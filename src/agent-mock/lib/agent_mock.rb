require "json"
require "waterdrop"
require "helpdesk_contracts"

# Agente de IA simulado (ADR-008; docs/10, seção 3.3). Não tem banco (invariante 12).
module AgentMock
  # Tópicos do ADR-004 (infra/kafka/topics.yml).
  TOPICS = {
    inbound: "helpdesk.agent.inbound.v1",
    outbound: "helpdesk.agent.outbound.v1",
    dlq: "helpdesk.agent.dlq.v1"
  }.freeze
end

require_relative "agent_mock/version"
require_relative "agent_mock/log"
require_relative "agent_mock/clock"
require_relative "agent_mock/seeded"
require_relative "agent_mock/text"
require_relative "agent_mock/config"
require_relative "agent_mock/failure_modes"
require_relative "agent_mock/tools"
require_relative "agent_mock/scenarios/decision"
require_relative "agent_mock/scenarios/rule"
require_relative "agent_mock/scenarios/engine"
require_relative "agent_mock/publisher"
require_relative "agent_mock/kafka"
require_relative "agent_mock/responder"
