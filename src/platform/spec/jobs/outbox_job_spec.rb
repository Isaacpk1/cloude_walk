require "rails_helper"

RSpec.describe OutboxJob, "RNF-14: o worker processa o outbox pelo ID" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  it "RN-55, ADR-016: ação turn.dispatch do scheduler abre o turno e enfileira a publicação do evento" do
    item = due_dispatch(ingest)
    clear_enqueued_jobs

    described_class.perform_now(item.id)

    turn = AiTurn.sole
    expect(item.reload.completed_at).to eq(start)
    expect(described_class).to have_been_enqueued.with(turn.event_id).on_queue("critical")
  end

  it "ação turn.dispatch descartada não enfileira publicação" do
    received = ingest
    item = due_dispatch(received)
    received.ticket.update_columns(assignment_version: 1)
    clear_enqueued_jobs

    described_class.perform_now(item.id)

    expect(AiTurn.count).to eq(0)
    expect(enqueued_jobs).to be_empty
  end

  it "RN-55: o aviso message.received é encerrado sem abrir turno (a triagem entra no bloco 11)" do
    received = ingest
    clear_enqueued_jobs

    described_class.perform_now(received_item(received).id)

    expect(AiTurn.count).to eq(0)
    expect(OutboxEvent.where(event_type: "agent.event")).to be_empty
    expect(received_item(received).completed_at).to eq(start)
    expect(enqueued_jobs).to be_empty
  end

  it "evento do agente: publica no broker" do
    stub_broker
    described_class.perform_now(due_dispatch(ingest).id)

    described_class.perform_now(AiTurn.sole.event_id)

    expect(OutboxEvent.find(AiTurn.sole.event_id).published_at).to eq(start)
  end

  it "falha transitória: agenda o despertador para o next_attempt_at gravado no Postgres" do
    stub_broker({ status: 503 })
    described_class.perform_now(due_dispatch(ingest).id)
    clear_enqueued_jobs

    described_class.perform_now(AiTurn.sole.event_id)

    item = OutboxEvent.find(AiTurn.sole.event_id)
    job = enqueued_jobs.sole
    expect(job).to include(job: described_class, args: [ item.id ])
    expect(Time.zone.at(job[:at])).to be_within(0.001).of(item.next_attempt_at)
  end

  describe "RF-06: delivery.requested" do
    let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }

    it "envia a saída ao provedor do chat" do
      delivery = requested_delivery(customer_message.ticket)
      stub_channels

      described_class.perform_now(delivery_item(delivery).id)

      expect(delivery.reload.status).to eq("delivered")
      expect(channel_requests.size).to eq(1)
    end

    it "RN-43: falha transitória agenda o despertador para o next_attempt_at do item" do
      delivery = requested_delivery(customer_message.ticket)
      stub_channels(status: 503)
      clear_enqueued_jobs

      described_class.perform_now(delivery_item(delivery).id)

      job = enqueued_jobs.sole
      expect(job).to include(job: described_class, args: [ delivery_item(delivery).id ])
      expect(Time.zone.at(job[:at])).to be_within(0.001).of(delivery_item(delivery).next_attempt_at)
    end
  end

  it "repetição: ação encerrada não faz nada" do
    item = due_dispatch(ingest)
    item.update!(completed_at: start)

    described_class.perform_now(item.id)

    expect(AiTurn.count).to eq(0)
  end

  it "item inexistente é ignorado" do
    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end
end
