# Eval da corrida dos 3 s (ADR-023; RN-55, RN-56; 04, critério de aceite de turnos; 07, seção 3.4, diagrama
# da corrida).
#
# Num atendimento de chat novo da marca, marcado como eval (conta de provedor `<marca>-chat-eval`), com cliente
# sintético verificado e identidade `eval_<hex>` própria da execução:
#
#   t=0      mensagem 1 (Ingestion::Receive)
#   t≈1,5 s  fim da janela: Deadlines::DispatchDue + Turns::Open abrem o turno 1 com [1]
#   t=3 s    mensagem 2: no mesmo commit, o turno 1 perde a validade (superseded)
#   t=3,5 s  a resposta do turno 1 chega (AgentActions::Apply) e é rejeitada como turno_superado
#   t=4 s    teto da janela: o turno 2 abre com [1, 2]
#   +0,5 s   a resposta do turno 2 é aplicada: uma única saída ao cliente
#   depois   a volta do worker na saída: atendimento de eval, a entrega encerra como cancelled (motivo eval)
#
# As respostas vêm do gabarito fixo (FIXTURE), válidas no contrato agent_outbound, com o modelo `eval-fixture`:
# o resultado depende só da regra da plataforma. O evento do turno é lido do outbox, sem passar pelo broker: o
# worker real descarta a publicação do turno de um atendimento de eval (motivo eval) e não entrega a saída dele.
# O scheduler real pode abrir o turno antes do eval: o eval usa o item e o turno que encontrar.
module Evals
  module Scenarios
    class CorridaTresSegundos
      NAME = "corrida-3s".freeze
      TITLE = "Corrida dos 3 s".freeze
      DESCRIPTION = "Mensagem 2 aos 3 s com o turno 1 aberto: a resposta do turno 1 aos 3,5 s é rejeitada, " \
                    "o turno 2 sai aos 4 s com as mensagens 1 e 2 e só ele responde ao cliente (RN-55, RN-56).".freeze
      AGENT_MODEL = "eval-fixture".freeze
      CHANNEL = "chat".freeze

      FIXTURE = {
        "scenario" => NAME, "version" => "1.0.0", "channel" => CHANNEL,
        "messages" => [
          { "seq" => 1, "at_ms" => 0, "text" => "meu repasse não caiu" },
          { "seq" => 2, "at_ms" => 3_000, "text" => "é o de ontem, R$ 1.200" }
        ],
        "actions" => [
          { "turn" => 1, "at_ms" => 3_500, "action" => "reply", "agent_ms" => 2_000,
            "text" => "Qual repasse você quer consultar?" },
          { "turn" => 2, "after_open_ms" => 500, "action" => "reply", "agent_ms" => 500,
            "text" => "O repasse de ontem, de R$ 1.200, cai hoje até as 18h." }
        ]
      }.freeze
      FIXTURE_VERSION = FIXTURE.fetch("version")

      CHECKS = [
        "turno 1 cobre só a mensagem 1", "mensagem 2 supera o turno 1 no commit",
        "resposta do turno 1 rejeitada como turno_superado", "nenhuma saída do turno 1",
        "turno 2 cobre as mensagens 1 e 2", "resposta do turno 2 aplicada", "uma única saída ao cliente"
      ].freeze

      def self.config_hash = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(FIXTURE))}"

      def self.expected
        {
          "turns" => [
            { "turn" => 1, "status" => "superseded", "context_until_seq" => 1, "pending_seqs" => [ 1 ] },
            { "turn" => 2, "status" => "applied", "context_until_seq" => 2, "pending_seqs" => [ 1, 2 ] }
          ],
          "rejections" => [ { "turn" => 1, "reason" => "turno_superado" } ],
          "outbound_count" => 1,
          "steps" => [
            { "step" => "mensagem 1", "t_ms" => 0 }, { "step" => "turno 1 aberto", "t_ms" => 1_500 },
            { "step" => "mensagem 2", "t_ms" => 3_000 }, { "step" => "resposta do turno 1", "t_ms" => 3_500 },
            { "step" => "turno 2 aberto", "t_ms" => 4_000 }, { "step" => "resposta do turno 2", "t_ms" => 4_500 }
          ]
        }
      end

      attr_reader :ticket, :trace_id

      def initialize(brand:, clock:, sleeper:)
        @brand = brand
        @clock = clock
        @sleeper = sleeper
        @steps = []
        @snapshots = {}
        @results = {}
      end

      def run
        customer = create_customer
        @t0 = @clock.call
        ingest(customer, FIXTURE["messages"][0], step: "mensagem 1")

        open_turn(1, fallback_at: @t0 + Turns::Policy.for(@brand).window_for(CHANNEL))
        wait_until(@t0 + ms(FIXTURE["messages"][1]["at_ms"]))
        ingest(customer, FIXTURE["messages"][1], step: "mensagem 2")
        @snapshots[:turn1_after_message2] = turn_record(1)&.status

        wait_until(@t0 + ms(FIXTURE["actions"][0]["at_ms"]))
        respond(1, step: "resposta do turno 1")

        opened_at = open_turn(2, fallback_at: @t0 + Turns::Policy.for(@brand).ceiling)
        return unless opened_at

        wait_until(opened_at + ms(FIXTURE["actions"][1]["after_open_ms"]))
        respond(2, step: "resposta do turno 2")
        conclude_deliveries
      end

      # O que foi observado até agora: o estado final dos turnos e das saídas, lido do banco, e os passos.
      def observed
        outbound = outbound_messages
        {
          "turns" => turns_summary, "outbound_seqs" => outbound.map { _1["seq"] }, "outbound" => outbound,
          "rejections" => @results.filter_map { |turn, r| { "turn" => turn, "reason" => r[:reason] } if r[:status] == "rejected" },
          "actions" => @results.map { |turn, r| { "turn" => turn }.merge(r.transform_keys(&:to_s)) },
          "turn1_status_after_message_2" => @snapshots[:turn1_after_message2],
          "deliveries" => deliveries_summary, "foreign_agent_actions" => foreign_agent_actions, "steps" => @steps
        }
      end

      def checks
        obs = observed
        open1 = @snapshots[:open1]
        open2 = @snapshots[:open2]
        from_turn1 = obs["outbound"].select { _1["turn"] == 1 }.map { _1["seq"] }
        first_out = obs["outbound"].first
        [
          check(CHECKS[0], { "context_until_seq" => 1, "pending_seqs" => [ 1 ] }, open1, turn: 1, seq: 1),
          check(CHECKS[1], "superseded", obs["turn1_status_after_message_2"], turn: 1, seq: 2),
          check(CHECKS[2], { "status" => "rejected", "reason" => "turno_superado" }, result_of(1), turn: 1),
          check(CHECKS[3], [], from_turn1, turn: 1, seq: from_turn1.first),
          check(CHECKS[4], { "context_until_seq" => 2, "pending_seqs" => [ 1, 2 ] }, open2, turn: 2, seq: 2),
          check(CHECKS[5], { "status" => "applied", "turn_status" => "applied" }, applied_view(2), turn: 2,
                                                                                                    seq: obs["outbound"].find { _1["turn"] == 2 }&.fetch("seq")),
          check(CHECKS[6], 1, obs["outbound"].size, turn: first_out&.fetch("turn") || 2, seq: first_out&.fetch("seq"))
        ]
      end

      private

      def ms(value) = value / 1000r

      def t_ms = ((@clock.call - @t0) * 1000).round

      # t_ms é o início do passo, relativo à mensagem 1: no relógio real, a duração da chamada não entra no horário.
      def step!(name, at_ms, **extra)
        @steps << { "step" => name, "t_ms" => at_ms }.merge(extra.transform_keys(&:to_s))
        JsonLog.info("eval.step", trace_id:, scenario: NAME, step: name, t_ms: at_ms, ticket_id: ticket&.id)
      end

      def wait_until(at)
        @sleeper.call((at - @clock.call).to_f)
      end

      # Cliente sintético verificado (RN-05) com conta de chat própria da execução: um atendimento novo,
      # sem misturar com o seed nem com outra execução (RN-03).
      def create_customer
        ActiveRecord::Base.transaction do
          customer = Customer.create!(brand: @brand, display_name: "Cliente sintético do eval #{NAME}", verified: true)
          customer.identities.create!(brand: @brand, channel: CHANNEL, external_id: "eval_#{SecureRandom.hex(8)}")
          customer
        end
      end

      def ingest(customer, message, step:)
        trace = SecureRandom.hex(16)
        @trace_id ||= trace
        normalized = {
          "schema" => "helpdesk.normalized_message.v1", "channel" => CHANNEL, "brand" => @brand.slug,
          "provider_account" => provider_account, "external_id" => "eval-#{SecureRandom.uuid}",
          "sender" => { "channel_identity" => customer.identities.sole.external_id },
          "content" => { "type" => "text", "text" => message.fetch("text") },
          "received_at" => @clock.call.utc.iso8601(3), "trace_id" => trace
        }
        at_ms = t_ms
        result = Ingestion::Receive.call(normalized, provider_payload: chat_webhook(customer, normalized))
        @ticket = result.ticket
        step!(step, at_ms, seq: result.message.seq)
      end

      # A conta de eval da marca (ADR-023, item 5): o atendimento nasce marcado como eval no commit da mensagem 1,
      # e o worker real não publica o turno dele no broker nem entrega a saída dele ao canal.
      # O webhook cru do chat, como o da ingestão real (contrato chat_webhook): o customer_ref é o destino da
      # resposta (07, seção 5.0). Sem ele, a saída seria recusada pela plataforma antes de qualquer envio.
      def chat_webhook(customer, normalized)
        identity = customer.identities.sole.external_id
        HelpdeskContracts.validate!(:chat_webhook, {
          "message_id" => normalized.fetch("external_id"), "account_id" => identity,
          "customer_ref" => "cus_#{identity}", "text" => normalized.dig("content", "text"),
          "sent_at" => normalized.fetch("received_at")
        })
      end

      def provider_account
        @provider_account ||= ProviderAccount.evaluation_for!(@brand, CHANNEL).slug
      end

      # Espera o fim da janela gravado pela ingestão e faz a volta do scheduler e a abertura pelo worker. Se o
      # scheduler real já registrou a ação (ou o worker já abriu o turno), usa o mesmo item pela chave única.
      # Devolve o horário da abertura, ou nil se nenhum turno novo abriu.
      def open_turn(number, fallback_at:)
        due = Ticket.where(id: ticket.id, brand_id: @brand.id).pick(:dispatch_due_at)
        wait_until(due || fallback_at)
        at_ms = t_ms
        opened_at = @clock.call
        current = Ticket.find_by!(id: ticket.id, brand_id: @brand.id)
        # Só o atendimento do eval, na marca do eval: o eval não registra prazos de outros atendimentos.
        Deadlines::DispatchDue.call(now: @clock.call, limit: 1, brand_id: @brand.id, ticket_ids: [ ticket.id ])
        item = OutboxEvent.find_by(brand_id: @brand.id, dedup_key: Deadlines::DispatchDue.dedup_key(current))
        Turns::Open.call(item.id) if item

        turn = turn_record(number)
        return unless turn

        @snapshots[:"open#{number}"] = { "context_until_seq" => turn.context_until_seq, "pending_seqs" => pending_seqs(turn) }
        step!("turno #{number} aberto", at_ms, turn: number)
        opened_at
      end

      def turn_record(number) = AiTurn.find_by(brand_id: @brand.id, ticket_id: ticket.id, turn: number)
      def pending_seqs(turn) = turn.context.fetch("pending_messages").map { _1["seq"] }

      # A ação do gabarito para o turno, com os campos do evento do turno lido do outbox (07, seção 5.3).
      def respond(number, step:)
        turn = turn_record(number)
        event = OutboxEvent.find_by!(id: turn.event_id, brand_id: @brand.id)
        at_ms = t_ms
        result = AgentActions::Apply.call(action_for(FIXTURE["actions"][number - 1], event.payload),
                                          traceparent: "00-#{event.trace_id}-#{SecureRandom.hex(8)}-01")
        @results[number] = { status: result.status.to_s, reason: result.reason }
        step!(step, at_ms, turn: number, result: result.status.to_s, reason: result.reason)
      end

      def action_for(fixture, event)
        now = @clock.call
        {
          "schema" => "helpdesk.agent_action.v1", "event_id" => SecureRandom.uuid, "in_reply_to" => event.fetch("event_id"),
          "conversation_id" => event.fetch("conversation_id"), "brand" => event.fetch("brand"), "turn" => event.fetch("turn"),
          "context_until_seq" => event.fetch("context_until_seq"), "assignment_version" => event.fetch("assignment_version"),
          "action" => fixture.fetch("action"), "tool_calls" => [],
          "agent" => { "model" => AGENT_MODEL, "version" => FIXTURE_VERSION, "config_hash" => self.class.config_hash },
          "timing" => { "received_at" => (now - ms(fixture.fetch("agent_ms"))).utc.iso8601(3),
                        "responded_at" => now.utc.iso8601(3), "agent_ms" => fixture.fetch("agent_ms") },
          "reply" => { "text" => fixture.fetch("text") }
        }
      end

      def turns_summary
        return [] unless ticket

        AiTurn.where(brand_id: @brand.id, ticket_id: ticket.id).order(:turn).map do |turn|
          { "turn" => turn.turn, "status" => turn.status, "context_until_seq" => turn.context_until_seq,
            "pending_seqs" => pending_seqs(turn) }
        end
      end

      # Saídas ao cliente e o turno de cada uma (auditoria delivery.requested do AgentActions::Apply).
      def outbound_messages
        return [] unless ticket

        turns = AuditEvent.where(brand_id: @brand.id, ticket_id: ticket.id, event_type: "delivery.requested")
                          .to_h { [ _1.data["seq"], _1.data["turn"] ] }
        Message.where(brand_id: @brand.id, ticket_id: ticket.id, direction: "outbound").order(:seq).pluck(:seq)
               .map { { "seq" => _1, "turn" => turns[_1] } }
      end

      # A volta do worker na saída do eval (Deliveries::Send, o mesmo caminho do OutboxJob): o atendimento é de
      # eval, então a entrega encerra como cancelled, motivo eval, sem chegar a um provedor (ADR-023, item 5). Se
      # o worker real já concluiu o item, o Send só confirma o estado.
      def conclude_deliveries
        OutboxEvent.where(brand_id: @brand.id, ticket_id: ticket.id, event_type: Deliveries::Send::EVENT_TYPE, completed_at: nil)
                   .order(:id).pluck(:id).each { Deliveries::Send.call(_1) }
      end

      # O desfecho de cada entrega do atendimento, com o motivo da auditoria que a encerrou.
      def deliveries_summary
        return [] unless ticket

        audits = AuditEvent.where(brand_id: @brand.id, ticket_id: ticket.id,
                                  event_type: %w[delivery.requested delivery.cancelled delivery.failed])
                           .order(:id).group_by { _1.data["delivery_id"] }
        Delivery.where(brand_id: @brand.id, ticket_id: ticket.id).order(:seq).map do |delivery|
          history = audits.fetch(delivery.delivery_id, [])
          closing = history.reverse.find { _1.event_type != "delivery.requested" }
          { "seq" => delivery.seq, "turn" => history.find { _1.event_type == "delivery.requested" }&.data&.dig("turn"),
            "status" => delivery.status, "reason" => closing&.data&.dig("reason") }
        end
      end

      # Ações de outro agente no atendimento do eval (ex.: o agent-mock respondendo pelo Kafka no Compose).
      def foreign_agent_actions
        return 0 unless ticket

        AuditEvent.where(brand_id: @brand.id, ticket_id: ticket.id, actor_type: "agent")
                  .where.not(agent_model: AGENT_MODEL).count
      end

      def result_of(number)
        result = @results[number]
        result && { "status" => result[:status], "reason" => result[:reason] }
      end

      def applied_view(number)
        result = @results[number]
        result && { "status" => result[:status], "turn_status" => turn_record(number)&.status }
      end

      def check(name, expected, observed, turn:, seq: nil)
        { name:, expected:, observed:, ok: observed == expected, evidence: { turn:, seq: } }
      end
    end
  end
end
