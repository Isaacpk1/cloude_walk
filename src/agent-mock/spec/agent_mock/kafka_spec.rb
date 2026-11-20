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

  describe "07 seção 7, RNF-03: vazão do agente com AGENT_CONCURRENCY" do
    it "padrão 48 (uma thread por partição: ~24 turnos/s com o agente a 2 s) e aplicado no Karafka" do
      expect(described_class.concurrency(env: {})).to eq(48)
      expect(Karafka::App.config.concurrency).to eq(described_class.concurrency)
    end

    it "aceita inteiro >= 1 por ENV" do
      expect(described_class.concurrency(env: { "AGENT_CONCURRENCY" => "12" })).to eq(12)
      expect(described_class.concurrency(env: { "AGENT_CONCURRENCY" => "1" })).to eq(1)
    end

    it "valor inválido derruba a subida" do
      [ "0", "-3", "abc", "2.5", "" ].each do |value|
        expect { described_class.concurrency(env: { "AGENT_CONCURRENCY" => value }) }
          .to raise_error(AgentMock::Config::Invalid, /AGENT_CONCURRENCY/), value.inspect
      end
    end

    it "não entra no config_hash: muda a vazão, não a decisão (RN-37)" do
      expect(AgentMock::Config.load(env: { "AGENT_CONCURRENCY" => "5" }).config_hash)
        .to eq(AgentMock::Config.load(env: {}).config_hash)
    end
  end
end
