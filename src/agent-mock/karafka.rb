# App Karafka do agente mock (ADR-008; docs/10, seção 3.3). Sobe com `bundle exec karafka server`.
# Consome helpdesk.agent.inbound.v1 num grupo próprio e publica em helpdesk.agent.outbound.v1.
require "karafka"
require_relative "lib/agent_mock"
require_relative "app/consumers/inbound_consumer"

# Falha na subida se a configuração for inválida (perfil desconhecido, taxa fora de 0..1, regra inválida).
# Monta todos os perfis (rapido, lento, mudo): o simulador pode escolher qualquer um sem reiniciar (RF-38).
AgentMock.profiles

class KarafkaApp < Karafka::App
  setup do |config|
    config.kafka = AgentMock::Kafka.consumer_config
    config.client_id = "helpdesk-agent-mock"
    # AGENT_CONCURRENCY (padrão 48, uma thread por partição); inválido derruba a subida.
    config.concurrency = AgentMock::Kafka.concurrency
    config.logger = AgentMock::Log.karafka_logger
    # Produtor com acks=all e idempotência, o mesmo padrão do broker.
    config.producer = AgentMock::Kafka.producer
  end

  routes.draw do
    consumer_group AgentMock::Kafka.group_id do
      topic AgentMock::TOPICS.fetch(:inbound) do
        consumer InboundConsumer
      end
    end
  end
end
