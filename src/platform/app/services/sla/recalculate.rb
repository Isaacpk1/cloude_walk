# Prazo de assunção quando a prioridade sobe (RN-14, RN-25; 07, seção 3.5): `sla_started_at` mais o prazo da
# prioridade nova, e nunca depois do que já valia (a prioridade só sobe, então o prazo só encurta). O relógio não
# reinicia (RN-23). Sem SLA iniciado, não faz nada. Quem chama já travou o atendimento.
module Sla
  class Recalculate
    def self.call(...) = new(...).call

    def initialize(ticket:)
      @ticket = ticket
    end

    def call
      return @ticket.sla_due_at unless @ticket.sla_started_at && @ticket.sla_due_at

      candidate = @ticket.sla_started_at + Sla::Policy.for_ticket(@ticket).assume_seconds(@ticket.priority)
      due = [ candidate, @ticket.sla_due_at ].min
      @ticket.update_columns(sla_due_at: due) if due != @ticket.sla_due_at
      due
    end
  end
end
