# Evento "DLQ" da linha do tempo do atendimento (ROADMAP 09; RF-37, RN-45). Um evento por linha de
# dead_letters correlacionada ao atendimento (brand_id e ticket_id, invariante 6), na hora da auditoria
# dead_letter.recorded (ou do registro, sem ela). dead_letter.audited é o mesmo fato com o desfecho
# "audited": não vira um segundo evento. O que ficou sem correlação não entra em nenhuma linha do tempo.
# O motivo e o desfecho vêm de DeadLetterView, num TimelineView::Error, como nas demais etapas.
class DeadLetterEvents
  def initialize(ticket)
    @ticket = ticket
  end

  def events
    records = DeadLetter.includes(:brand).where(brand_id: @ticket.brand_id, ticket_id: @ticket.id).order(:created_at, :id).to_a
    return [] if records.empty?

    recorded = AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: "dead_letter.recorded")
                         .order(:occurred_at, :id).index_by { _1.data["dead_letter_id"] }
    seqs = @ticket.ai_turns.where(brand_id: @ticket.brand_id).pluck(:turn, :context_until_seq).to_h
    records.map { event(DeadLetterView.from(_1), recorded[_1.id]&.occurred_at || _1.created_at, seqs) }
  end

  private

  def event(view, at, seqs)
    TimelineView::Event.new(
      kind: :dead_letter, started_at: at, finished_at: at, ticket_id: @ticket.id.to_s, seq: seqs[view.turn], turn: view.turn,
      trace_id: view.trace_id, source: DataSource::SYSTEM, dead_letter: view, error: self.class.error_for(view),
      detail: "#{view.source_label}: #{view.reason_label}, event_id #{view.event_id.to_s.first(8)} · #{view.outcome_label}"
    )
  end

  def self.error_for(view)
    TimelineView::Error.new(origin: "dlq_#{view.source}", http_status: nil, attempt: view.attempts.positive? ? view.attempts : nil,
                            message: "#{view.reason_label}; violações: #{view.violations_text}", retry: false,
                            next_attempt_at: nil, outcome: "dlq_#{view.outcome || 'pendente'}")
  end
end
