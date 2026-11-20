require "time"

# Sem Kafka de verdade nos testes (ADR-010): o WaterDrop grava em memória com o cliente Buffered.
module KafkaHelpers
  FIXTURE = File.expand_path("../../../contracts/v1/fixtures/valid/agent_inbound/message_created_07_secao_5_2.json", __dir__)
  T0 = Time.utc(2026, 11, 17, 13, 40, 1.76r)

  # Relógio e "sono" falsos: a latência injetada avança o relógio, sem sleep real.
  class FakeClock
    attr_reader :now, :slept

    def initialize(now = T0)
      @now = now
      @slept = []
    end

    def call = @now
    def sleep(seconds) = (@slept << seconds) && (@now += seconds)
    def advance(seconds) = @now += seconds
  end

  # Produtor que falha como o librdkafka falha quando o Kafka está fora do ar.
  class FailingProducer
    attr_reader :attempts

    def initialize = @attempts = []

    def produce_sync(message)
      @attempts << message
      raise WaterDrop::Errors::ProduceError, "Local: Message timed out (msg_timed_out)"
    end
  end

  def buffered_producer
    WaterDrop::Producer.new do |config|
      config.deliver = true
      config.client_class = WaterDrop::Clients::Buffered
      config.kafka = { "bootstrap.servers": "localhost:9092" }
    end
  end

  # Evento válido do 07, seção 5.2, com prazo 20 s depois de T0 (RN-46) e texto trocável.
  def inbound(texts: nil, verified: true, ai_turns: 2, **overrides)
    event = JSON.parse(File.read(FIXTURE, encoding: "UTF-8"))
    event["event_id"] = SecureRandom.uuid
    event["deadline_at"] = (T0 + 20).iso8601(3)
    event["customer"]["verified"] = verified
    event["ticket"]["ai_turns"] = ai_turns
    if texts
      seq = event["context_until_seq"] - texts.size
      event["context"]["pending_messages"] = texts.map { { "seq" => seq += 1, "text" => _1 } }
      event["message"]["text"] = texts.last
    end
    event.merge(overrides.transform_keys(&:to_s))
  end

  def trace_id = @trace_id ||= SecureRandom.hex(16)
  def traceparent = @traceparent ||= "00-#{trace_id}-#{SecureRandom.hex(8)}-01"
  def headers_for(event) = { "event_id" => event["event_id"], "traceparent" => traceparent, "schema" => event["schema"] }

  def messages_in(producer, topic) = producer.client.messages.select { _1[:topic] == topic }
  def outbound(producer) = messages_in(producer, AgentMock::TOPICS.fetch(:outbound))
  def dlq(producer) = messages_in(producer, AgentMock::TOPICS.fetch(:dlq))
  def action_in(producer) = JSON.parse(outbound(producer).last.fetch(:payload))

  def log_lines(io) = io.string.lines.map { JSON.parse(_1) }
end

module KafkaHelpers
  # Exatamente um item (como o Enumerable#sole do Rails).
  def sole(list)
    expect(list.size).to eq(1), "esperava 1 item, veio #{list.size}"
    list.first
  end
end
