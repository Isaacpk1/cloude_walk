require "stringio"

# Sem Kafka de verdade nos testes (ADR-010): o WaterDrop grava em memória com o cliente Buffered.
module KafkaHelpers
  SECRET = ENV.fetch("BROKER_WEBHOOK_SECRET")
  FIXTURE = File.expand_path("../../../contracts/v1/fixtures/valid/agent_inbound/message_created_07_secao_5_2.json", __dir__)

  def buffered_producer
    WaterDrop::Producer.new do |config|
      config.deliver = true
      config.client_class = WaterDrop::Clients::Buffered
      config.kafka = { "bootstrap.servers": "localhost:9092" }
    end
  end

  # Produtor que falha como o librdkafka falha quando o Kafka está fora do ar.
  class FailingProducer
    attr_reader :attempts

    def initialize(fail_topics: :all)
      @fail_topics = fail_topics
      @attempts = []
      @delegate = nil
    end

    def delegate_to(producer) = tap { @delegate = producer }
    def heal! = @fail_topics = []

    def produce_sync(message)
      @attempts << message
      raise WaterDrop::Errors::ProduceError, "Local: Message timed out (msg_timed_out)" if fails?(message[:topic])

      @delegate.produce_sync(message)
    end

    private

    def fails?(topic) = @fail_topics == :all || @fail_topics.include?(topic)
  end

  def event(**overrides)
    JSON.parse(File.read(FIXTURE, encoding: "UTF-8")).merge("event_id" => SecureRandom.uuid).merge(overrides.transform_keys(&:to_s))
  end

  def trace_id = @trace_id ||= SecureRandom.hex(16)
  def traceparent = "00-#{trace_id}-#{SecureRandom.hex(8)}-01"

  # Envia como a plataforma envia (07, seção 5.2). `body` cru permite testar corpo alterado e JSON malformado.
  def post_webhook(payload = event, body: JSON.generate(payload), secret: SECRET, at: Time.now, headers: {})
    event_id = payload.is_a?(Hash) ? payload["event_id"] : SecureRandom.uuid
    defaults = {
      "CONTENT_TYPE" => "application/json",
      "HTTP_X_HELPDESK_SIGNATURE" => HelpdeskContracts::Signature.header(body, secret:, at:),
      "HTTP_X_HELPDESK_EVENT_ID" => event_id,
      "HTTP_TRACEPARENT" => traceparent
    }
    post "/webhooks", body, defaults.merge(headers).compact
  end

  def messages_in(producer, topic) = producer.client.messages.select { _1[:topic] == topic }
  def json_body = JSON.parse(last_response.body)
end
