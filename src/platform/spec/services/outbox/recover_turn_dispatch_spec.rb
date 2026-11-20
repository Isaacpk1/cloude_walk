require "rails_helper"

RSpec.describe Outbox::Recover, "ADR-016: a recuperação reoferece a ação de abertura do turno" do
  include ActiveJob::TestHelper

  let!(:brand) { create(:brand, :infinitepay) }
  let(:now) { Time.zone.parse("2026-11-18T21:00:00Z") }

  around { |example| travel_to(now) { example.run } }

  it "reoferece a ação turn.dispatch aberta cujo job o Redis perdeu" do
    item = due_dispatch(ingest)
    item.update!(next_attempt_at: now - 10.seconds)
    clear_enqueued_jobs

    expect(described_class.call).to include(item.id)
    expect(OutboxJob).to have_been_enqueued.with(item.id)
  end

  it "o laço do worker (Sweeper) também reoferece a ação" do
    item = due_dispatch(ingest)
    item.update!(next_attempt_at: now - 10.seconds)
    clear_enqueued_jobs

    Outbox::Sweeper.run_once

    expect(OutboxJob).to have_been_enqueued.with(item.id)
  end
end
