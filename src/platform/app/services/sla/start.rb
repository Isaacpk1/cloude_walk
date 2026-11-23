# Início do SLA de assunção quando o caso entra na fila humana pela primeira vez (RN-21, RN-22, RN-23; 07,
# seção 3.5), na transação do handoff ou da triagem, com o atendimento já travado:
#
#   Sla::Start.call(ticket:, now: Time.current) # => sla_due_at
#
# Grava `sla_started_at = now` e `sla_due_at = now + assume` da política da fila para a prioridade. Nunca reinicia:
# escalar de novo, devolver à fila ou transferir mantêm o relógio (RN-23, RN-32).
module Sla
  class Start
    def self.call(...) = new(...).call

    def initialize(ticket:, now: Time.current)
      @ticket = ticket
      @now = now
    end

    def call
      return @ticket.sla_due_at if @ticket.sla_started_at

      due = @now + Sla::Policy.for_ticket(@ticket).assume_seconds(@ticket.priority)
      @ticket.update_columns(sla_started_at: @now, sla_due_at: due)
      due
    end
  end
end
