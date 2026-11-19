require "rails_helper"

RSpec.describe OutboxJob, "RNF-14: o worker processa o outbox pelo ID" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  it "aviso da ingestão: abre o turno e enfileira a publicação do evento" do
    received = ingest
    clear_enqueued_jobs

    described_class.perform_now(received_item(received).id)

    turn = AiTurn.sole
    expect(described_class).to have_been_enqueued.with(turn.event_id).on_queue("critical")
  end

  it "evento do agente: publica no broker" do
    stub_broker
    received = ingest
    described_class.perform_now(received_item(received).id)

    described_class.perform_now(AiTurn.sole.event_id)

    expect(OutboxEvent.find(AiTurn.sole.event_id).published_at).to eq(start)
  end

  it "falha transitória: agenda o despertador para o next_attempt_at gravado no Postgres" do
    stub_broker({ status: 503 })
    received = ingest
    described_class.perform_now(received_item(received).id)
    clear_enqueued_jobs

    described_class.perform_now(AiTurn.sole.event_id)

    item = OutboxEvent.find(AiTurn.sole.event_id)
    job = enqueued_jobs.sole
    expect(job).to include(job: described_class, args: [ item.id ])
    expect(Time.zone.at(job[:at])).to be_within(0.001).of(item.next_attempt_at)
  end

  it "repetição: item encerrado não faz nada" do
    received = ingest
    item = received_item(received)
    item.update!(completed_at: start)

    described_class.perform_now(item.id)

    expect(AiTurn.count).to eq(0)
  end

  it "item inexistente é ignorado" do
    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end
end
