require "rails_helper"

RSpec.describe Sla::Recalculate, "RN-14, RN-25: prazo quando a prioridade sobe" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:now) { Time.zone.parse("2026-11-24 10:00:00") }
  let(:ticket) do
    ingest("oi", brand: "infinitepay", identity: "acc_r").ticket.tap do
      _1.update_columns(priority: "media", sla_started_at: now, sla_due_at: now + 3600.seconds)
    end
  end

  it "a prioridade nova encurta o prazo, contado desde o início do SLA" do
    ticket.update_columns(priority: "alta")

    described_class.call(ticket:)

    expect(ticket.reload.sla_due_at).to eq(now + 900.seconds)
  end

  it "nunca empurra o prazo para depois do que já valia" do
    ticket.update_columns(priority: "baixa")

    described_class.call(ticket:)

    expect(ticket.reload.sla_due_at).to eq(now + 3600.seconds)
  end

  it "sem SLA iniciado, não faz nada" do
    ticket.update_columns(sla_started_at: nil, sla_due_at: nil, priority: "critica")

    described_class.call(ticket:)

    expect(ticket.reload).to have_attributes(sla_started_at: nil, sla_due_at: nil)
  end
end
