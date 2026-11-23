# Estouro do prazo de assunção (RN-26): marca o caso como fora do SLA, de forma permanente (o banco recusa
# desfazer), e audita `sla.breached` com o atraso. O painel mostra o caso em destaque para o supervisor.
module Sla
  class Breach < Action
    private

    def specific_reason = ("ja_estourado" if ticket.sla_breached)
    def deadline = ticket.sla_due_at

    def apply
      ticket.update_columns(sla_breached: true)
      complete
      audit("sla.breached", sla_due_at: iso(ticket.sla_due_at), late_ms: ((db_now - ticket.sla_due_at) * 1000).round,
                            priority: ticket.priority)
      JsonLog.info("sla.breached", trace_id: item.trace_id, ticket_id: ticket.id)
      Result.new(status: :breached)
    end
  end
end
