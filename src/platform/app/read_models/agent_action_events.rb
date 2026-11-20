# Ação recebida do agente (ROADMAP 04; RF-31, RF-32, RN-37), lida de ai_turns.response e da auditoria
# agent_action.applied/rejected que o consumer grava. Serve à conversa (a ação de cada turno e o seu
# desfecho) e à linha do tempo (execução do agente e aplicação ou descarte de cada ação recebida).
#
# Relógio: a linha do tempo usa o relógio da plataforma. A execução do agente termina quando a ação foi
# registrada (auditoria, relógio do banco) e dura timing.agent_ms; o tempo de trânsito no Kafka entre
# responded_at e o registro fica fora dela. Os horários do agente aparecem só no detalhe.
class AgentActionEvents
  OUTCOMES = { "agent_action.applied" => :applied, "agent_action.rejected" => :rejected }.freeze

  def initialize(ticket)
    @ticket = ticket
  end

  # A primeira ação recebida para o turno (ai_turns.response) e o seu desfecho. nil sem resposta.
  def for_turn(turn)
    response = turn.response
    return unless response
    return AgentActionView.from(response, outcome: :applied) if turn.status == "applied"

    rejected = audits.find { _1.event_type == "agent_action.rejected" && _1.data["event_id"] == response["event_id"] }
    return AgentActionView.from(response, outcome: :received) unless rejected

    AgentActionView.from(response, outcome: :rejected, rejection_reason: rejected.data["reason"])
  end

  def events = audits.flat_map { action_events(_1) }

  private

  # Isolamento por marca (invariante 6): só a auditoria da marca do atendimento.
  def audits
    @audits ||= AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: OUTCOMES.keys)
                          .order(:occurred_at, :id).to_a
  end

  def action_events(audit)
    data = audit.data
    outcome = OUTCOMES.fetch(audit.event_type)
    action = AgentActionView.from(content_for(data), outcome:, rejection_reason: data["reason"])
    received_at = audit.occurred_at
    outcome_event = event(audit, action, outcome == :applied ? :applied : :discarded, started_at: received_at,
                                                                                    finished_at: received_at, detail: outcome_detail(action, data))
    [ agent_run(audit, action, data), outcome_event ].compact
  end

  # Sem timing.agent_ms não há duração a mostrar: só o desfecho.
  def agent_run(audit, action, data)
    return unless action.agent_ms

    event(audit, action, :agent_run, started_at: audit.occurred_at - Rational(action.agent_ms, 1000),
                                     finished_at: audit.occurred_at, detail: run_detail(action, data))
  end

  # A auditoria não repete o conteúdo da ação (texto, escalação, encerramento); ele está em
  # ai_turns.response, que guarda só a primeira ação recebida para o turno.
  def content_for(data)
    response = responses[data["event_id"]]
    response ? response.slice("reply", "escalation", "resolution").merge(data) : data
  end

  def responses
    @responses ||= @ticket.ai_turns.filter_map(&:response).index_by { _1["event_id"] }
  end

  def run_detail(action, data)
    text = "Ação recebida do agente: #{action.action} (#{action.agent_label}, config #{action.short_config_hash}), " \
           "agent_ms #{action.agent_ms}"
    text += "; consultas: #{action.tool_calls_text}" if action.tool_calls.any?
    timing = data["timing"] || {}
    text += "; relógio do agente: #{timing['received_at']} → #{timing['responded_at']}" if timing["received_at"]
    text
  end

  def outcome_detail(action, data)
    head = "Ação #{action.action} do turno #{data['turn']} (event_id #{action.event_id.to_s.first(8)})"
    action.applied? ? "#{head} aplicada" : "#{head} descartada: #{action.rejection_reason_label}"
  end

  def event(audit, action, kind, **attrs)
    TimelineView::Event.new(kind:, ticket_id: @ticket.id.to_s, seq: audit.data["context_until_seq"], turn: audit.data["turn"],
                            trace_id: audit.trace_id, source: DataSource::SYSTEM, agent_action: action, **attrs)
  end
end
