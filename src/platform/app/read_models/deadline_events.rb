# Prazos, handoff e aviso de progresso na linha do tempo (ROADMAP 08; RN-46, RN-57, RF-36, RF-56, RNF-18), lidos da
# auditoria no formato combinado dos blocos 08 e 09 (item 5). Cada evento se liga ao turno, ao seq e ao trace_id e
# leva o gatilho e o motivo (TimelineView::Cause). Durações:
# - registro do prazo (turn/cycle.timeout_scheduled, progress.notice_scheduled): do vencimento ao registro no outbox
#   (o atraso do scheduler, delay_ms);
# - turno expirado: do prazo do turno à expiração gravada;
# - pedido de handoff: do pedido ao desfecho (ticket.escalated ou handoff.discarded) pelo worker;
# - escalado para humano: da gravação da primeira mensagem pendente à entrada na fila humana (RNF-18: até T + 2 s);
# - aviso enviado ou descartado: do registro pelo scheduler à ação do worker.
# Isolamento por marca (invariante 6): auditoria, turnos, mensagens e fila filtrados pelo brand_id do atendimento.
class DeadlineEvents
  AUDITS = %w[turn.timeout_scheduled cycle.timeout_scheduled ai_turn.expired handoff.requested handoff.discarded
              ticket.escalated progress.notice_scheduled progress.notice_sent progress.notice_discarded
              turn.timeout_discarded cycle.timeout_discarded].freeze

  # Motivos do Deadlines::Expire#discard (07, seção 6): o timeout ficou obsoleto antes do worker.
  TIMEOUT_DISCARDS = {
    "turno_applied" => "a resposta da IA já tinha sido aplicada",
    "turno_superseded" => "o turno foi superado por uma mensagem nova do cliente",
    "turno_expired" => "o turno já estava expirado",
    "atribuicao_mudou" => "o atendimento mudou de responsável desde o registro",
    "fora_da_ia" => "o caso já não estava com a IA",
    "ciclo_encerrado" => "o ciclo já tinha sido encerrado",
    "ciclo_mudou" => "outro ciclo começou depois do registro"
  }.freeze

  def initialize(ticket)
    @ticket = ticket
  end

  def events = audits.filter_map { event_for(_1) }

  private

  def audits
    @audits ||= AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: AUDITS).order(:occurred_at, :id).to_a
  end

  def turns = @turns ||= @ticket.ai_turns.where(brand_id: @ticket.brand_id).index_by(&:turn)
  def created_by_seq = @created_by_seq ||= Message.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id).pluck(:seq, :created_at).to_h

  def event_for(audit)
    case audit.event_type
    when "turn.timeout_scheduled", "cycle.timeout_scheduled" then timeout_scheduled(audit)
    when "turn.timeout_discarded", "cycle.timeout_discarded" then timeout_discarded(audit)
    when "ai_turn.expired" then turn_expired(audit)
    when "handoff.requested" then handoff_requested(audit)
    when "handoff.discarded" then handoff_discarded(audit)
    when "ticket.escalated" then escalated(audit)
    when "progress.notice_scheduled" then progress_scheduled(audit)
    else progress_done(audit)
    end
  end

  def build(audit, kind, started_at:, seq:, turn:, detail:, cause:)
    started_at = [ started_at || audit.occurred_at, audit.occurred_at ].min
    TimelineView::Event.new(kind:, started_at:, finished_at: audit.occurred_at, ticket_id: @ticket.id.to_s, seq:, turn:,
                            trace_id: audit.trace_id, source: DataSource::SYSTEM, detail:, cause:)
  end

  def timeout_scheduled(audit)
    data = audit.data
    turn = audit.event_type == "turn.timeout_scheduled" ? data["turn"] : nil
    reason = turn ? "prazo_do_turno" : "teto_do_ciclo"
    what = turn ? "Prazo do turno #{turn}" : "Teto do ciclo (primeira pendente seq #{data['first_pending_seq']})"
    build(audit, :timeout_scheduled, started_at: parse(data["deadline_at"]), seq: seq_for(turn, data), turn:,
                                     detail: "#{what} vencido às #{clock(data['deadline_at'])}: o scheduler registrou " \
                                             "#{audit.event_type.delete_suffix('_scheduled')} no outbox #{data['delay_ms']} ms depois",
                                     cause: cause("scheduler", reason, "O worker revalida sob o lock e pede o handoff (RF-36)"))
  end

  def timeout_discarded(audit)
    data = audit.data
    turn = audit.event_type == "turn.timeout_discarded" ? data["turn"] : nil
    scheduled = audits.find { _1.event_type == audit.event_type.sub("_discarded", "_scheduled") && _1.id < audit.id && _1.data["turn"] == turn &&
                              _1.data["first_pending_seq"] == data["first_pending_seq"] }
    what = turn ? "Prazo do turno #{turn}" : "Teto do ciclo (primeira pendente seq #{data['first_pending_seq']})"
    label = TIMEOUT_DISCARDS.fetch(data["reason"], data["reason"])
    build(audit, :timeout_discarded, started_at: scheduled&.occurred_at, seq: seq_for(turn, data), turn:,
                                     detail: "#{what} descartado: #{label}",
                                     cause: TimelineView::Cause.new(origin: "worker", reason: data["reason"], reason_label: label,
                                                                    outcome: "Sem handoff: o caso continua como estava"))
  end

  def turn_expired(audit)
    data = audit.data
    build(audit, :turn_expired, started_at: parse(data["deadline_at"]), seq: seq_for(data["turn"], data), turn: data["turn"],
                                detail: "Turno #{data['turn']} expirado: prazo #{clock(data['deadline_at'])} vencido; " \
                                        "respostas da IA a partir daqui são rejeitadas (RN-46)",
                                cause: cause("worker", "prazo_do_turno", "Turno eligible → expired"))
  end

  def handoff_requested(audit)
    data = audit.data
    resolved = resolution_for(audit)
    finished = resolved ? resolved.occurred_at : audit.occurred_at
    outcome = if resolved.nil? then "Aguardando o worker do outbox (Handoff::Escalate)"
    elsif resolved.event_type == "ticket.escalated" then "Escalado para humano em #{ms(audit.occurred_at, finished)} ms"
    else "Descartado: #{ConversationView::Handoff.discard_reason_label(resolved.data['reason'])}"
    end
    TimelineView::Event.new(kind: :handoff_requested, started_at: audit.occurred_at, finished_at: finished,
                            ticket_id: @ticket.id.to_s, seq: seq_for(data["turn"], data), turn: data["turn"],
                            trace_id: audit.trace_id, source: DataSource::SYSTEM,
                            detail: "Pedido de handoff: #{reason_label(data['reason'])}; gatilho #{source_label(data['source'])}; " \
                                    "assignment_version #{data['assignment_version']}",
                            cause: cause(data["source"], data["reason"], outcome))
  end

  def handoff_discarded(audit)
    data = audit.data
    label = ConversationView::Handoff.discard_reason_label(data["reason"])
    build(audit, :handoff_discarded, started_at: nil, seq: seq_for(data["turn"], data), turn: data["turn"],
                                     detail: "Pedido de handoff (#{reason_label(data['handoff_reason'])}) descartado: #{label}",
                                     cause: TimelineView::Cause.new(origin: "worker", reason: data["reason"], reason_label: label,
                                                                    outcome: "O caso continua como estava"))
  end

  def escalated(audit)
    data = audit.data
    request = request_for(audit)
    first_seq = request&.data&.dig("first_pending_seq")
    started_at = created_by_seq[first_seq] || request&.occurred_at
    waited = started_at ? " #{ms(started_at, audit.occurred_at)} ms desde a primeira mensagem pendente (RNF-18)" : ""
    build(audit, :escalated, started_at:, seq: first_seq, turn: request&.data&.dig("turn"),
                             detail: "Escalado para a fila #{queue_name(data['queue_id'])} (assignment_version " \
                                     "#{data['from_assignment_version']} → #{data['to_assignment_version']}): " \
                                     "#{reason_label(data['reason'])};#{waited}",
                             cause: cause(data["source"], data["reason"], "Na fila humana: #{queue_name(data['queue_id'])}"))
  end

  def progress_scheduled(audit)
    data = audit.data
    deadline = data["deadline_at"] || data["progress_due_at"]
    build(audit, :progress_scheduled, started_at: parse(deadline), seq: data["first_pending_seq"], turn: nil,
                                      detail: "Aviso de progresso do ciclo da seq #{data['first_pending_seq']} vencido às " \
                                              "#{clock(deadline)}: o scheduler registrou progress.notice no " \
                                              "outbox #{data['delay_ms']} ms depois",
                                      cause: TimelineView::Cause.new(origin: "scheduler", reason: "aviso_de_progresso",
                                                                     reason_label: "15 s desde a primeira mensagem pendente (RN-57)"))
  end

  def progress_done(audit)
    data = audit.data
    scheduled = audits.find { _1.event_type == "progress.notice_scheduled" && _1.data["first_pending_seq"] == data["first_pending_seq"] }
    if audit.event_type == "progress.notice_sent"
      build(audit, :progress_sent, started_at: scheduled&.occurred_at, seq: data["seq"], turn: nil,
                                   detail: "Aviso de progresso gravado como saída seq #{data['seq']}, delivery_id " \
                                           "#{data['delivery_id'].to_s.first(8)} (kind progress)",
                                   cause: TimelineView::Cause.new(origin: "worker", reason: "aviso_de_progresso",
                                                                  reason_label: "Caso ainda pendente com a IA aos 15 s (RN-57)",
                                                                  outcome: "Entrega pelo Deliveries::Send"))
    else
      label = ConversationView::ProgressNotice::REASONS.fetch(data["reason"], data["reason"])
      build(audit, :progress_discarded, started_at: scheduled&.occurred_at, seq: data["first_pending_seq"], turn: nil,
                                        detail: "Aviso de progresso descartado: #{label}",
                                        cause: TimelineView::Cause.new(origin: data["source"] || "worker", reason: data["reason"],
                                                                       reason_label: label, outcome: "Nenhuma saída gravada"))
    end
  end

  def resolution_for(request)
    version = request.data["assignment_version"]
    audits.find do |audit|
      audit.id > request.id &&
        ((audit.event_type == "ticket.escalated" && audit.data["from_assignment_version"] == version) ||
         (audit.event_type == "handoff.discarded" && audit.data["assignment_version"] == version))
    end
  end

  def request_for(escalated)
    audits.select { _1.event_type == "handoff.requested" && _1.id < escalated.id }
          .reverse.find { _1.data["assignment_version"] == escalated.data["from_assignment_version"] }
  end

  def seq_for(turn, data) = (turn && turns[turn]&.context_until_seq) || data["first_pending_seq"]

  def queue_name(queue_id)
    @queue_names ||= {}
    @queue_names.fetch(queue_id) do
      queue = HelpdeskQueue.includes(:current_version).find_by(brand_id: @ticket.brand_id, id: queue_id)
      @queue_names[queue_id] = queue&.current_version&.name || "padrão"
    end
  end

  def cause(origin, reason, outcome)
    TimelineView::Cause.new(origin:, reason:, reason_label: reason_label(reason), outcome:)
  end

  def reason_label(reason) = ConversationView::Handoff.reason_label(reason)
  def source_label(source) = ConversationView::Handoff.source_label(source)
  def ms(from, to) = TimelineView::Event.ms_between(from, to)
  def parse(value) = value && Time.zone.parse(value)
  def clock(iso) = iso ? PanelClock.format(Time.zone.parse(iso), precise: true) : "—"
end
