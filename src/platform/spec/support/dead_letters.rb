# Mensagens de helpdesk.agent.dlq.v1 como os três produtores as gravam (contrato dead_letter; bloco 09).
module DeadLetterHelpers
  DLQ_TOPIC = "helpdesk.agent.dlq.v1".freeze
  CONTRACT_VIOLATION = [ { "pointer" => "/turn", "type" => "required", "message" => "campo obrigatório ausente: turn" } ].freeze

  # O corpo do evento do turno, como a plataforma o publicou no broker (o item agent.event do outbox).
  def turn_event_body(turn) = JSON.generate(OutboxEvent.find(turn.event_id).payload)

  def dlq_headers(source:, reason:, event_id:, violations: nil, traceparent: AgentActionHelpers::TRACEPARENT)
    violations ||= %w[contrato acao_invalida].include?(reason) ? CONTRACT_VIOLATION : []
    { "dlq_source" => source, "dlq_reason" => reason, "dlq_violations" => JSON.generate(violations),
      "event_id" => event_id.to_s, "traceparent" => traceparent.to_s }
  end

  def next_dlq_offset = (@next_dlq_offset = (@next_dlq_offset || 0) + 1)

  def record_dead_letter(payload, headers:, offset: next_dlq_offset, partition: 0, key: nil)
    DeadLetters::Record.call(topic: DLQ_TOPIC, partition:, offset:, payload:, headers:, key:)
  end

  # Evento do turno recusado pelo broker por contrato (422 → DLQ).
  def broker_dead_letter(turn, reason: "contrato", **)
    record_dead_letter(turn_event_body(turn), headers: dlq_headers(source: "broker", reason:, event_id: turn.event_id), **)
  end

  # Ação do agente para o turno que caiu na DLQ (agent-mock acao_invalida ou plataforma contrato).
  def action_dead_letter(turn, source: "platform", reason: "contrato", **overrides)
    action = agent_action_for(turn, **overrides)
    record_dead_letter(JSON.generate(action), headers: dlq_headers(source:, reason:, event_id: action["event_id"]))
  end

  def handoff_items = OutboxEvent.where(event_type: "handoff.requested")
end

RSpec.configure { |c| c.include DeadLetterHelpers }
