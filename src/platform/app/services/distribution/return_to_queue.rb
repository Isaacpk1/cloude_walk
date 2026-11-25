# Devolução à fila do caso de um analista offline (RN-31, RN-23, RN-32; 07, seção 3.5; ADR-016).
#
#   Distribution::ReturnToQueue.call(outbox_event_id) # => Result(status:, reason:, next_attempt_at:)
#   # status: :returned | :discarded | :not_due | :already_done | :skipped
#
# Chamado pelo OutboxJob para o item `analyst.offline`. Uma transação, com o atendimento travado antes do item e
# do usuário (a ordem do resto do sistema) e escopo pela marca do item (invariante 6). Revalida com o relógio do
# banco lido depois do lock: o mesmo responsável e a mesma atribuição, o caso ainda com o analista, o analista
# ainda offline e há pelo menos 10 min. Válido: o caso volta a `aguardando_humano`, sem responsável,
# `assignment_version + 1`, a vaga é liberada e `ticket.returned_to_queue` é auditado; o SLA não muda (`sla_started_at`
# e `sla_due_at` ficam como estavam). Obsoleto: descarte auditado (`ticket.return_discarded`). Ainda não vencido pelo
# relógio do banco: o item fica aberto, com o despertador no prazo (nunca é descartado, senão a chave consumida
# esconderia o prazo). O item encerra na transação do efeito ou do descarte.
module Distribution
  class ReturnToQueue
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

        @ticket = Ticket.lock(Ticket::ROW_LOCK).find_by(id: @item.ticket_id, brand_id: @item.brand_id)
        @item.lock!
        next Result.new(status: :already_done) if @item.completed_at

        judge
      end
    end

    private

    attr_reader :item, :ticket

    def payload = item.payload

    def judge
      return discard("atendimento_inexistente") unless ticket
      return discard("atribuicao_mudou") if ticket.assignee_id != payload["assignee_id"] ||
                                            ticket.assignment_version != payload["assignment_version"]
      return discard("fora_do_analista") unless Deadlines::AnalystOffline::STATES.include?(ticket.state)

      analyst = User.lock.find_by(id: ticket.assignee_id)
      return discard("analista_voltou") unless analyst&.status == "offline" && analyst.status_changed_at

      due_at = analyst.status_changed_at + Deadlines::AnalystOffline::OFFLINE_AFTER
      return not_due(due_at) if DatabaseClock.now < due_at

      give_back(analyst)
    end

    def give_back(analyst)
      from_state = ticket.state
      version = ticket.assignment_version + 1
      ticket.update_columns(state: "aguardando_humano", assignee_id: nil, assignment_version: version, updated_at: Time.current)
      Distribution::Slot.release!(user_id: analyst.id)
      complete
      audit("ticket.returned_to_queue", reason: "analista_offline", from_assignee_id: analyst.id, state_from: from_state,
                                        offline_since: iso(analyst.status_changed_at), sla_due_at: ticket.sla_due_at && iso(ticket.sla_due_at),
                                        assignment_version: version)
      JsonLog.info("ticket.returned_to_queue", trace_id: item.trace_id, ticket_id: ticket.id, assignee_id: analyst.id)
      Result.new(status: :returned, reason: "analista_offline")
    end

    def not_due(due_at)
      item.update!(next_attempt_at: due_at, lease_until: nil)
      Result.new(status: :not_due, next_attempt_at: due_at)
    end

    def discard(reason)
      complete(last_error: reason)
      audit("ticket.return_discarded", reason:, from_assignee_id: payload["assignee_id"],
                                       assignment_version: payload["assignment_version"])
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
