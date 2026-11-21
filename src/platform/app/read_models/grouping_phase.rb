# Lê a fase de agrupamento de um atendimento (RN-55, RF-55; 07, seção 3.4) do ciclo gravado em tickets
# (first_pending_at, dispatch_due_at), das mensagens e da auditoria message.received da última mensagem
# (window_ms e ceiling_at, a partir do bloco 06). Sem esses campos na auditoria, usa a Turns::Policy da
# marca. Fora da IA, sem ciclo ou com um turno elegível que já cobre a última mensagem: sem fase.
# Isolamento por marca (invariante 6): mensagens e auditoria filtradas pelo brand_id do atendimento.
class GroupingPhase
  def initialize(ticket, now: Time.current)
    @ticket = ticket
    @now = now
  end

  def view
    return unless grouping?

    ConversationView::Grouping.new(
      pending_seqs: pending_seqs, channel: @ticket.channel, window_ms:, dispatch_due_at: @ticket.dispatch_due_at,
      ceiling_at:, prevails:, overdue: @ticket.dispatch_due_at < @now
    )
  end

  private

  def grouping?
    @ticket.with_ai? && @ticket.dispatch_due_at && @ticket.first_pending_at &&
      !@ticket.ai_turns.where(brand_id: @ticket.brand_id, status: "eligible")
              .exists?([ "context_until_seq >= ?", @ticket.latest_customer_seq ])
  end

  def policy = @policy ||= Turns::Policy.for(@ticket.brand)

  # As mesmas que o Turns::Open vai mandar: do cliente, depois da última saída visível ao cliente.
  def pending_seqs
    messages = Message.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id)
    answered_until = messages.where(direction: "outbound", internal: false).maximum(:seq).to_i
    messages.where(direction: "inbound", author_type: "customer").where(seq: (answered_until + 1)..).order(:seq).pluck(:seq)
  end

  def last_received
    @last_received ||= AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: "message.received")
                                 .order(:occurred_at, :id).last&.data || {}
  end

  def window_ms = last_received["window_ms"] || (policy.window_for(@ticket.channel) * 1000).to_i

  def ceiling_at
    last_received["ceiling_at"]&.then { Time.zone.parse(_1) } || (@ticket.first_pending_at + policy.ceiling)
  end

  def prevails
    return :none if window_ms.zero?

    @ticket.dispatch_due_at >= ceiling_at ? :ceiling : :window
  end
end
