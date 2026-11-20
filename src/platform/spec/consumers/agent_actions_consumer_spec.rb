require "rails_helper"

RSpec.describe AgentActionsConsumer, "RF-31, RNF-14: consumer de helpdesk.agent.outbound.v1" do
  subject(:consumer) { karafka.consumer_for("helpdesk.agent.outbound.v1") }

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:ok) { AgentActions::Apply::Result.new(status: :applied, reason: nil, turn: nil) }

  def produce(body, traceparent: AgentActionHelpers::TRACEPARENT)
    karafka.produce(body, key: "tkt_1", headers: { "event_id" => SecureRandom.uuid, "traceparent" => traceparent,
                                                   "schema" => "helpdesk.agent_action.v1" }.compact)
  end

  it "roteia o tópico no grupo platform-consumer" do
    expect(consumer.topic.consumer_group.name).to eq("platform-consumer")
  end

  it "RF-56: chama o serviço com o corpo cru e o traceparent do cabeçalho, e confirma o offset depois" do
    allow(AgentActions::Apply).to receive(:call).and_return(ok)
    produce('{"a":1}')
    produce('{"b":2}', traceparent: nil)

    consumer.consume

    expect(AgentActions::Apply).to have_received(:call).with('{"a":1}', traceparent: AgentActionHelpers::TRACEPARENT).ordered
    expect(AgentActions::Apply).to have_received(:call).with('{"b":2}', traceparent: nil).ordered
    expect(consumer.messages.last.offset + 1).to eq(consumer.coordinator.seek_offset)
  end

  it "RNF-14: erro de banco sobe e o offset da mensagem que falhou não é confirmado (reentrega)" do
    calls = 0
    allow(AgentActions::Apply).to receive(:call) do
      calls += 1
      raise ActiveRecord::ConnectionNotEstablished, "banco fora" if calls == 2

      ok
    end
    produce('{"a":1}')
    produce('{"b":2}')

    expect { consumer.consume }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    failed = consumer.messages.to_a.last
    expect(consumer.coordinator.seek_offset).to eq(failed.offset)
  end

  it "RF-31: de ponta a ponta com o serviço real, aplica a ação ao turno" do
    turn = opened_turn
    action = agent_action_for(turn)
    produce(JSON.generate(action))

    consumer.consume

    expect(turn.reload).to have_attributes(status: "applied", applied_event_id: action["event_id"])
    expect(AuditEvent.find_by(event_type: "agent_action.applied").trace_id).to eq(AgentActionHelpers::TRACE_ID)
  end
end
