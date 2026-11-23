# Alerta dos 80% do prazo de assunção (RN-25, RN-14): sobe a prioridade um nível (crítica não sobe), grava
# `sla_alerted_at`, recalcula o prazo pela prioridade nova (só encurta) e audita `sla.alerted` e, se a prioridade
# mudou, `ticket.priority_raised` com `reason: "sla_80"`. A fila humana se reordena pela prioridade nova (RN-29).
module Sla
  class Alert < Action
    private

    def specific_reason = ("ja_alertado" if ticket.sla_alerted_at)
    def deadline = Deadlines::SlaAlert.alert_at(ticket)

    def apply
      from = ticket.priority || "media"
      to = Handoff::Policy.for(ticket.brand).raised_priority(from)
      due_before = ticket.sla_due_at
      ticket.update_columns(priority: to, sla_alerted_at: db_now)
      due_after = Sla::Recalculate.call(ticket:)
      complete
      audit("ticket.priority_raised", from:, to:, reason: "sla_80") if to != from
      audit("sla.alerted", from:, to:, sla_due_at_before: iso(due_before), sla_due_at: iso(due_after))
      JsonLog.info("sla.alerted", trace_id: item.trace_id, ticket_id: ticket.id, from:, to:)
      Result.new(status: :alerted)
    end
  end
end
