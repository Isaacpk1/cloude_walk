# Lê a recusa terminal do turno da última mensagem (RN-49, RN-46; 07, seção 3.4) da auditoria
# ai_turn.not_opened gravada pelo Turns::Open. Há recusa quando o caso está com a IA, a última recusa terminal
# cobre latest_customer_seq (cover_until_seq) e nenhum turno elegível a cobre. Uma mensagem nova do cliente
# sobe latest_customer_seq e a recusa deixa de valer: volta a fase de agrupamento.
# Isolamento por marca (invariante 6): auditoria, turnos e mensagens filtrados pelo brand_id do atendimento.
class TurnRefusalPhase
  def initialize(ticket)
    @ticket = ticket
  end

  def view
    audit = last_terminal_refusal
    return unless audit && @ticket.with_ai? && !covered?

    data = audit.data
    ConversationView::TurnRefusal.new(
      reason: data["reason"], pending_seqs: data["pending_seqs"] || pending_seqs, pending_chars: data["pending_chars"],
      limit: data["limit"], violations: data["violations"], deadline_at: data["deadline_at"]&.then { Time.zone.parse(_1) },
      occurred_at: audit.occurred_at, trace_id: audit.trace_id
    )
  end

  private

  def last_terminal_refusal
    audit = AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: "ai_turn.not_opened")
                      .where("data->>'reason' IN (?)", Turns::Open::TERMINAL_REASONS)
                      .order(:occurred_at, :id).last
    audit if audit && audit.data["cover_until_seq"].to_i >= @ticket.latest_customer_seq
  end

  def covered?
    @ticket.ai_turns.where(brand_id: @ticket.brand_id, status: "eligible")
           .exists?([ "context_until_seq >= ?", @ticket.latest_customer_seq ])
  end

  # As mesmas do Turns::Open: do cliente, depois da última saída visível ao cliente.
  def pending_seqs
    messages = Message.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id)
    answered_until = messages.where(direction: "outbound", internal: false).maximum(:seq).to_i
    messages.where(direction: "inbound", author_type: "customer").where(seq: (answered_until + 1)..).order(:seq).pluck(:seq)
  end
end
