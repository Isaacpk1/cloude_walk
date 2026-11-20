RSpec.describe AgentMock::Kafka do
  describe "ADR-004, 07 seção 6: produtor com acks=all e idempotência" do
    it "configura acks=all, idempotência, brokers e timeout por ENV" do
      config = described_class.producer_config(env: { "KAFKA_BROKERS" => "kafka:9092", "KAFKA_MESSAGE_TIMEOUT_MS" => "3000" })

      expect(config).to include("bootstrap.servers": "kafka:9092", "request.required.acks": -1,
                                "enable.idempotence": true, "message.timeout.ms": 3000)
    end
  end

  describe "ADR-008: consumidor em grupo próprio" do
    it "consome helpdesk.agent.inbound.v1 no grupo agent-mock, separado do consumer da plataforma" do
      route = Karafka::App.routes.flat_map { |group| group.topics.map { [ group.name, _1.name, _1.consumer ] } }

      expect(route).to eq([ [ "agent-mock", "helpdesk.agent.inbound.v1", InboundConsumer ] ])
      expect(described_class.group_id(env: { "AGENT_CONSUMER_GROUP" => "outro" })).to eq("outro")
    end
  end
end
