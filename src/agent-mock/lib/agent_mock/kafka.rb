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

    # Threads de processamento do Karafka (07, seção 7). A latência simulada ocupa a thread, então a
    # vazão é ~concorrência ÷ latência. O padrão do Karafka (5) daria ~2,5 turnos/s com o agente a 2 s;
    # 48 acompanha as 48 partições de infra/kafka/topics.yml (~24 turnos/s). A ordem por partição
    # continua garantida: o Karafka nunca processa duas mensagens da mesma partição ao mesmo tempo.
    # Fica fora do config_hash (RN-37): muda a vazão, não a decisão de nenhum turno.
    DEFAULT_CONCURRENCY = 48

    def concurrency(env: ENV)
      value = env.fetch("AGENT_CONCURRENCY", DEFAULT_CONCURRENCY.to_s)
      threads = Integer(value, 10)
      raise ArgumentError if threads < 1

      threads
    rescue ArgumentError, TypeError
      raise Config::Invalid, "AGENT_CONCURRENCY inválido (inteiro >= 1): #{value.inspect}"
    end
  end
end
