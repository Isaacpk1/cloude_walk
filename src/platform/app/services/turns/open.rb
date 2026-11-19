# Abertura de um turno da IA pela ação "turn.dispatch" do outbox (07, seção 3.1, passo 3, e seção 3.4;
# RN-55; ADR-016).
#
#   Turns::Open.call(outbox_event_id) # => Result(status:, turn:)
#
# A ingestão grava os prazos do ciclo no atendimento (dispatch_due_at, ai_deadline_at). Quando a janela
# de agrupamento vence, o scheduler grava a ação "turn.dispatch" no outbox e o worker chega aqui.
#
# Uma transação, com a linha do atendimento travada (antes do item, na mesma ordem da ingestão):
# revalida a ação e a encerra. Ou descarta com o motivo auditado, ou monta o contexto com todas as
# mensagens pendentes (RF-33, RN-49), grava o turno `eligible` e o seu evento no outbox (invariante 2)
# e zera dispatch_due_at. first_pending_* e ai_deadline_at ficam até a resposta aplicada (bloco 07).
# O evento fica pronto e imutável: as retentativas reenviam o mesmo conteúdo com o mesmo event_id
# (invariante 3). A publicação acontece depois, fora da transação.
#
# A atribuição ao bot entra com a triagem (bloco 11): até lá, todo caso que não está com um humano vai
# para a IA.
module Turns
  class Open
    Result = Data.define(:status, :turn)

    DISPATCH_TYPE = Deadlines::DispatchDue::EVENT_TYPE
    EVENT_TYPE = "agent.event".freeze
    HISTORY_LIMIT = 20 # RN-49

    def self.call(...) = new(...).call

    def initialize(outbox_event_id)
      @outbox_event_id = outbox_event_id
    end

    def call
      ActiveRecord::Base.transaction do
        item = OutboxEvent.find(@outbox_event_id)
        # Ordem das travas igual à da ingestão: atendimento primeiro, depois o item. Escopo por marca (invariante 6).
        ticket = Ticket.lock.find_by!(id: item.ticket_id, brand_id: item.brand_id)
        item.lock!
        next Result.new(status: :already_done, turn: nil) if item.completed_at

        @ticket = ticket
        @item = item
        decide
      end
    end

    private

    attr_reader :ticket, :item

    def decide
      return not_opened(:skipped, reason: "fora_da_ia", state: ticket.state) unless ticket.with_ai?

      expected = item.payload["assignment_version"]
      if expected != ticket.assignment_version
        return not_opened(:stale_assignment, reason: "atribuicao_mudou", expected_version: expected,
                                             current_version: ticket.assignment_version)
      end

      covering = ticket.ai_turns.eligible.where(context_until_seq: ticket.latest_customer_seq...).order(:turn).last
      return not_opened(:covered, reason: "coberto", covered_by_turn: covering.turn) if covering

      window_closed? ? check_deadline : window_still_open
    end

    def now = @now ||= Time.current
    def window_closed? = ticket.dispatch_due_at && ticket.dispatch_due_at <= now

    # Uma ação de versão anterior não encurta a janela da mensagem mais recente (07, seção 3.4).
    def window_still_open
      return not_opened(:no_window, reason: "sem_janela") unless ticket.dispatch_due_at

      not_opened(:window_open, reason: "janela_aberta", dispatch_due_at: iso(ticket.dispatch_due_at))
    end

    # RN-46: o prazo é do ciclo, contado de first_pending_at, e vale para todos os turnos dele.
    def check_deadline
      return not_opened(:expired, reason: "sem_prazo") unless deadline_at
      return not_opened(:expired, reason: "prazo_vencido", deadline_at: iso(deadline_at)) if now >= deadline_at

      open_turn
    end

    def open_turn
      event_id = SecureRandom.uuid
      number = ticket.ai_turns.maximum(:turn).to_i + 1
      payload = Envelope.new(ticket:, event_id:, turn: number, pending:, history:, deadline_at:).to_h
      # Invariante 10, RN-44: fora do contrato é falha permanente; nada sai e a ação não é repetida.
      violations = HelpdeskContracts.errors(:agent_inbound, payload)
      return not_opened(:invalid, reason: "contrato", violations: violations.map(&:pointer)) if violations.any?

      turn = ticket.ai_turns.create!(
        brand_id: ticket.brand_id, turn: number, context_until_seq: ticket.latest_customer_seq,
        assignment_version: ticket.assignment_version, context: payload.fetch("context"), event_id:,
        status: "eligible", deadline_at:
      )
      OutboxEvent.create!(id: event_id, brand_id: ticket.brand_id, ticket:, event_type: EVENT_TYPE, payload:,
                          trace_id: item.trace_id, next_attempt_at: now)
      dispatch_due_at = ticket.dispatch_due_at
      ticket.update_columns(dispatch_due_at: nil)
      complete_item
      audit("ai_turn.opened", turn: number, event_id:, context_until_seq: turn.context_until_seq,
                              pending_seqs: pending.map(&:seq), deadline_at: iso(deadline_at),
                              dispatch_due_at: iso(dispatch_due_at))
      Result.new(status: :opened, turn:)
    end

    def not_opened(status, **data)
      complete_item
      audit("ai_turn.not_opened", **data)
      Result.new(status:, turn: nil)
    end

    def complete_item = item.update!(completed_at: now, lease_until: nil)

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

    def deadline_at = ticket.ai_deadline_at
    def iso(time) = time&.utc&.iso8601(3)

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket:, actor_type: "system", event_type:, trace_id: item.trace_id,
                         data: { dispatch_id: item.id, cover_until_seq: item.payload["cover_until_seq"] }.merge(data))
    end
  end
end
