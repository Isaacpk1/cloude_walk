# Faz o papel da ingestão e do scheduler do bloco 03 nos testes do worker, sem depender deles:
# grava os prazos do ciclo direto no atendimento e a ação "turn.dispatch" no outbox (07, seção 3.4).
module TurnDispatchHelpers
  AI_DEADLINE = 60.seconds # RN-46, ADR-020: teto do ciclo

  # Abre o ciclo pendente, se ainda não houver, e marca o fim da janela (dispatch_due_at).
  def start_cycle(ticket, dispatch_due_at: Time.current, ai_deadline_at: nil)
    ticket.reload
    first = first_pending_message(ticket)
    first_pending_at = ticket.first_pending_at || first.created_at
    ticket.update_columns(first_pending_seq: ticket.first_pending_seq || first.seq, first_pending_at:,
                          ai_deadline_at: ai_deadline_at || ticket.ai_deadline_at || (first_pending_at + AI_DEADLINE),
                          dispatch_due_at:)
    ticket
  end

  # A janela venceu e o scheduler gravou a ação. Repetir devolve a mesma ação (chave única do outbox).
  def due_dispatch(received)
    ticket = received.respond_to?(:ticket) ? received.ticket.reload : received.reload
    key = "turn.dispatch:#{ticket.id}:#{ticket.assignment_version}:#{ticket.latest_customer_seq}"
    OutboxEvent.find_by(dedup_key: key) || begin
      due = ticket.dispatch_due_at
      start_cycle(ticket, dispatch_due_at: due.nil? || due > Time.current ? Time.current : due)
      create(:turn_dispatch, for_ticket: ticket)
    end
  end

  def open_turn_for(received) = Turns::Open.call(due_dispatch(received).id).turn

  private

  def first_pending_message(ticket)
    answered_until = ticket.messages.where(direction: "outbound", internal: false).maximum(:seq).to_i
    ticket.messages.where(direction: "inbound", author_type: "customer").where(seq: (answered_until + 1)..).first
  end
end

RSpec.configure { |c| c.include TurnDispatchHelpers }
