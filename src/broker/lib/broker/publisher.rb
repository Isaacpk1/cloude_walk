require "json"

module Broker
  # Tópicos do ADR-004 (infra/kafka/topics.yml).
  TOPICS = {
    inbound: "helpdesk.agent.inbound.v1",
    dlq: "helpdesk.agent.dlq.v1"
  }.freeze

  # Publica no Kafka e espera a confirmação (07, seção 3.1, passo 4: o broker só responde depois
  # do Kafka). O envelope vai igual ao corpo recebido, com a chave conversation_id (RF-30, RNF-13)
  # e event_id e traceparent nos cabeçalhos (07, seção 5.2; RF-56).
  class Publisher
    Unavailable = Class.new(StandardError)
    Report = Data.define(:topic, :partition, :offset)

    def initialize(producer:, topics: TOPICS)
      @producer = producer
      @topics = topics
    end

    def publish(event, body:, traceparent:)
      produce(topic: @topics.fetch(:inbound), key: event.fetch("conversation_id"), payload: body,
              headers: { "event_id" => event.fetch("event_id"), "traceparent" => traceparent,
                         "schema" => event.fetch("schema") })
    end

    # Evento autenticado mas fora do contrato: falha permanente, vai para a DLQ sem retentativa
    # (invariante 10, RN-44). O corpo vai como chegou, para o supervisor ver e reprocessar (RF-37).
    def dead_letter(body:, key:, reason:, violations:, event_id:, traceparent:)
      headers = { "dlq_reason" => reason, "dlq_source" => "broker", "dlq_violations" => JSON.generate(violations),
                  "event_id" => event_id.to_s, "traceparent" => traceparent.to_s }
      produce(topic: @topics.fetch(:dlq), key:, payload: body, headers:)
    end

    private

    def produce(**message)
      report = @producer.produce_sync(**message)
      Report.new(topic: report.topic_name || message[:topic], partition: report.partition, offset: report.offset)
    rescue WaterDrop::Errors::BaseError, Rdkafka::BaseError => e
      raise Unavailable, e.message
    end
  end
end
