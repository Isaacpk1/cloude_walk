# Formato de leitura estável da linha do tempo de um atendimento (ROADMAP, "Linha do tempo").
# Os eventos se ligam ao atendimento, à mensagem e ao turno por ticket_id, seq, turn e trace_id.
class TimelineView < Data.define(:conversation_id, :ticket_id, :events, :source)
  def initialize(events:, **rest)
    super(events: events.sort_by.with_index { |event, i| [ event.started_at, i ] }.freeze, **rest)
  end

  def started_at = events.first&.started_at
  def finished_at = events.filter_map(&:finished_at).max

  def total_duration_ms
    return if started_at.nil? || finished_at.nil?

    TimelineView::Event.ms_between(started_at, finished_at)
  end

  def duration_ms_of(kind) = events.select { _1.kind == kind }.sum { _1.duration_ms.to_i }
  def offset_ms(event) = TimelineView::Event.ms_between(started_at, event.started_at)
  def events_for_turn(turn) = events.select { _1.turn == turn }

  # ROADMAP 09: as etapas que falharam, na ordem do fluxo, cada uma com os seus eventos de falha.
  def failures_by_stage
    failed = events.select(&:failure_label)
    TimelineView::Event::STAGES.keys.index_with { |stage| failed.select { _1.stage == stage } }
  end
end
