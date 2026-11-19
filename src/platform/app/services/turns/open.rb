# Abertura de um turno da IA a partir do aviso `message.received` do outbox (07, seção 3.1, passo 3).
#
#   Turns::Open.call(outbox_event_id) # => Result(status:, turn:)
#
# Uma transação, com a linha do atendimento travada: monta o contexto com todas as mensagens
# pendentes (RF-33, RN-49), grava o turno `eligible` e o seu evento no outbox (invariante 2) e
# encerra o aviso da ingestão. O evento fica pronto e imutável: as retentativas reenviam o mesmo
# conteúdo com o mesmo event_id (invariante 3). A publicação acontece depois, fora da transação.
#
# Bloco 03: o turno abre logo após a mensagem, sem janela de agrupamento. A janela, o teto de 4 s e
# a abertura pelo scheduler (dispatch_due_at) entram nos blocos 06 e 08. A atribuição ao bot entra
# com a triagem (bloco 11): até lá, todo caso que não está com um humano vai para a IA.
module Turns
  class Open
    Result = Data.define(:status, :turn)

    AI_DEADLINE = 30.seconds # RN-46 (06, parâmetros)
    HISTORY_LIMIT = 20 # RN-49
    # 07, seção 3.3: mensagens nesses estados não vão para a IA.
    HUMAN_STATES = %w[aguardando_humano com_analista resolvido fechado].freeze
    EVENT_TYPE = "agent.event".freeze

    def self.call(...) = new(...).call

    def initialize(outbox_event_id)
      @outbox_event_id = outbox_event_id
    end

    def call
      ActiveRecord::Base.transaction do
        notice = OutboxEvent.find(@outbox_event_id)
        # Ordem das travas igual à da ingestão: atendimento primeiro, depois o item.
        ticket = Ticket.lock.find(notice.ticket_id)
        notice.lock!
        next Result.new(status: :already_done, turn: nil) if notice.completed_at

        @ticket = ticket
        @notice = notice
        decide
      end
    end

    private

    attr_reader :ticket, :notice

    def decide
      return not_opened(:skipped, reason: "fora_da_ia", state: ticket.state) unless with_ai?

      covering = ticket.ai_turns.eligible.where(context_until_seq: ticket.latest_customer_seq...).order(:turn).last
      return not_opened(:covered, reason: "coberto", covered_by_turn: covering.turn) if covering
      return not_opened(:expired, reason: "prazo_vencido", deadline_at: deadline_at.iso8601(3)) if Time.current >= deadline_at

      open_turn
    end

    def with_ai?
      return false if HUMAN_STATES.include?(ticket.state)

      ticket.assignee.nil? || ticket.assignee.kind == "bot"
    end

    def open_turn
      event_id = SecureRandom.uuid
      number = ticket.ai_turns.maximum(:turn).to_i + 1
      payload = Envelope.new(ticket:, event_id:, turn: number, pending:, history:, deadline_at:).to_h
      HelpdeskContracts.validate!(:agent_inbound, payload)

      turn = ticket.ai_turns.create!(
        brand_id: ticket.brand_id, turn: number, context_until_seq: ticket.latest_customer_seq,
        assignment_version: ticket.assignment_version, context: payload.fetch("context"), event_id:,
        status: "eligible", deadline_at:
      )
      OutboxEvent.create!(id: event_id, brand_id: ticket.brand_id, ticket:, event_type: EVENT_TYPE, payload:,
                          trace_id: notice.trace_id, next_attempt_at: Time.current)
      complete_notice
      audit("ai_turn.opened", turn: number, event_id:, context_until_seq: turn.context_until_seq,
                              pending_seqs: pending.map(&:seq), deadline_at: deadline_at.iso8601(3))
      Result.new(status: :opened, turn:)
    end

    def not_opened(status, **data)
      complete_notice
      audit("ai_turn.not_opened", **data)
      Result.new(status:, turn: nil)
    end

    def complete_notice = notice.update!(completed_at: Time.current, lease_until: nil)

    # "Sem resposta": mensagens do cliente depois da última saída visível ao cliente.
    def pending
      @pending ||= begin
        answered_until = ticket.messages.where(direction: "outbound", internal: false).maximum(:seq).to_i
        ticket.messages.where(direction: "inbound", author_type: "customer").where(seq: (answered_until + 1)..).to_a
      end
    end

    def history
      first_pending = pending.first&.seq || (ticket.latest_customer_seq + 1)
      ticket.messages.where(internal: false).where(seq: ...first_pending).reorder(seq: :desc).limit(HISTORY_LIMIT).to_a.reverse
    end

    # RN-46: compartilhado pelos turnos do ciclo, contado do commit da primeira mensagem pendente.
    def deadline_at = @deadline_at ||= pending.first.created_at + AI_DEADLINE

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket:, actor_type: "system", event_type:,
                         trace_id: notice.trace_id, data:)
    end
  end
end
