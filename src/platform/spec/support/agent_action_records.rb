# Grava direto no banco o efeito de uma ação do agente, no mesmo formato do AgentActions::Apply
# (ai_turns.response, ai_turns.status e auditoria agent_action.applied/rejected), para testar a
# leitura do painel com desfechos arbitrários (ex.: um motivo de descarte qualquer) sem montar o cenário
# que o produz. O formato é conferido contra o Apply real em spec/read_models/agent_action_events_spec.rb;
# para o caminho de verdade, grave pelo AgentActions::Apply (spec/support/agent_actions.rb).
module AgentActionRecordHelpers
  def agent_action_payload(turn, action: "reply", text: "Seu repasse cai hoje até as 18h.", agent_ms: 2_000,
                           tool_calls: nil, **extra)
    ticket = turn.ticket
    {
      "schema" => "helpdesk.agent_action.v1", "event_id" => SecureRandom.uuid, "in_reply_to" => turn.event_id,
      "conversation_id" => "tkt_#{ticket.id}", "brand" => ticket.brand.slug, "turn" => turn.turn,
      "context_until_seq" => turn.context_until_seq, "assignment_version" => turn.assignment_version,
      "action" => action,
      "tool_calls" => tool_calls || [ { "tool" => "consultar_repasse", "args" => { "periodo" => "ontem" },
                                        "result" => { "status" => "programado", "valor" => "1200.00" }, "duration_ms" => 120 } ],
      "agent" => { "model" => "mock-deterministico", "version" => "0.3.0",
                   "config_hash" => "sha256:9f2c4e1ab7d03c55e8f1aa90" },
      "timing" => { "received_at" => Time.current.utc.iso8601(3),
                    "responded_at" => (Time.current + (agent_ms / 1000.0)).utc.iso8601(3), "agent_ms" => agent_ms }
    }.merge(content_for_action(action, text)).merge(extra)
  end

  # Aplicada: turno eligible → applied, applied_event_id e auditoria agent_action.applied.
  # Rejeitada: o turno guarda a resposta (a primeira) e a auditoria agent_action.rejected leva o motivo.
  # occurred_at: horário da auditoria (padrão: relógio do banco), para testar durações com o tempo controlado.
  def record_agent_action(turn, payload, rejected: nil, occurred_at: nil)
    turn.reload
    now = Time.current
    attrs = { response: turn.response || payload, response_received_at: turn.response_received_at || now }
    attrs.merge!(status: "applied", applied_event_id: payload["event_id"]) unless rejected
    turn.update_columns(attrs)
    data = payload.slice("turn", "event_id", "in_reply_to", "action", "timing", "context_until_seq", "classification")
                  .merge("tool_calls" => payload.fetch("tool_calls", []),
                         "agent" => payload.fetch("agent", {}).slice("model", "version", "config_hash"),
                         "turn_status" => turn.status, "platform_received_at" => now.utc.iso8601(6))
                  .merge(payload.slice("reply", "escalation", "resolution")).compact
    data["reason"] = rejected if rejected
    AuditEvent.create!(brand_id: turn.brand_id, ticket_id: turn.ticket_id, actor_type: "agent",
                       event_type: rejected ? "agent_action.rejected" : "agent_action.applied", data:,
                       trace_id: OutboxEvent.find_by(id: turn.event_id)&.trace_id || SecureRandom.hex(16),
                       agent_model: payload.dig("agent", "model"), agent_version: payload.dig("agent", "version"),
                       **{ occurred_at: }.compact)
  end

  private

  def content_for_action(action, text)
    case action
    when "reply" then { "reply" => { "text" => text } }
    when "resolve" then { "resolution" => { "reason" => "cliente confirmou que o repasse caiu", "text" => text } }
    when "escalate"
      { "escalation" => { "reason" => "contestacao_de_cobranca",
                          "summary" => { "problema" => "Cobrança em duplicidade", "dados_cliente" => "conta 000021",
                                         "acoes_tomadas" => "consultou transações", "motivo" => "exige analista",
                                         "pendente" => "abrir contestação" } } }
    else {}
    end
  end
end

RSpec.configure { |c| c.include AgentActionRecordHelpers }
