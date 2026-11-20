require "rails_helper"

RSpec.describe AgentActionsConsumer, "RF-31, RNF-14: consumer de helpdesk.agent.outbound.v1" do
  subject(:consumer) { karafka.consumer_for("helpdesk.agent.outbound.v1") }

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:ok) { AgentActions::Apply::Result.new(status: :applied, reason: nil, turn: nil) }

  def produce(body, traceparent: AgentActionHelpers::TRACEPARENT, event_id: SecureRandom.uuid)
    karafka.produce(body, key: "tkt_1", headers: { "event_id" => event_id, "traceparent" => traceparent,
                                                   "schema" => "helpdesk.agent_action.v1" }.compact)
  end

  it "roteia o tópico no grupo platform-consumer" do
    expect(consumer.topic.consumer_group.name).to eq("platform-consumer")
  end

  it "RF-56: chama o serviço com o corpo cru, o traceparent e o event_id do cabeçalho, e confirma o offset depois" do
    allow(AgentActions::Apply).to receive(:call).and_return(ok)
    produce('{"a":1}', event_id: "e-1")
    produce('{"b":2}', traceparent: nil, event_id: nil)

    consumer.consume

    expect(AgentActions::Apply).to have_received(:call)
      .with('{"a":1}', traceparent: AgentActionHelpers::TRACEPARENT, header_event_id: "e-1").ordered
    expect(AgentActions::Apply).to have_received(:call).with('{"b":2}', traceparent: nil, header_event_id: nil).ordered
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

  it "RN-44: JSON malformado vai para a DLQ com o event_id do cabeçalho da mensagem e o offset é confirmado" do
    event_id = SecureRandom.uuid
    produce("{nao é json", event_id:)

    consumer.consume

    expect(dead_letters.sole[:headers]).to include("event_id" => event_id, "dlq_reason" => "contrato")
    expect(consumer.coordinator.seek_offset).to eq(consumer.messages.last.offset + 1)
  end

  it "RN-44, 07 seção 6: \\u0000 numa string não trava a partição: DLQ e offset confirmado" do
    turn = opened_turn
    produce(JSON.generate(agent_action_for(turn, reply: { "text" => "oi\u0000" })))

    consumer.consume

    expect(dead_letters.sole[:headers]).to include("dlq_reason" => "contrato")
    expect(turn.reload).to have_attributes(status: "eligible", response: nil)
    expect(consumer.coordinator.seek_offset).to eq(consumer.messages.last.offset + 1)
  end
end
