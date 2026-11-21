# Espera intencional de cada turno na linha do tempo (RN-55, RNF-03; 07, seção 3.4). Vai do commit da
# primeira mensagem pendente que o turno leva até o fim da janela (dispatch_due_at). Depois dele, o
# scheduler grava a ação "turn.dispatch" e o worker abre o turno (ADR-016): esse atraso é overhead da
# plataforma, não espera intencional, e aparece só no detalhe (RNF-03). Lida de ai_turns, das
# mensagens e da auditoria ai_turn.opened.
#
# Bloco 06: o detalhe mostra a janela usada (window_ms de ai_turn.opened ou do message.received da última
# pendente; sem eles, a Turns::Policy), se o teto (primeira pendente + 4 s) foi atingido e o
# context_version do turno. Isolamento por marca (invariante 6): auditoria filtrada pelo brand_id.
class TurnWindowEvents
  def initialize(ticket)
    @ticket = ticket
  end

  def events
    turns = @ticket.ai_turns.where(brand_id: @ticket.brand_id).to_a
    return [] if turns.empty?

    created = @ticket.messages.to_h { [ _1.seq, _1.created_at ] }
    opened = audits("ai_turn.opened").index_by { _1.data["event_id"] }
    turns.filter_map { window(_1, created, opened[_1.event_id]) }
  end

  private

  def audits(event_type)
    AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type:).order(:occurred_at, :id).to_a
  end

  def received_by_seq = @received_by_seq ||= audits("message.received").index_by { _1.data["seq"] }
  def policy = @policy ||= Turns::Policy.for(@ticket.brand)

  def window(turn, created, audit)
    seqs = Array(turn.context["pending_messages"]).map { _1["seq"] }
    started_at = created[seqs.min]
    return unless started_at

    due = audit&.data&.dig("dispatch_due_at")&.then { Time.zone.parse(_1) } || turn.created_at
    finished_at = due.clamp(started_at, [ turn.created_at, started_at ].max)
    TimelineView::Event.new(kind: :intentional_wait, started_at:, finished_at:, ticket_id: @ticket.id.to_s,
                            seq: turn.context_until_seq, turn: turn.turn, trace_id: audit&.trace_id,
                            source: DataSource::SYSTEM,
                            detail: "#{detail(turn, seqs, finished_at)}; #{rule(turn, seqs, started_at, due, audit)}")
  end

  def detail(turn, seqs, window_end)
    delay = TimelineView::Event.ms_between(window_end, turn.created_at)
    "Fim da janela de agrupamento às #{clock(window_end)} UTC: o scheduler gravou turn.dispatch " \
      "e o worker abriu o turno #{turn.turn} com as mensagens seq #{seqs.min} a #{seqs.max} " \
      "(turno aberto #{delay} ms depois)"
  end

  # Qual regra encerrou a espera: a janela do canal depois da última pendente ou o teto desde a primeira.
  def rule(turn, seqs, first_at, due, audit)
    last_received = received_by_seq[seqs.max]&.data || {}
    channel = audit&.data&.dig("channel") || @ticket.channel
    window_ms = audit&.data&.dig("window_ms") || last_received["window_ms"] || (policy.window_for(channel) * 1000).to_i
    ceiling_at = last_received["ceiling_at"]&.then { Time.zone.parse(_1) } || (first_at + policy.ceiling)
    window = window_ms.zero? ? "sem janela no #{channel}" : "janela de #{window_ms} ms no #{channel}"
    ceiling = due >= ceiling_at ? "teto de 4 s atingido às #{clock(ceiling_at)} UTC" : "teto não atingido"
    version = turn.context_version.nil? ? "sem context_version (anterior ao bloco 06)" : "context_version #{turn.context_version}"
    "#{window}, #{ceiling}, #{version}"
  end

  def clock(time) = time.utc.strftime("%H:%M:%S.%L")
end
