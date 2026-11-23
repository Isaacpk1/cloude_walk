require "rails_helper"

RSpec.describe DeadLettersConsumer, "RF-34, RN-45, RNF-14: consumer de helpdesk.agent.dlq.v1" do
  subject(:consumer) { karafka.consumer_for("helpdesk.agent.dlq.v1") }

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:ok) { DeadLetters::Record::Result.new(status: :recorded, dead_letter_id: 1, outcome: "uncorrelated", handoff_event_id: nil) }

  def produce(body, headers: dlq_headers(source: "broker", reason: "contrato", event_id: "e-1"), key: "tkt_1")
    karafka.produce(body, key:, headers:)
  end

  it "roteia o tópico no grupo platform-dlq" do
    expect(consumer.topic.consumer_group.name).to eq("platform-dlq")
  end

  it "o grupo das ações do agente não lê a DLQ" do
    groups = Karafka::App.routes.select { |group| group.topics.map(&:name).include?("helpdesk.agent.dlq.v1") }

    expect(groups.map(&:name)).to eq([ "platform-dlq" ])
  end

  it "chama o serviço com topic, partition, offset, corpo cru, cabeçalhos e chave, e confirma o offset depois" do
    allow(DeadLetters::Record).to receive(:call).and_return(ok)
    headers = dlq_headers(source: "broker", reason: "contrato", event_id: "e-1")
    produce("{nao é json", headers:)

    consumer.consume

    message = consumer.messages.last
    expect(DeadLetters::Record).to have_received(:call).with(
      topic: "helpdesk.agent.dlq.v1", partition: message.partition, offset: message.offset, payload: "{nao é json",
      headers: include(headers), key: "tkt_1"
    )
    expect(consumer.coordinator.seek_offset).to eq(message.offset + 1)
  end

  it "RNF-14: erro de banco sobe e o offset da mensagem que falhou não é confirmado (reentrega)" do
    calls = 0
    allow(DeadLetters::Record).to receive(:call) do
      calls += 1
      raise ActiveRecord::ConnectionNotEstablished, "banco fora" if calls == 2

      ok
    end
    produce("a")
    produce("b")

    expect { consumer.consume }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    expect(consumer.coordinator.seek_offset).to eq(consumer.messages.to_a.last.offset)
  end

  it "RN-45: de ponta a ponta, o evento de um turno válido na DLQ pede o handoff" do
    turn = opened_turn
    produce(turn_event_body(turn), headers: dlq_headers(source: "broker", reason: "contrato", event_id: turn.event_id))

    consumer.consume

    expect(DeadLetter.sole).to have_attributes(ticket_id: turn.ticket_id, outcome: "escalated", topic: "helpdesk.agent.dlq.v1")
    expect(handoff_items.sole.payload).to include("reason" => "falha_de_integracao", "source" => "dlq")
  end

  it "RN-47: a reentrega da mesma mensagem não grava outra linha" do
    turn = opened_turn
    produce(turn_event_body(turn), headers: dlq_headers(source: "broker", reason: "contrato", event_id: turn.event_id))
    consumer.consume
    message = consumer.messages.last

    DeadLetters::Record.call(topic: message.topic, partition: message.partition, offset: message.offset,
                             payload: message.raw_payload, headers: message.headers, key: message.key)

    expect(DeadLetter.count).to eq(1)
    expect(handoff_items.count).to eq(1)
  end

  it "mensagem sem chave nem cabeçalhos é gravada e o offset confirmado" do
    produce("x", headers: {}, key: nil)

    consumer.consume

    expect(DeadLetter.sole).to have_attributes(source: "unknown", outcome: "uncorrelated")
    expect(consumer.coordinator.seek_offset).to eq(consumer.messages.last.offset + 1)
  end
end
