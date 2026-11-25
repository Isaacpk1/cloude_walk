module TicketLifecycle
  module Wait
    # Entrega confirmada com o atendimento já travado. Uma resposta velha não inicia espera nova.
    def self.start(ticket:, delivery:, now:)
      return unless %w[reply analyst].include?(delivery.kind) && %w[com_ia com_analista aguardando_cliente].include?(ticket.state)
      return unless delivery.seq > ticket.latest_customer_seq
      return if delivery.ai_assignment_version && delivery.ai_assignment_version != ticket.assignment_version

      ticket.update_columns(state: "aguardando_cliente", waiting_since: now, reminder_due_at: now + 24.hours,
                            inactivity_due_at: now + 48.hours, updated_at: now)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system",
                         event_type: "ticket.waiting_for_customer", trace_id: delivery.trace_id,
                         data: { delivery_id: delivery.delivery_id, waiting_since: now.utc.iso8601(6) })
    end

    def self.finish(ticket:, now:, trace_id:)
      return unless ticket.state == "aguardando_cliente" && ticket.waiting_since

      state = ticket.assignee&.kind == "human" ? "com_analista" : "com_ia"
      ticket.update_columns(state:, waiting_since: nil, reminder_due_at: nil, inactivity_due_at: nil, updated_at: now)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system",
                         event_type: "ticket.customer_returned", trace_id:, data: { state_to: state })
    end
  end
end
