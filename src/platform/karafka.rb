# Karafka na plataforma: o processo `consumer` (docs/10; 07, seção 2; ADR-004).
#
#   bundle exec karafka server
#
# Consome as ações do agente em helpdesk.agent.outbound.v1 e só publica direto no Kafka para a DLQ
# (docs/10: "A plataforma envia ao broker por webhook e só publica direto na DLQ, pelo próprio Karafka").
# Consome também a DLQ (helpdesk.agent.dlq.v1), num grupo próprio (platform-dlq): grava o espelho em
# dead_letters e aplica a RN-45 (bloco 09). Grupo separado para o atraso de um não segurar o outro.
# O Rails carrega este arquivo no boot (railtie do Karafka); a conexão com o Kafka só abre quando o
# consumer roda ou quando a DLQ é usada.
class KarafkaApp < Karafka::App
  setup do |config|
    config.kafka = {
      "bootstrap.servers": ENV.fetch("KAFKA_BROKERS", "localhost:9092"),
      # Produtor da DLQ: só confirma com todas as réplicas (como o broker, 07, seção 3.1, passo 4).
      "request.required.acks": -1
    }
    # Workers que processam partições em paralelo (padrão do Karafka: 5). Cada worker usa uma conexão do
    # pool do Active Record (config/database.yml, max_connections = RAILS_MAX_THREADS): no processo
    # consumer, KAFKA_CONCURRENCY e RAILS_MAX_THREADS sobem e descem juntos, senão os workers esperam
    # conexão (ActiveRecord::ConnectionTimeoutError) e a mensagem volta para reentrega.
    config.concurrency = Integer(ENV.fetch("KAFKA_CONCURRENCY", 5))
    config.client_id = "helpdesk-platform"
    config.group_id = "platform-consumer"
    # Recria o consumer a cada lote só em desenvolvimento, para o reload de código funcionar.
    config.consumer_persistence = !Rails.env.development?
  end

  # Invariante 13: erros do Karafka viram uma linha de log em JSON, sem o payload.
  Karafka.monitor.subscribe("error.occurred") do |event|
    JsonLog.warn("karafka.error", type: event[:type], error: event[:error].class.name)
  end

  routes.draw do
    topic AgentActions::Apply::TOPICS.fetch(:outbound) do
      consumer AgentActionsConsumer
    end

    consumer_group "platform-dlq" do
      topic AgentActions::Apply::TOPICS.fetch(:dlq) do
        consumer DeadLettersConsumer
      end
    end
  end
end
