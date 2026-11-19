# Espera intencional de cada turno na linha do tempo (RN-55, RNF-03; 07, seção 3.4). Vai do commit da
# primeira mensagem pendente que o turno leva até o fim da janela (dispatch_due_at). Depois dele, o
# scheduler grava a ação "turn.dispatch" e o worker abre o turno (ADR-016): esse atraso é overhead da
# plataforma, não espera intencional, e aparece só no detalhe (RNF-03). Lida de ai_turns, das
# mensagens e da auditoria ai_turn.opened.
class TurnWindowEvents
  def initialize(ticket)
    @ticket = ticket
  end

  def events
    turns = @ticket.ai_turns.to_a
    return [] if turns.empty?

    created = @ticket.messages.to_h { [ _1.seq, _1.created_at ] }
    opened = AuditEvent.where(ticket_id: @ticket.id, event_type: "ai_turn.opened").index_by { _1.data["event_id"] }
    turns.filter_map { window(_1, created, opened[_1.event_id]) }
  end

  private

  def window(turn, created, audit)
    seqs = Array(turn.context["pending_messages"]).map { _1["seq"] }
    started_at = created[seqs.min]
    return unless started_at

    due = audit&.data&.dig("dispatch_due_at")&.then { Time.zone.parse(_1) } || turn.created_at
    finished_at = due.clamp(started_at, [ turn.created_at, started_at ].max)
    TimelineView::Event.new(kind: :intentional_wait, started_at:, finished_at:, ticket_id: @ticket.id.to_s,
                            seq: turn.context_until_seq, turn: turn.turn, trace_id: audit&.trace_id,
                            source: DataSource::SYSTEM, detail: detail(turn, seqs, finished_at))
  end

  def detail(turn, seqs, window_end)
    delay = TimelineView::Event.ms_between(window_end, turn.created_at)
    "Fim da janela de agrupamento às #{window_end.utc.strftime('%H:%M:%S.%L')} UTC: o scheduler gravou turn.dispatch " \
      "e o worker abriu o turno #{turn.turn} com as mensagens seq #{seqs.min} a #{seqs.max} " \
      "(turno aberto #{delay} ms depois)"
  end
end
