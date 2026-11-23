require "rails_helper"

RSpec.describe Distribution::ReturnToQueue, "RN-31: devolução concorrente", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:offline_since) { Time.zone.parse("2026-11-24 10:00:00") }

  before { allow(DatabaseClock).to receive(:now) { offline_since + 10.minutes } }

  it "dois workers no mesmo item devolvem uma vez só e liberam uma vaga só" do
    setup = distribution_setup(infinitepay)
    analyst = analyst_in(setup[:team], status: "offline").tap { _1.update_columns(status_changed_at: offline_since) }
    ticket = case_with(analyst, brand: infinitepay, queue: setup[:queue], identity: "acc_a")
    Deadlines::AnalystOffline.call(now: offline_since + 10.minutes, limit: 10)
    item = OutboxEvent.find_by!(ticket_id: ticket.id, event_type: "analyst.offline")

    results = run_concurrently(threads: 2) { described_class.call(item.id) }

    expect(results).to all(be_a(Data))
    expect(results.map(&:status).sort).to eq(%i[already_done returned])
    expect(analyst.reload.active_count).to eq(0)
    expect(ticket.reload).to have_attributes(state: "aguardando_humano", assignment_version: 2)
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.returned_to_queue").count).to eq(1)
  end

  it "duas voltas do scheduler registram um item só por caso" do
    setup = distribution_setup(infinitepay)
    analyst = analyst_in(setup[:team], status: "offline").tap { _1.update_columns(status_changed_at: offline_since) }
    case_with(analyst, brand: infinitepay, queue: setup[:queue], identity: "acc_a")

    results = run_concurrently(threads: 2) { Deadlines::AnalystOffline.call(now: offline_since + 10.minutes, limit: 10) }

    expect(results.flatten.size).to eq(1)
    expect(OutboxEvent.where(event_type: "analyst.offline").count).to eq(1)
  end

  it "devolução e atribuição ao mesmo tempo: a vaga nunca fica negativa nem passa da capacidade" do
    setup = distribution_setup(infinitepay)
    gone = analyst_in(setup[:team], status: "offline", capacity: 1).tap { _1.update_columns(status_changed_at: offline_since) }
    stays = analyst_in(setup[:team], status: "online", capacity: 1)
    returning = case_with(gone, brand: infinitepay, queue: setup[:queue], identity: "acc_a")
    waiting = waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_b")
    Deadlines::AnalystOffline.call(now: offline_since + 10.minutes, limit: 10)
    item = OutboxEvent.find_by!(ticket_id: returning.id, event_type: "analyst.offline")

    run_concurrently(threads: 2) do |i|
      i.zero? ? described_class.call(item.id) : Distribution::Assign.call(ticket_id: waiting.id, brand_id: infinitepay.id)
    end

    expect([ gone.reload.active_count, stays.reload.active_count ]).to eq([ 0, 1 ])
    expect(returning.reload.state).to eq("aguardando_humano")
    expect(waiting.reload).to have_attributes(state: "com_analista", assignee_id: stays.id)
  end
end
