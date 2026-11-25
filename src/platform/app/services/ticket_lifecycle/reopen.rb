module TicketLifecycle
  # RN-08/RN-09: a ingestão já mantém a linha travada. Devolve nil quando é necessário criar outro caso.
  class Reopen
    def self.call(ticket:, text:, now:, trace_id:)
      return ticket unless ticket.state == "resolvido" && ticket.resolved_at

      if now > ticket.close_due_at
        ticket.update_columns(state: "fechado", updated_at: now)
        audit(ticket, "ticket.closed", trace_id:, reason: "prazo_de_reabertura", state_from: "resolvido", state_to: "fechado")
        return
      end
      human = Handoff::Policy.for(ticket.brand).human_request?(text, ticket.brand.locale)
      queue_version = QueueVersion.find_by(queue_id: ticket.queue_id, version: ticket.queue_version)
      ai = ticket.resolution_source == "agent" && !human && (queue_version.nil? || queue_version.ai_first)
      state = ai ? "com_ia" : "aguardando_humano"
      assignee_id = ai && ticket.assignee&.kind == "bot" ? ticket.assignee_id : nil
      ticket.update_columns(state:, assignee_id:, assignment_version: ticket.assignment_version + 1,
                            resolved_at: nil, close_due_at: nil, resolution_source: nil, resolution_reason: nil,
                            ai_turns_count: 0, updated_at: now)
      Sla::Start.call(ticket:, now:) unless ai
      audit(ticket, "ticket.reopened", trace_id:, state_from: "resolvido", state_to: state,
                                      assignment_version: ticket.assignment_version, queue_id: ticket.queue_id)
      ticket
    end

    def self.audit(ticket, event_type, trace_id:, **data)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type:, trace_id:, data:)
    end
  end
end
