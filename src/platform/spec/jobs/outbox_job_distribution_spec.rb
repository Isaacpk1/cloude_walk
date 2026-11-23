require "rails_helper"

RSpec.describe OutboxJob, "bloco 13: devolução por offline e alertas de SLA" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:setup) { distribution_setup(infinitepay) }
  let(:started) { Time.zone.parse("2026-11-24 10:00:00") }

  it "HANDLED cobre os três tipos, para a recuperação do outbox reoferecer" do
    expect(described_class::HANDLED).to include("analyst.offline", "sla.alert", "sla.breach")
  end

  it "analyst.offline: chama a devolução e conclui o item" do
    allow(DatabaseClock).to receive(:now) { started + 10.minutes }
    analyst = analyst_in(setup[:team], status: "offline").tap { _1.update_columns(status_changed_at: started) }
    ticket = case_with(analyst, brand: infinitepay, queue: setup[:queue], identity: "acc_a")
    id = Deadlines::AnalystOffline.call(now: started + 10.minutes, limit: 5).sole

    described_class.perform_now(id)

    expect(ticket.reload.state).to eq("aguardando_humano")
    expect(OutboxEvent.find(id).completed_at).to be_present
  end

  it "sla.alert: antes dos 80% pelo relógio do banco, deixa o despertador no prazo gravado" do
    ticket = waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_b", started_at: started, sla_due_at: started + 10.minutes)
    id = Deadlines::SlaAlert.call(now: started + 8.minutes, limit: 5).sole
    allow(DatabaseClock).to receive(:now) { started + 7.minutes }

    expect { described_class.perform_now(id) }.to have_enqueued_job(described_class).with(id).at(started + 8.minutes)

    expect(OutboxEvent.find(id).completed_at).to be_nil
    expect(ticket.reload.sla_alerted_at).to be_nil
  end

  it "sla.breach: marca o estouro no prazo" do
    ticket = waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_c", started_at: started, sla_due_at: started + 10.minutes)
    id = Deadlines::SlaBreach.call(now: started + 10.minutes, limit: 5).sole
    allow(DatabaseClock).to receive(:now) { started + 10.minutes }

    described_class.perform_now(id)

    expect(ticket.reload.sla_breached).to be(true)
  end

  it "repetição: reentregar o job de um item concluído não faz nada" do
    waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_d", started_at: started, sla_due_at: started + 10.minutes)
    id = Deadlines::SlaBreach.call(now: started + 10.minutes, limit: 5).sole
    allow(DatabaseClock).to receive(:now) { started + 10.minutes }
    described_class.perform_now(id)

    expect { described_class.perform_now(id) }.not_to change(AuditEvent, :count)
  end
end
