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

messages = Message.where(direction: "inbound").where("external_id LIKE ?", "bench_#{run_id}_%")
stored = messages.count
ticket_ids = messages.distinct.pluck(:ticket_id)

# Latência por etapa, em ms, só das mensagens da execução (o relógio é o do banco/plataforma).
ack_to_published = OutboxEvent.where(ticket_id: ticket_ids, event_type: Turns::Open::EVENT_TYPE).where.not(published_at: nil)
                              .pluck(Arel.sql("EXTRACT(EPOCH FROM (published_at - created_at)) * 1000")).map(&:to_f)
turn_status = AiTurn.where(ticket_id: ticket_ids).group(:status).count
turns_total = turn_status.values.sum
delivered = Delivery.where(ticket_id: ticket_ids, status: "delivered")
reply_latency = delivered.joins(:message).pluck(Arel.sql("EXTRACT(EPOCH FROM (deliveries.delivered_at - messages.received_at)) * 1000")).map(&:to_f)
pending_outbox = OutboxEvent.where(ticket_id: ticket_ids, completed_at: nil).count

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
  "outbox_pending_now" => pending_outbox
)
