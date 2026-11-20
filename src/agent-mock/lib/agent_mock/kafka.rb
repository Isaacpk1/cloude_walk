require "waterdrop"

module AgentMock
  # Configuração do Kafka do agente (ADR-004, ADR-008), no mesmo padrão do broker.
  module Kafka
    module_function

    # acks=all e idempotência: a ação só conta como publicada com a escrita confirmada, e uma
    # retentativa interna do librdkafka não duplica a mensagem na partição.
    def producer_config(env: ENV)
      {
        "bootstrap.servers": env.fetch("KAFKA_BROKERS", "localhost:9092"),
        "client.id": "helpdesk-agent-mock",
        "request.required.acks": -1,
        "enable.idempotence": true,
        "message.timeout.ms": Integer(env.fetch("KAFKA_MESSAGE_TIMEOUT_MS", "5000"))
      }
    end

    def producer(env: ENV)
      config = producer_config(env:)
      WaterDrop::Producer.new do |c|
        c.deliver = true
        c.kafka = config
        c.max_wait_timeout = config.fetch(:"message.timeout.ms") + 1_000
      end
    end

    # Consumidor: grupo próprio, para não dividir partições com o consumer da plataforma.
    def consumer_config(env: ENV)
      { "bootstrap.servers": env.fetch("KAFKA_BROKERS", "localhost:9092"), "client.id": "helpdesk-agent-mock" }
    end

    def group_id(env: ENV) = env.fetch("AGENT_CONSUMER_GROUP", "agent-mock")
  end
end
