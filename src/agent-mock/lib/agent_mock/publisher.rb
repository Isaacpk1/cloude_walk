require "json"

module AgentMock
  # Publica no Kafka com confirmação (produce_sync, acks=all). Não engole erro: se o Kafka não
  # confirmar, a exceção sobe, o Karafka não confirma o offset e o evento volta (07, seção 6).
  class Publisher
    def initialize(producer:, topics: TOPICS)
      @producer = producer
      @topics = topics
    end

    # Ação em helpdesk.agent.outbound.v1: chave conversation_id (RNF-13) e cabeçalhos event_id
    # (da ação), traceparent (o mesmo recebido, RF-56) e schema.
    def publish(action, traceparent:)
      headers = { "event_id" => action.fetch("event_id"), "traceparent" => traceparent,
                  "schema" => action.fetch("schema") }.compact
      @producer.produce_sync(topic: @topics.fetch(:outbound), key: action.fetch("conversation_id"),
                             payload: JSON.generate(action), headers:)
    end

    # Falha permanente: DLQ sem retentativa (invariante 10, RN-44), no formato do broker e do contrato
    # dead_letter. Sem conversation_id nem event_id, vai sem chave: o WaterDrop recusa chave vazia, e o erro
    # travaria a partição de entrada (o offset nunca seria confirmado).
    def dead_letter(body:, key:, reason:, violations:, event_id:, traceparent:)
      key = key.is_a?(String) && !key.empty? ? key : nil
      headers = { "dlq_reason" => reason, "dlq_source" => "agent-mock", "dlq_violations" => JSON.generate(violations),
                  "event_id" => event_id.to_s, "traceparent" => traceparent.to_s }
      @producer.produce_sync(topic: @topics.fetch(:dlq), key:, payload: body, headers:)
    end
  end
end
