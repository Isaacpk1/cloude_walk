require "waterdrop"

module Broker
  # Produtor Kafka do broker (ADR-004, ADR-007; docs/10, seção 3.2).
  module Kafka
    module_function

    # acks=all e idempotência: o 200 do broker só sai com a escrita confirmada (07, seção 3.1, passo 4)
    # e uma retentativa interna do librdkafka não duplica a mensagem na partição.
    # message.timeout.ms limita a espera da requisição: sem confirmação, o broker responde 503
    # e a plataforma tenta de novo pelo outbox (07, seção 6).
    def config(env: ENV)
      {
        "bootstrap.servers": env.fetch("KAFKA_BROKERS", "localhost:9092"),
        "client.id": "helpdesk-broker",
        "request.required.acks": -1,
        "enable.idempotence": true,
        "message.timeout.ms": Integer(env.fetch("KAFKA_MESSAGE_TIMEOUT_MS", "5000"))
      }
    end

    def producer(env: ENV)
      WaterDrop::Producer.new do |c|
        c.deliver = true
        c.kafka = config(env:)
        c.max_wait_timeout = config(env:).fetch(:"message.timeout.ms") + 1_000
      end
    end
  end
end
