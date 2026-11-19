# Atendimento com abertura de turno pendente (07, seção 3.4; ADR-016), para os testes do scheduler.
# Grava a mensagem pelo caminho real da ingestão e fixa os prazos do ciclo, para o teste não depender
# do cálculo da janela (Turns::Window, coberto nos testes da ingestão).
module DeadlineHelpers
  def pending_dispatch(due_at:, **)
    result = ingest(**)
    ticket = result.ticket
    first_at = ticket.first_pending_at || due_at - 1.5.seconds
    ticket.update_columns(first_pending_seq: ticket.first_pending_seq || result.message.seq, first_pending_at: first_at,
                          dispatch_due_at: due_at, ai_deadline_at: first_at + 30.seconds)
    ticket.reload
  end

  def dispatch_items = OutboxEvent.where(event_type: Deadlines::DispatchDue::EVENT_TYPE).order(:created_at, :id)
end

RSpec.configure { |c| c.include DeadlineHelpers }
