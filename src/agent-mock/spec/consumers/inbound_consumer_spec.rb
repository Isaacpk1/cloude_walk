require "karafka/testing/rspec/helpers"

RSpec.describe InboundConsumer do
  include Karafka::Testing::RSpec::Helpers

  subject(:consumer) { karafka.consumer_for(AgentMock::TOPICS.fetch(:inbound)) }

  let(:clock) { KafkaHelpers::FakeClock.new }
  let(:redis) { KafkaHelpers::FakeControlRedis.new }

  def profiles_for(env)
    AgentMock::Profiles.new(config: AgentMock::Config.load(env:), source: AgentMock::ProfileSource.new(redis:),
                            log: AgentMock::Log.new(StringIO.new))
  end

  before do
    allow(AgentMock).to receive_messages(profiles: profiles_for("AGENT_LATENCY_MS" => "0"),
                                         clock:, log: AgentMock::Log.new(StringIO.new))
  end

  def publish_inbound(event, headers: headers_for(event))
    karafka.produce(JSON.generate(event), key: event["conversation_id"], headers:)
  end

  def produced_to(topic) = karafka.produced_messages.select { _1[:topic] == topic }

  describe "ADR-008, RF-32: consome agent.inbound e publica a ação em agent.outbound" do
    it "traduz a mensagem do Kafka (corpo bruto e cabeçalhos) e publica com chave e cabeçalhos" do
      event = inbound(texts: [ "Meu repasse não caiu" ])
      publish_inbound(event)

      consumer.consume

      message = sole(produced_to(AgentMock::TOPICS.fetch(:outbound)))
      action = JSON.parse(message[:payload])
      expect(HelpdeskContracts.valid?(:agent_outbound, action)).to be(true)
      expect(action).to include("in_reply_to" => event["event_id"], "action" => "reply")
      expect(message[:key]).to eq(event["conversation_id"])
      expect(message[:headers]).to eq("event_id" => action["event_id"], "traceparent" => traceparent,
                                      "schema" => "helpdesk.agent_action.v1")
    end

    it "processa o lote inteiro, um evento por vez" do
      events = [ inbound(texts: [ "Bom dia" ]), inbound(texts: [ "Obrigado, resolvido" ]) ]
      events.each { publish_inbound(_1) }

      consumer.consume

      actions = produced_to(AgentMock::TOPICS.fetch(:outbound)).map { JSON.parse(_1[:payload]) }
      expect(actions.map { _1["in_reply_to"] }).to eq(events.map { _1["event_id"] })
      expect(actions.map { _1["action"] }).to eq(%w[reply resolve])
    end
  end

  describe "invariante 10: evento inválido vai para a DLQ e o consumo segue" do
    it "publica na DLQ, não responde e processa o próximo do lote" do
      bad = inbound.except("assignment_version")
      good = inbound(texts: [ "Bom dia" ])
      publish_inbound(bad)
      publish_inbound(good)

      consumer.consume

      expect(sole(produced_to(AgentMock::TOPICS.fetch(:dlq)))[:headers]).to include("dlq_source" => "agent-mock")
      expect(JSON.parse(sole(produced_to(AgentMock::TOPICS.fetch(:outbound)))[:payload])["in_reply_to"]).to eq(good["event_id"])
    end
  end

  describe "RF-38: modo mudo" do
    it "consome e não publica nada" do
      allow(AgentMock).to receive(:profiles).and_return(profiles_for("AGENT_PROFILE" => "mudo"))
      publish_inbound(inbound(texts: [ "Bom dia" ]))

      consumer.consume

      expect(produced_to(AgentMock::TOPICS.fetch(:outbound))).to be_empty
      expect(produced_to(AgentMock::TOPICS.fetch(:dlq))).to be_empty
    end
  end

  describe "RF-38: perfil escolhido pelo simulador" do
    it "o mesmo consumidor passa a usar o perfil gravado no lote seguinte, sem reiniciar" do
      publish_inbound(inbound(texts: [ "Bom dia" ]))
      consumer.consume
      expect(produced_to(AgentMock::TOPICS.fetch(:outbound)).size).to eq(1)

      redis.set(AgentMock::ProfileSource.key("global"), "mudo")
      publish_inbound(inbound(texts: [ "Bom dia" ]))
      consumer.consume

      expect(produced_to(AgentMock::TOPICS.fetch(:outbound)).size).to eq(1)
    end
  end

  describe "07, seção 6: Kafka não confirma a ação" do
    it "levanta o erro para o Karafka não confirmar o offset do evento que falhou" do
      first = inbound(texts: [ "Bom dia" ])
      second = inbound(texts: [ "Bom dia" ])
      publish_inbound(first)
      publish_inbound(second)
      calls = 0
      allow(consumer.producer).to receive(:produce_sync).and_wrap_original do |original, **message|
        calls += 1
        raise WaterDrop::Errors::ProduceError, "Local: Message timed out" if calls == 2

        original.call(**message)
      end

      expect { consumer.consume }.to raise_error(WaterDrop::Errors::ProduceError)
      expect(consumer.send(:seek_offset)).to eq(consumer.messages.first.offset + 1)
    end
  end
end
