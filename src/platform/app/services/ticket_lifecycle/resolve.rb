module TicketLifecycle
  # Chamado na transação e sob o lock do atendimento. Falha do resumo desfaz a resolução inteira.
  class Resolve
    def self.call(ticket:, source:, reason:, now:, trace_id:)
      ticket.update_columns(state: "resolvido", resolved_at: now, resolution_source: source,
                            resolution_reason: reason, close_due_at: now + 72.hours,
                            waiting_since: nil, reminder_due_at: nil, inactivity_due_at: nil, updated_at: now)
      summary = TicketSummary.create!(brand_id: ticket.brand_id, ticket_id: ticket.id,
                                      assignment_version: ticket.assignment_version, resolved_at: now,
                                      body: Summary.call(ticket:, reason:), created_at: now)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system",
                         event_type: "ticket.summary_recorded", trace_id:,
                         data: { summary_id: summary.id, assignment_version: ticket.assignment_version })
    end
  end
end
