# Abertura e recusa de turnos na linha do tempo (RN-49, RN-55, RF-56; 07, seção 3.4), lidas da auditoria
# ai_turn.opened e ai_turn.not_opened (formato do bloco 06).
# - Abertura do turno: as mensagens pendentes e as do histórico que o turno levou, os tamanhos em
#   caracteres, o context_version e o digest abreviado. Sem os campos do bloco 06, usa ai_turns.context.
# - Turno não aberto: só as recusas terminais (Turns::Open::TERMINAL_REASONS): contexto_excede_limite (RN-49),
#   com o tamanho das pendentes e o limite, e prazo_vencido, sem_prazo e contrato (RN-46). O handoff fica pendente (bloco 10).
#   Os outros motivos (coberto, janela_aberta, fora_da_ia...) são rotina do scheduler e ficam fora.
# Isolamento por marca (invariante 6): auditoria e turnos filtrados pelo brand_id do atendimento.
class TurnContextEvents
  TOO_LARGE = "contexto_excede_limite".freeze

  def initialize(ticket)
    @ticket = ticket
  end

  def events
    opened = audits.select { _1.event_type == "ai_turn.opened" }.index_by { _1.data["event_id"] }
    turns = @ticket.ai_turns.where(brand_id: @ticket.brand_id).order(:turn).to_a
    turns.map { opened_event(_1, opened[_1.event_id]) } + audits.filter_map { not_opened_event(_1) }
  end

  private

  def audits
    @audits ||= AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id,
                                 event_type: %w[ai_turn.opened ai_turn.not_opened]).order(:occurred_at, :id).to_a
  end

  def opened_event(turn, audit)
    data = audit&.data || {}
    context = turn.context || {}
    pending = data["pending_seqs"] || Array(context["pending_messages"]).map { _1["seq"] }
    history = data["history_seqs"] || Array(context["history"]).map { _1["seq"] }
    pending_chars = data["pending_chars"] || chars(context["pending_messages"])
    context_chars = data["context_chars"] || (pending_chars + chars(context["history"]))
    TimelineView::Event.new(
      kind: :turn_opened, started_at: turn.created_at, finished_at: turn.created_at, ticket_id: @ticket.id.to_s,
      seq: turn.context_until_seq, turn: turn.turn, trace_id: audit&.trace_id, source: DataSource::SYSTEM,
      detail: "Turno #{turn.turn} aberto com as pendentes seq #{list(pending)} e o histórico seq #{list(history)}: " \
              "#{pending_chars} caracteres pendentes, #{context_chars} no contexto; #{version(turn)}"
    )
  end

  # Só as recusas terminais do ciclo (Turns::Open::TERMINAL_REASONS); o handoff com o histórico é do bloco 10.
  def not_opened_event(audit)
    return unless audit.event_type == "ai_turn.not_opened" && Turns::Open::TERMINAL_REASONS.include?(audit.data["reason"])

    data = audit.data
    seqs = Array(data["pending_seqs"])
    seq = seqs.max || data["cover_until_seq"]
    TimelineView::Event.new(
      kind: :turn_not_opened, started_at: audit.occurred_at, finished_at: audit.occurred_at, ticket_id: @ticket.id.to_s,
      seq:, turn: nil, trace_id: audit.trace_id, source: DataSource::SYSTEM,
      detail: "Turno não aberto (#{data['reason']}): #{refusal_numbers(data)}" \
              "#{seqs.any? ? " nas mensagens seq #{list(seqs)}" : " até a seq #{seq}"}; #{pending_handoff(data['reason'])}"
    )
  end

  def refusal_numbers(data)
    case data["reason"]
    when TOO_LARGE then "#{data['pending_chars']} caracteres pendentes, acima do limite de #{data['limit']}"
    when "prazo_vencido" then "teto do ciclo #{panel_time(data['deadline_at'])} vencido antes da abertura"
    when "contrato" then "evento fora do contrato agent_inbound (#{Array(data['violations']).join(', ')})"
    else "sem teto do ciclo gravado"
    end
  end

  def pending_handoff(reason) = "handoff para humano pendente (bloco 10; #{reason == TOO_LARGE ? 'RN-49' : 'RN-46'})"

  def panel_time(iso) = iso && PanelClock.format(Time.zone.parse(iso), precise: true)
  def chars(items) = Array(items).sum { _1["text"].to_s.length }
  def list(seqs) = seqs.empty? ? "nenhuma" : seqs.join(", ")

  def version(turn)
    return "turno anterior ao bloco 06 (sem context_version nem digest)" if turn.context_digest.nil?

    "context_version #{turn.context_version}, digest #{turn.context_digest.delete_prefix('sha256:').first(12)}"
  end
end
