# Lê o handoff do atendimento para a conversa (ROADMAP 08; RN-46, RF-36, RNF-18; 07, seção 3.2) da auditoria no formato
# combinado dos blocos 08 e 09 (itens 1 e 5): o último handoff.requested e o seu desfecho, ticket.escalated (mesma
# from_assignment_version que a assignment_version do pedido) ou handoff.discarded (mesma assignment_version), e as
# saídas canceladas pelo handoff (delivery.cancelled com reason "handoff"). Também monta o histórico de escalação.
# Isolamento por marca (invariante 6): auditoria, fila, entregas e mensagens filtradas pelo brand_id do atendimento.
class HandoffPhase
  AUDITS = %w[handoff.requested ticket.escalated handoff.discarded delivery.cancelled].freeze
  AI = "IA".freeze

  def initialize(ticket)
    @ticket = ticket
  end

  def view
    request = of_type("handoff.requested").last
    request && handoff(request)
  end

  # O pedido que levou a cada escalação (ConversationView::Escalation), para o histórico de escalação da conversa.
  def escalations
    of_type("ticket.escalated").map do |audit|
      data = audit.data
      ConversationView::Escalation.new(
        occurred_at: audit.occurred_at, from: AI, to: queue_name(data["queue_id"]) || "fila padrão",
        trigger: ConversationView::Handoff.source_label(data["source"]),
        reason: ConversationView::Handoff.reason_label(data["reason"]), assignment_version: data["to_assignment_version"]
      )
    end
  end

  # A fila humana em que o caso está agora, se o último handoff o escalou (para o responsável atual da conversa).
  def current_queue_name
    current = view
    current.queue_name || "fila padrão" if current&.escalated? && !@ticket.with_ai?
  end

  private

  def audits
    @audits ||= AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: AUDITS).order(:occurred_at, :id).to_a
  end

  def of_type(type) = audits.select { _1.event_type == type }

  def outcome(request, type, key)
    version = request.data["assignment_version"]
    of_type(type).find { _1.data[key] == version && _1.id > request.id }
  end

  def handoff(request)
    data = request.data
    escalated = outcome(request, "ticket.escalated", "from_assignment_version")
    discarded = escalated ? nil : outcome(request, "handoff.discarded", "assignment_version")
    resolved = escalated || discarded
    ConversationView::Handoff.new(
      state: escalated ? :escalated : (discarded ? :discarded : :requested),
      reason: data["reason"], source: data["source"], turn: data["turn"], first_pending_seq: data["first_pending_seq"],
      requested_at: request.occurred_at, resolved_at: resolved&.occurred_at,
      discard_reason: discarded&.data&.dig("reason"), from_assignment_version: escalated&.data&.dig("from_assignment_version"),
      to_assignment_version: escalated&.data&.dig("to_assignment_version"), queue_id: escalated&.data&.dig("queue_id"),
      queue_name: escalated && queue_name(escalated.data["queue_id"]), waited_ms: escalated && waited_ms(data, escalated),
      cancelled_deliveries: escalated ? cancelled_by_handoff(escalated.data["from_assignment_version"]) : [],
      trace_id: request.trace_id
    )
  end

  def queue_name(queue_id)
    return if queue_id.nil?

    queue = HelpdeskQueue.includes(:current_version).find_by(brand_id: @ticket.brand_id, id: queue_id)
    return unless queue

    version = @ticket.queue_id == queue.id && @ticket.queue_version ? queue.versions.find_by(version: @ticket.queue_version) : nil
    (version || queue.current_version)&.name
  end

  # RNF-18: da gravação da primeira mensagem pendente do ciclo até a entrada na fila humana.
  def waited_ms(data, escalated)
    first = Message.find_by(brand_id: @ticket.brand_id, ticket_id: @ticket.id, seq: data["first_pending_seq"])
    first && TimelineView::Event.ms_between(first.created_at, escalated.occurred_at)
  end

  def cancelled_by_handoff(assignment_version)
    ids = of_type("delivery.cancelled").select { _1.data["reason"] == "handoff" }.map { _1.data["delivery_id"] }
    Delivery.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, delivery_id: ids, ai_assignment_version: assignment_version)
            .order(:seq).map { ConversationView::Handoff::CancelledDelivery.new(delivery_id: _1.delivery_id, seq: _1.seq, kind: _1.kind) }
  end
end
