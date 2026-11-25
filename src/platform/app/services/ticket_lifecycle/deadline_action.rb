module TicketLifecycle
  class DeadlineAction
    TYPES = { "customer.reminder" => Deadlines::CustomerReminder, "customer.inactivity" => Deadlines::CustomerInactivity,
              "ticket.close" => Deadlines::TicketClose }.freeze
    Result = Data.define(:status, :next_attempt_at, :delivery_event_id) do
      def initialize(next_attempt_at: nil, delivery_event_id: nil, **) = super
    end

    def self.call(id) = new(id).call

    def initialize(id) = @id = id

    def call
      ActiveRecord::Base.transaction do
        @item = OutboxEvent.find_by(id: @id, event_type: TYPES.keys)
        next Result.new(status: :skipped) unless @item

        @ticket = Ticket.lock(Ticket::ROW_LOCK).find_by(id: @item.ticket_id, brand_id: @item.brand_id)
        @item.lock!
        next Result.new(status: :already_done) if @item.completed_at

        @now = DatabaseClock.now
        apply_if_due
      end
    end

    private

    def apply_if_due
      registration = TYPES.fetch(@item.event_type)
      deadline = @ticket&.public_send(registration::COLUMN)
      unless @ticket && @ticket.state == registration::STATE && @ticket.assignment_version == @item.payload["assignment_version"] &&
             deadline&.utc&.iso8601(6) == @item.payload["deadline_at"]
        return discard("ciclo_mudou")
      end
      due = @item.event_type == "ticket.close" ? @now > deadline : @now >= deadline
      unless due
        next_at = @item.event_type == "ticket.close" ? deadline + 0.000001.seconds : deadline
        @item.update!(next_attempt_at: next_at, lease_until: nil)
        return Result.new(status: :not_due, next_attempt_at: next_at)
      end
      case @item.event_type
      when "customer.reminder" then remind
      when "customer.inactivity" then resolve
      when "ticket.close" then close
      end
    end

    def remind
      return discard("inatividade_vencida") if @now >= @ticket.inactivity_due_at

      event_id = Reminder.call(ticket: @ticket, trace_id: @item.trace_id, now: @now)
      complete
      Result.new(status: :reminded, delivery_event_id: event_id)
    end

    def resolve
      from = @ticket.state
      Distribution::Slot.release!(user_id: @ticket.assignee_id) if @ticket.assignee&.kind == "human"
      Resolve.call(ticket: @ticket, source: "inactivity", reason: "sem_resposta_do_cliente", now: @now, trace_id: @item.trace_id)
      audit("ticket.resolved", reason: "sem_resposta_do_cliente", state_from: from, state_to: "resolvido")
      complete
      Result.new(status: :resolved)
    end

    def close
      @ticket.update_columns(state: "fechado", updated_at: @now)
      audit("ticket.closed", state_from: "resolvido", state_to: "fechado")
      complete
      Result.new(status: :closed)
    end

    def discard(reason)
      audit("ticket.lifecycle_discarded", reason:)
      complete(error: reason)
      Result.new(status: :discarded)
    end

    def complete(error: nil) = @item.update!(completed_at: @now, lease_until: nil, last_error: error)

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: @item.brand_id, ticket_id: @ticket&.id, actor_type: "system", event_type:,
                         trace_id: @item.trace_id, data: data.merge(outbox_event_id: @item.id))
    end
  end
end
