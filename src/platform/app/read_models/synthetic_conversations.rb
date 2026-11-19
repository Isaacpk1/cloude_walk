require "digest"

# Provedor de exemplos sintéticos para as telas de conversa e linha do tempo (bloco 01).
# Monta ConversationView e TimelineView com os mesmos campos que os registros reais terão
# (07, seções 3.1, 3.4 e 4), todos marcados como DataSource::SYNTHETIC.
#
# Usa o nome da marca, do cliente, do bot e do analista do seed quando existirem
# (Seeds::Synthetic). A conversa em si não é gravada no banco: é um exemplo fixo e determinístico.
class SyntheticConversations
  BASE_TIME = Time.utc(2026, 11, 16, 13, 0, 0)
  SCENARIOS = {
    "exemplo-repasse" => :happy_path,
    "exemplo-corrida-3s" => :three_second_race,
    "exemplo-escalacao" => :escalation
  }.freeze
  FALLBACK_BRAND_NAMES = { "infinitepay" => "InfinitePay", "jim" => "JIM" }.freeze

  def all = SCENARIOS.keys.map { find(_1) }
  def find(id) = scenario(id)&.first
  def timeline(id) = scenario(id)&.last

  private

  def scenario(id)
    method_name = SCENARIOS[id.to_s]
    return unless method_name

    (@scenarios ||= {})[id.to_s] ||= send(method_name, Builder.new(id: id.to_s, number: SCENARIOS.keys.index(id.to_s) + 1))
  end

  # Caminho feliz (07, seção 3.1): uma mensagem, um turno, uma consulta e uma resposta entregue.
  def happy_path(b)
    names = names_for("infinitepay", customer_index: 0)
    b.message(1, "customer", names[:customer_name], "meu repasse não caiu", at: 0)
    b.message(2, "bot", names[:bot], "Encontrei seu repasse de R$ 1.200,00 da venda de ontem. Ele está programado e cai hoje até as 18h.",
              at: 3_702, delivery_status: "delivered", trace_seq: 1)
    b.turn(1, "applied", covered_seqs: [ 1 ], assignment_version: 1, action: "reply", tool_calls: %w[consultar_repasse],
                         note: "context_until_seq 1 cobre latest_customer_seq 1")

    b.ingestion(seq: 1, at: 0)
    b.cycle(turn: 1, trace_seq: 1, wait: 38..1_538, publish: 1_545..1_610, agent: 1_650..3_650,
            wait_detail: "Janela de 1,5 s sem nova mensagem (RN-55)", agent_detail: "Agente mock consultou consultar_repasse")
    b.event(:applied, 3_680..3_702, seq: 2, turn: 1, trace_seq: 1, detail: "Ação reply aplicada: context_until_seq 1 ≥ latest_customer_seq 1")
    b.delivery(seq: 2, at: 3_720..3_905, trace_seq: 1)

    b.build(**names.slice(:brand_slug, :brand_name, :customer_name), channel: "whatsapp", state: "aguardando_cliente",
            title: "Repasse não caiu", assignee: participant(names[:bot], "bot"), assignment_version: 1, latest_customer_seq: 1)
  end

  # Corrida dos 3 s (07, seção 3.4; RN-55 e RN-56): a mensagem 2 é gravada enquanto o turno 1 está no agente.
  def three_second_race(b)
    names = names_for("infinitepay", customer_index: 1)
    b.message(1, "customer", names[:customer_name], "meu repasse não caiu", at: 0)
    b.message(2, "customer", names[:customer_name], "é o de ontem, R$ 1.200", at: 3_000)
    b.message(3, "bot", names[:bot], "Achei o repasse de ontem, de R$ 1.200,00. Ele foi liberado hoje às 9h e cai na sua conta até as 18h.",
              at: 6_041, delivery_status: "delivered", trace_seq: 1)
    b.turn(1, "superseded", covered_seqs: [ 1 ], assignment_version: 1, action: "reply", tool_calls: %w[consultar_repasse],
                            note: "Superado pela gravação da seq 2 aos 3 s. Resposta das 3,5 s descartada")
    b.turn(2, "applied", covered_seqs: [ 1, 2 ], assignment_version: 1, action: "reply", tool_calls: %w[consultar_repasse],
                         note: "Contexto com as mensagens 1 e 2")

    b.ingestion(seq: 1, at: 0)
    b.cycle(turn: 1, trace_seq: 1, wait: 36..1_536, publish: 1_540..1_602, agent: 1_640..3_500,
            wait_detail: "Janela de 1,5 s sem nova mensagem (RN-55)", agent_detail: "Turno 1 com context_until_seq 1")
    b.ingestion(seq: 2, at: 3_000, persisted_detail: "latest_customer_seq = 2 no mesmo commit: turno 1 superado (RN-56)")
    b.event(:discarded, 3_500..3_512, seq: 1, turn: 1, trace_seq: 1,
                                      detail: "Resposta do turno 1 rejeitada: context_until_seq 1 < latest_customer_seq 2")
    b.cycle(turn: 2, trace_seq: 1, wait: 3_035..4_000, publish: 4_003..4_061, agent: 4_100..6_000,
            wait_detail: "Teto de 4 s desde first_pending_at (RN-55)", agent_detail: "Turno 2 com context_until_seq 2")
    b.event(:applied, 6_020..6_041, seq: 3, turn: 2, trace_seq: 1, detail: "Ação reply aplicada: context_until_seq 2 ≥ latest_customer_seq 2")
    b.delivery(seq: 3, at: 6_060..6_240, trace_seq: 1)

    b.build(**names.slice(:brand_slug, :brand_name, :customer_name), channel: "whatsapp", state: "aguardando_cliente",
            title: "Repasse em duas mensagens", assignee: participant(names[:bot], "bot"), assignment_version: 1, latest_customer_seq: 2)
  end

  # Escalação por decisão do agente (07, seção 3.2): fila humana, aviso de transferência e analista.
  def escalation(b)
    names = names_for("jim", customer_index: 0)
    queue = "Fila Geral (#{names[:brand_name]})"
    b.message(1, "customer", names[:customer_name], "cobraram duas vezes a mesma venda no meu cartão", at: 0)
    b.message(2, "system", "Sistema", "Vou transferir você para uma pessoa da nossa equipe. Ela já recebe o histórico da conversa.",
              at: 3_690, delivery_status: "delivered", trace_seq: 1)
    b.message(3, "analyst", names[:analyst], "Oi! Já vi as duas cobranças. Vou abrir a contestação da segunda agora.",
              at: 60_020, delivery_status: "delivered", trace_seq: 3)
    b.message(4, "customer", names[:customer_name], "obrigado, fico no aguardo", at: 75_000, trace_seq: 4)
    b.turn(1, "applied", covered_seqs: [ 1 ], assignment_version: 1, action: "escalate", tool_calls: %w[consultar_transacoes],
                         note: "Agente escalou com resumo do handoff (RN-39)")
    b.escalate(at: 3_672, from: names[:bot], to: queue, trigger: "Decisão do agente (escalate)",
               reason: "Contestação de cobrança em duplicidade exige analista", assignment_version: 2)
    b.escalate(at: 45_000, from: queue, to: names[:analyst], trigger: "Atribuição",
               reason: "Analista online com vaga na equipe (RN-30)", assignment_version: 3)

    b.ingestion(seq: 1, at: 0)
    b.cycle(turn: 1, trace_seq: 1, wait: 35..1_535, publish: 1_540..1_600, agent: 1_630..3_630,
            wait_detail: "Janela de 1,5 s sem nova mensagem (RN-55)", agent_detail: "Agente mock consultou consultar_transacoes")
    b.event(:applied, 3_650..3_672, seq: 1, turn: 1, trace_seq: 1, detail: "Ação escalate aplicada com resumo")
    b.event(:escalated, 3_672..3_690, seq: 2, turn: 1, trace_seq: 1,
                                      detail: "#{queue}; assignment_version 1 → 2; aviso de transferência no outbox (RN-42)")
    b.delivery(seq: 2, at: 3_700..3_880, trace_seq: 1)
    b.event(:assigned, 45_000..45_020, seq: nil, turn: nil, trace_seq: 1, detail: "#{names[:analyst]} assumiu; assignment_version 2 → 3")
    b.event(:persisted, 60_000..60_020, seq: 3, turn: nil, trace_seq: 3, detail: "Mensagem do analista gravada sem passar pelo Kafka")
    b.delivery(seq: 3, at: 60_030..60_210, trace_seq: 3)
    b.ingestion(seq: 4, at: 75_000, persisted_detail: "Caso com analista: entra no histórico humano, sem turno da IA")

    b.build(**names.slice(:brand_slug, :brand_name, :customer_name), channel: "whatsapp", state: "com_analista",
            title: "Cobrança em duplicidade", assignee: participant(names[:analyst], "human"), assignment_version: 3, latest_customer_seq: 4)
  end

  def participant(name, kind) = ConversationView::Participant.new(name:, kind:)

  def names_for(brand_slug, customer_index:)
    brand = Brand.find_by(slug: brand_slug)
    brand_name = brand&.name || FALLBACK_BRAND_NAMES.fetch(brand_slug)
    {
      brand_slug:,
      brand_name:,
      customer_name: brand&.customers&.order(:id)&.offset(customer_index)&.first&.display_name || "Cliente sintético #{customer_index + 1}",
      bot: User.find_by(kind: "bot")&.name || "Agente de IA",
      analyst: User.find_by(email: "analista1.#{brand_slug}@helpdesk.test")&.name || "Analista 1 #{brand_name}"
    }
  end

  # Monta uma conversa e sua linha do tempo a partir de deslocamentos em milissegundos.
  class Builder
    def initialize(id:, number:)
      @id = id
      @number = number
      @ticket_id = format("sint-%04d", number)
      @messages = []
      @turns = []
      @escalations = []
      @events = []
    end

    def message(seq, author_type, author_name, body, at:, delivery_status: nil, trace_seq: seq)
      @messages << ConversationView::Message.new(
        seq:, author_type:, author_name:, body:, internal: false,
        direction: author_type == "customer" ? "inbound" : "outbound",
        occurred_at: time(at), trace_id: trace(trace_seq), delivery_status:,
        delivery_id: delivery_status && delivery_id(seq)
      )
    end

    def turn(number, status, covered_seqs:, assignment_version:, action:, tool_calls:, note:)
      @turns << ConversationView::Turn.new(
        number:, status:, covered_seqs:, context_until_seq: covered_seqs.max, assignment_version:,
        event_id: uuid("turn-#{number}"), action:, tool_calls:, note:
      )
    end

    def escalate(at:, **attrs) = @escalations << ConversationView::Escalation.new(occurred_at: time(at), **attrs)

    def event(kind, range, seq:, turn:, trace_seq:, detail:)
      @events << TimelineView::Event.new(
        kind:, started_at: time(range.begin), finished_at: time(range.end), ticket_id: @ticket_id,
        seq:, turn:, trace_id: trace(trace_seq), detail:, source: DataSource::SYNTHETIC
      )
    end

    # Recebimento do webhook (202 só depois do commit) e a transação única da ingestão (invariante 1).
    def ingestion(seq:, at:, persisted_detail: nil)
      event(:received, at..(at + 42), seq:, turn: nil, trace_seq: seq, detail: "Webhook do canal aceito com 202 após o commit")
      event(:persisted, (at + 4)..(at + 36), seq:, turn: nil, trace_seq: seq,
                                             detail: persisted_detail || "Transação única: mensagem seq #{seq}, auditoria e outbox")
    end

    # Janela de agrupamento, publicação no broker e execução do agente de um turno.
    def cycle(turn:, trace_seq:, wait:, publish:, agent:, wait_detail:, agent_detail:)
      event(:intentional_wait, wait, seq: nil, turn:, trace_seq:, detail: wait_detail)
      event(:published, publish, seq: nil, turn:, trace_seq:,
                                 detail: "Webhook ao broker; Kafka confirmou (event_id #{uuid("turn-#{turn}")[0, 8]})")
      event(:agent_run, agent, seq: nil, turn:, trace_seq:, detail: agent_detail)
    end

    def delivery(seq:, at:, trace_seq:)
      event(:delivered, at, seq:, turn: nil, trace_seq:, detail: "Canal confirmou #{delivery_id(seq)}")
    end

    def build(**attrs)
      source = DataSource::SYNTHETIC
      conversation = ConversationView.new(
        id: @id, ticket_id: @ticket_id, messages: @messages, turns: @turns, escalations: @escalations, source:, **attrs
      )
      [ conversation, TimelineView.new(conversation_id: @id, ticket_id: @ticket_id, events: @events, source:) ]
    end

    private

    def time(ms) = BASE_TIME + ((@number - 1) * 3600) + Rational(ms, 1000)
    def trace(seq) = Digest::SHA256.hexdigest("#{@id}:trace:#{seq}")[0, 32]
    def delivery_id(seq) = "dlv-#{@ticket_id}-#{seq}"

    def uuid(name)
      hex = Digest::SHA256.hexdigest("#{@id}:#{name}")
      [ hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12] ].join("-")
    end
  end
  private_constant :Builder
end
