RSpec.describe AgentMock::Responder do
  let(:producer) { buffered_producer }
  let(:clock) { KafkaHelpers::FakeClock.new }
  let(:io) { StringIO.new }
  let(:env) { {} }
  let(:config) { AgentMock::Config.load(env:) }
  subject(:responder) { described_class.new(producer:, config:, log: AgentMock::Log.new(io), clock:) }

  def deliver(event, headers: headers_for(event), payload: JSON.generate(event))
    responder.call(payload:, headers:)
  end

  describe "RF-32, RF-33: pedido de repasse vira consulta + reply" do
    it "consulta get_settlement_status e responde com o resultado, no contrato agent_outbound" do
      event = inbound(texts: [ "Meu repasse de ontem não caiu" ])

      result = deliver(event)

      expect(result.status).to eq(:published)
      action = action_in(producer)
      expect(HelpdeskContracts.errors(:agent_outbound, action)).to be_empty
      expect(action["action"]).to eq("reply")
      expect(action["tool_calls"].map { _1["tool"] }).to eq([ "get_settlement_status" ])
      call = action["tool_calls"].first
      expect(call.keys).to contain_exactly("tool", "args", "result", "duration_ms")
      expect(call["args"]).to include("date" => "2026-11-16")
      expect(action.dig("reply", "text")).to include(call.dig("result", "status").tr("_", " "))
    end
  end
end
