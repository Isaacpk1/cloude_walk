# Lê os prazos do atendimento para a conversa (ROADMAP 08; RN-46, RN-57, RF-36; 07, seção 3.4): o ciclo gravado em
# tickets (first_pending_*, ai_deadline_at, progress_due_at), o turno eligible da atribuição atual (ai_turns.deadline_at)
# e o aviso de progresso do ciclo, na interface combinada dos blocos 08 e 09 (item 5): a entrega kind "progress" com
# ai_first_pending_seq, progress.notice_scheduled (deadline_at, delay_ms), progress.notice_sent (delivery_id, seq),
# progress.notice_discarded (reason) e delivery.cancelled (reason resposta_aplicada ou handoff).
#
# O ciclo é identificado por first_pending_seq (a seq da primeira pendente, única por ciclo). Fechado o ciclo, o aviso
# do último ciclo continua visível até a próxima mensagem do cliente. Fora da IA: sem bloco (o handoff é o HandoffPhase).
# Isolamento por marca (invariante 6): turnos, entregas, mensagens e auditoria filtrados pelo brand_id do atendimento.
class DeadlinesPhase
  AUDITS = %w[progress.notice_scheduled progress.notice_sent progress.notice_discarded delivery.cancelled].freeze

  def initialize(ticket, now: Time.current)
    @ticket = ticket
    @now = now
  end

  def view
    return unless @ticket.with_ai?

    pending = !@ticket.first_pending_at.nil?
    progress = pending ? progress_for(@ticket.first_pending_seq) : last_cycle_progress
    return unless pending || progress

    turn = pending ? current_turn : nil
    ConversationView::Deadlines.new(
      pending:, first_pending_seq: @ticket.first_pending_seq, first_pending_at: @ticket.first_pending_at,
      ai_deadline_at: @ticket.ai_deadline_at, remaining_ms: ms_until(@ticket.ai_deadline_at), turn: turn&.turn,
      turn_deadline_at: turn&.deadline_at, turn_remaining_ms: ms_until(turn&.deadline_at), progress:
    )
  end

  private

  def ms_until(time) = time && TimelineView::Event.ms_between(@now, time)

  def current_turn
    @ticket.ai_turns.where(brand_id: @ticket.brand_id, status: "eligible", assignment_version: @ticket.assignment_version)
           .reorder(turn: :desc).first
  end

  def audits
    @audits ||= AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: AUDITS)
                          .order(:occurred_at, :id).to_a
  end

  def audit_for(type, cycle_seq)
    audits.reverse.find { _1.event_type == type && _1.data["first_pending_seq"] == cycle_seq }
  end

  def progress_deliveries
    @progress_deliveries ||= Delivery.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, kind: "progress").order(:seq).to_a
  end

  def progress_for(cycle_seq)
    delivery = progress_deliveries.reverse.find { _1.ai_first_pending_seq == cycle_seq }
    return delivered_notice(delivery, cycle_seq) if delivery

    scheduled = audit_for("progress.notice_scheduled", cycle_seq)
    discarded = audit_for("progress.notice_discarded", cycle_seq)
    return notice(:discarded, cycle_seq, scheduled, occurred_at: discarded.occurred_at, reason: discarded.data["reason"], trace_id: discarded.trace_id) if discarded
    return unless @ticket.progress_due_at || scheduled

    due_at = @ticket.progress_due_at || parse(scheduled.data["deadline_at"])
    notice(:scheduled, cycle_seq, scheduled, overdue: scheduled.nil? && due_at < @now)
  end

  def delivered_notice(delivery, cycle_seq)
    sent = audits.find { _1.event_type == "progress.notice_sent" && _1.data["delivery_id"] == delivery.delivery_id }
    cancelled = audits.reverse.find { _1.event_type == "delivery.cancelled" && _1.data["delivery_id"] == delivery.delivery_id }
    notice(delivery.status == "cancelled" ? :cancelled : :sent, cycle_seq, audit_for("progress.notice_scheduled", cycle_seq),
           occurred_at: sent&.occurred_at || delivery.created_at, delivery_id: delivery.delivery_id, seq: delivery.seq,
           delivery_status: delivery.status, reason: cancelled&.data&.dig("reason"), trace_id: delivery.trace_id)
  end

  def notice(state, cycle_seq, scheduled, **facts)
    due_at = parse(scheduled&.data&.dig("deadline_at")) || (cycle_seq == @ticket.first_pending_seq ? @ticket.progress_due_at : nil)
    ConversationView::ProgressNotice.new(state:, first_pending_seq: cycle_seq, due_at:, scheduled_at: scheduled&.occurred_at,
                                         delay_ms: scheduled&.data&.dig("delay_ms"), **facts)
  end

  # Ciclo encerrado: o aviso (enviado, cancelado ou descartado) do último ciclo com aviso, se nenhuma mensagem do
  # cliente chegou depois dele (senão é de um ciclo anterior ao último).
  def last_cycle_progress
    seqs = progress_deliveries.filter_map(&:ai_first_pending_seq) +
           audits.select { _1.event_type == "progress.notice_discarded" }.filter_map { _1.data["first_pending_seq"] }
    progress = seqs.max&.then { progress_for(_1) }
    return unless progress&.occurred_at

    later = Message.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, direction: "inbound", author_type: "customer")
                   .where(seq: (progress.first_pending_seq + 1)..).where("created_at > ?", progress.occurred_at)
    progress unless later.exists?
  end

  def parse(value) = value && Time.zone.parse(value)
end
