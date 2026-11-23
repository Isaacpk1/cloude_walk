require "rails_helper"

RSpec.describe Sla::Start, "RN-23, RN-32: início do SLA na entrada da fila humana" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:setup) { distribution_setup(brand) }
  let(:now) { Time.zone.parse("2026-11-24 10:00:00") }
  let(:ticket) { ingest("oi", brand: "infinitepay", identity: "acc_s").ticket.tap { _1.update_columns(queue_id: setup[:queue].id, queue_version: 1, priority: "alta") } }

  it "RN-21: grava o início e o prazo de assunção da prioridade" do
    described_class.call(ticket:, now:)

    expect(ticket.reload).to have_attributes(sla_started_at: now, sla_due_at: now + 900.seconds)
  end

  it "usa a política da versão da fila do caso" do
    setup[:queue].publish_version!(name: "N1", created_by: nil, sla_policy: { "alta" => { "assume_s" => 120 } })
    ticket.update_columns(queue_version: 2)

    described_class.call(ticket:, now:)

    expect(ticket.reload.sla_due_at).to eq(now + 120.seconds)
  end

  it "RN-13: sem prioridade vale média" do
    ticket.update_columns(priority: nil)

    described_class.call(ticket:, now:)

    expect(ticket.reload.sla_due_at).to eq(now + 3600.seconds)
  end

  it "RN-23, RN-32: repetir ou escalar de novo não reinicia o relógio" do
    described_class.call(ticket:, now:)
    described_class.call(ticket:, now: now + 30.minutes)

    expect(ticket.reload).to have_attributes(sla_started_at: now, sla_due_at: now + 900.seconds)
  end

  it "devolve o prazo gravado" do
    expect(described_class.call(ticket:, now:)).to eq(now + 900.seconds)
  end
end
