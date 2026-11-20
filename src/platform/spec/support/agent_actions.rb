# Ação do agente para um turno aberto, no formato que o agent-mock publica em helpdesk.agent.outbound.v1
# (07, seção 5.3; contrato agent_outbound). Por padrão, correlaciona com o turno persistido.
module AgentActionHelpers
  TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736".freeze
  TRACEPARENT = "00-#{TRACE_ID}-00f067aa0ba902b7-01".freeze

  def agent_action_for(turn, **overrides)
    {
      "schema" => "helpdesk.agent_action.v1", "event_id" => SecureRandom.uuid, "in_reply_to" => turn.event_id,
      "conversation_id" => "tkt_#{turn.ticket_id}", "brand" => turn.brand.slug, "turn" => turn.turn,
      "context_until_seq" => turn.context_until_seq, "assignment_version" => turn.assignment_version,
      "action" => "reply", "reply" => { "text" => "Seu repasse de R$ 1.200 cai hoje até as 18h." },
      "tool_calls" => [ { "tool" => "get_settlement_status", "args" => { "date" => "2026-11-19" },
                          "result" => { "status" => "pendente", "amount" => 1200.0 }, "duration_ms" => 180 } ],
      "classification" => { "category" => "repasses", "priority" => "alta" },
      "agent" => { "model" => "mock-deterministico", "version" => "0.3.0", "config_hash" => "sha256:9f1c2e" },
      "timing" => { "received_at" => "2026-11-20T13:40:01.760Z", "responded_at" => "2026-11-20T13:40:03.770Z",
                    "agent_ms" => 2010 }
    }.merge(overrides.transform_keys(&:to_s))
  end

  def opened_turn(text = "meu repasse não caiu", **)
    open_turn_for(ingest(text, **))
  end

  # Relógio do Postgres (o `now()` do banco não acompanha o travel_to).
  def db_now = ActiveRecord::Base.connection.select_value("SELECT clock_timestamp()")

  def dead_letters = karafka.produced_messages.select { |m| m[:topic] == "helpdesk.agent.dlq.v1" }
end

RSpec.configure { |c| c.include AgentActionHelpers }
