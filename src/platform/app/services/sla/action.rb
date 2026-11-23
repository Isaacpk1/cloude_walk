# Base dos workers dos alertas de SLA (RN-25, RN-26; 07, seção 3.5; ADR-016):
#
#   Sla::Alert.call(outbox_event_id)  / Sla::Breach.call(outbox_event_id)
#   # => Result(status:, reason:, next_attempt_at:)  status: :alerted | :breached | :discarded | :not_due | :already_done | :skipped
#
# Uma transação, com o atendimento travado antes do item (a ordem do resto do sistema) e escopo pela marca do item
# (invariante 6). Revalida com o relógio do banco lido depois do lock: o caso ainda espera na fila, sem analista,
# na mesma atribuição, e o prazo venceu. Obsoleto: descarte auditado (`sla.action_discarded`). Ainda não vencido
# pelo relógio do banco: o item fica aberto, com o despertador no prazo (nunca é descartado, senão a chave
# consumida esconderia o prazo). O item encerra na transação do efeito ou do descarte.
module Sla
  class Action
    Result = Data.define(:status, :reason, :next_attempt_at) do
      def initialize(reason: nil, next_attempt_at: nil, **) = super
    end

    def self.call(...) = new(...).call

    def initialize(outbox_event_id)
      @id = outbox_event_id
    end

    def call
      ActiveRecord::Base.transaction do
        @item = OutboxEvent.find_by(id: @id)
        next Result.new(status: :skipped) unless @item

        @ticket = Ticket.lock.find_by(id: @item.ticket_id, brand_id: @item.brand_id)
        @item.lock!
        next Result.new(status: :already_done) if @item.completed_at

        @db_now = DatabaseClock.now # depois do lock
        judge
      end
    end

    private

    attr_reader :item, :ticket, :db_now

    def judge
      reason = obsolete_reason
      return discard(reason) if reason

      due_at = deadline
      return not_due(due_at) if db_now < due_at

      apply
    end

    def obsolete_reason
      return "atendimento_inexistente" unless ticket
      return "atribuicao_mudou" if ticket.assignment_version != item.payload["assignment_version"]
      return "atribuido" if ticket.state != "aguardando_humano" || ticket.assignee_id
      return "sem_sla" unless ticket.sla_started_at && ticket.sla_due_at

      specific_reason
    end

    def not_due(due_at)
      item.update!(next_attempt_at: due_at, lease_until: nil)
      Result.new(status: :not_due, next_attempt_at: due_at)
    end

    def discard(reason)
      complete(last_error: reason)
      audit("sla.action_discarded", reason:, action: item.event_type)
      JsonLog.info("deadline.discarded", trace_id: item.trace_id, outbox_event_id: item.id, event_type: item.event_type, reason:)
      Result.new(status: :discarded, reason:)
    end

    def complete(last_error: nil) = item.update!(completed_at: Time.current, lease_until: nil, last_error:)

    def iso(time) = time.utc.iso8601(3)

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: item.brand_id, ticket_id: ticket&.id, actor_type: "system", event_type:,
                         trace_id: item.trace_id, data: { outbox_event_id: item.id }.merge(data))
    end
  end
end
