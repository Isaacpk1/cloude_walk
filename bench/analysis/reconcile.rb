# Lê o que a execução deixou no banco e o resumo do k6, e imprime um JSON com perdas, turnos superados e latência por
# etapa (RNF-03, RNF-13, RNF-14, E1, E5). Roda dentro da plataforma:
#
#   bin/rails runner /bench/analysis/reconcile.rb RUN_ID /results/RUN_ID-k6.json
#
# Só lê. Sem mexer em nada, repetir a análise dá o mesmo resultado.
require "json"

run_id, k6_file = ARGV
abort "uso: reconcile.rb RUN_ID [resumo-do-k6.json]" unless run_id

def percentiles(values)
  return {} if values.empty?

  sorted = values.sort
  pick = ->(q) { sorted[[ (q * sorted.size).ceil - 1, 0 ].max] }
  { "count" => sorted.size, "p50" => pick.(0.5), "p95" => pick.(0.95), "p99" => pick.(0.99), "max" => sorted.last }
end

brand = Brand.find_by!(slug: ENV.fetch("BENCH_BRAND", "infinitepay"))
messages = Message.where(brand_id: brand.id, direction: "inbound").where("external_id LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like("bench_#{run_id}_")}%")
stored = messages.count
ticket_ids = messages.distinct.pluck(:ticket_id)

# Latência por etapa, em ms, só das mensagens da execução (o relógio é o do banco/plataforma).
ack_to_published = OutboxEvent.where(brand_id: brand.id, ticket_id: ticket_ids, event_type: Turns::Open::EVENT_TYPE).where.not(published_at: nil)
                              .pluck(Arel.sql("EXTRACT(EPOCH FROM (published_at - created_at)) * 1000")).map(&:to_f)
turn_status = AiTurn.where(brand_id: brand.id, ticket_id: ticket_ids).group(:status).count
turns_total = turn_status.values.sum
# Uma amostra por mensagem de entrada que foi coberta por uma resposta entregue. O instante de criação da
# saída não substitui o recebimento da entrada. Avisos e saídas canceladas não contam como resposta.
latency_relation = messages.joins(<<~SQL.squish)
  JOIN LATERAL (
    SELECT d.delivered_at, t.context, applied.data AS action_data, opened.data->>'dispatch_due_at' AS window_at,
           ob.published_at AS published_at
    FROM deliveries d
    JOIN audit_events a ON a.brand_id = d.brand_id AND a.ticket_id = d.ticket_id
      AND a.event_type = 'delivery.requested' AND a.data->>'delivery_id' = d.delivery_id::text
    LEFT JOIN ai_turns t ON t.brand_id = d.brand_id AND t.ticket_id = d.ticket_id AND t.turn = (a.data->>'turn')::integer
    LEFT JOIN audit_events applied ON applied.brand_id = d.brand_id AND applied.ticket_id = d.ticket_id
      AND applied.event_type = 'agent_action.applied' AND applied.data->>'event_id' = t.applied_event_id::text
    LEFT JOIN outbox_events ob ON ob.id = t.event_id
    LEFT JOIN audit_events opened ON opened.brand_id = d.brand_id AND opened.ticket_id = d.ticket_id
      AND opened.event_type = 'ai_turn.opened' AND (opened.data->>'turn')::integer = t.turn
    WHERE d.brand_id = messages.brand_id AND d.ticket_id = messages.ticket_id
      AND d.status = 'delivered' AND d.kind IN ('reply', 'resolution') AND d.seq > messages.seq
      AND (a.data->>'context_until_seq')::integer >= messages.seq
    ORDER BY d.seq LIMIT 1
  ) answer ON true
SQL
samples = latency_relation.pluck(
  Arel.sql("EXTRACT(EPOCH FROM (answer.delivered_at - messages.received_at)) * 1000"),
  Arel.sql("(answer.action_data->'timing'->>'agent_ms')::numeric"),
  Arel.sql("EXTRACT(EPOCH FROM (answer.window_at::timestamp - messages.received_at)) * 1000"),
  Arel.sql("jsonb_array_length(answer.context->'pending_messages')")
)
# Fronteiras do agente (caixa-preta): o que acontece entre a publicação do turno e a entrada da resposta no broker é do
# agente (inclui a fila dele); o resto é da plataforma. Tudo medido por relógios da plataforma e do broker.
#   ida            janela de agrupamento fechada -> evento do turno publicado no Kafka
#   agente         publicado -> resposta entrou no Kafka (broker_at)
#   volta_consumo  resposta no Kafka -> aplicada pela plataforma (fila do consumer, trava, gravação)
#   volta_entrega  aplicada -> entregue ao canal
boundary = latency_relation.pluck(
  Arel.sql("EXTRACT(EPOCH FROM (answer.published_at - answer.window_at::timestamp)) * 1000"),
  Arel.sql("EXTRACT(EPOCH FROM ((answer.action_data->>'broker_at')::timestamp - answer.published_at)) * 1000"),
  Arel.sql("EXTRACT(EPOCH FROM ((answer.action_data->>'platform_received_at')::timestamp - (answer.action_data->>'broker_at')::timestamp)) * 1000"),
  Arel.sql("EXTRACT(EPOCH FROM (answer.delivered_at - (answer.action_data->>'platform_received_at')::timestamp)) * 1000"),
  Arel.sql("(answer.action_data->'timing'->>'agent_ms')::numeric")
).select { |row| row.none?(&:nil?) }.map { |row| row.map(&:to_f) }
reply_latency = samples.map { _1.first.to_f }
overhead = []
excluded = Hash.new(0)
samples.each do |total, agent, window, context_size|
  reason = if context_size != 1 then "contexto_agrupado_ou_sem_turno"
  elsif agent.nil? || window.nil? then "sem_tempos"
  elsif agent.negative? || window.negative? || total - agent - window < 0 then "tempos_inconsistentes"
  end
  reason ? excluded[reason] += 1 : overhead << (total - agent - window).to_f
end
pending_outbox = OutboxEvent.where(brand_id: brand.id, ticket_id: ticket_ids, completed_at: nil).count

k6 = k6_file && File.exist?(k6_file) ? JSON.parse(File.read(k6_file)) : nil
accepted = k6&.dig("metrics", "helpdesk_accepted", "values", "count")&.to_i
duplicated = k6&.dig("metrics", "helpdesk_duplicate", "values", "count")&.to_i

puts JSON.pretty_generate(
  "run_id" => run_id,
  "k6" => k6 && { "profile" => k6["profile"], "mode" => k6["mode"], "seed" => k6["seed"], "accepted_202" => accepted, "duplicate_200" => duplicated,
                  "rejected" => k6.dig("metrics", "helpdesk_rejected", "values", "count")&.to_i,
                  "ack_ms" => k6.dig("metrics", "http_req_duration", "values")&.slice("med", "p(95)", "p(99)", "max") },
  "stored_messages" => stored,
  "lost_messages" => accepted ? accepted - stored : nil, # RNF-14: precisa ser 0
  "conversations" => ticket_ids.size,
  "ai_turns" => { "total" => turns_total, "by_status" => turn_status,
                  "superseded_ratio" => turns_total.zero? ? nil : (turn_status.fetch("superseded", 0).to_f / turns_total).round(4) },
  "outbox_published_after_ms" => percentiles(ack_to_published),
  "reply_delivered_after_ms" => percentiles(reply_latency),
  "platform_overhead_ms" => percentiles(overhead),
  "agent_ms" => percentiles(samples.filter_map { _1[1]&.to_f }),
  "fronteiras_ms" => {
    "ida" => percentiles(boundary.map { _1[0] }), "agente_caixa_preta" => percentiles(boundary.map { _1[1] }),
    "volta_consumo" => percentiles(boundary.map { _1[2] }), "volta_entrega" => percentiles(boundary.map { _1[3] }),
    "plataforma_ida_mais_volta" => percentiles(boundary.map { _1[0] + _1[2] + _1[3] }),
    # A fila da integração (tópico, partições) é da plataforma; só o processamento do agente fica de fora.
    "fila_da_integracao" => percentiles(boundary.map { _1[1] - _1[4] }),
    "overhead_com_fila" => percentiles(boundary.map { _1[0] + (_1[1] - _1[4]) + _1[2] + _1[3] })
  },
  "grouping_wait_ms" => percentiles(samples.filter_map { _1[2]&.to_f }),
  "overhead_excluded_samples" => excluded,
  "messages_without_delivered_reply" => stored - samples.size,
  "outbox_pending_now" => pending_outbox
)
