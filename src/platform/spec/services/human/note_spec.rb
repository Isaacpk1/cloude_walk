require "rails_helper"

# RN-50: nota interna nunca vai ao cliente (RF-49).
RSpec.describe Human::Note, "RN-50: nota interna" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:setup) { distribution_setup(infinitepay) }
  let!(:ana) { analyst_in(setup[:team]) }
  let!(:ticket) { case_with(ana, brand: infinitepay, queue: setup[:queue], identity: "acc_1") }

  it "grava mensagem interna, sem entrega nem outbox, e audita" do
    result = described_class.call(ticket_id: ticket.id, brand_id: infinitepay.id, user: ana, text: "Cliente já ligou três vezes")

    expect(result.status).to eq(:noted)
    note = Message.where(ticket_id: ticket.id, internal: true).sole
    expect(note).to have_attributes(author_type: "analyst", author_id: ana.id, direction: "outbound", seq: 2)
    expect(Delivery.count).to eq(0)
    expect(OutboxEvent.where(event_type: "delivery.requested")).to be_empty
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "analyst.noted")).to exist
  end

  it "não muda o contexto que a IA veria nem o estado" do
    before = ticket.reload.context_version

    described_class.call(ticket_id: ticket.id, brand_id: infinitepay.id, user: ana, text: "nota")

    expect(ticket.reload).to have_attributes(context_version: before, state: "com_analista")
  end

  it "só o responsável anota, e texto em branco é recusado" do
    other = analyst_in(setup[:team])

    expect(described_class.call(ticket_id: ticket.id, brand_id: infinitepay.id, user: other, text: "x").reason).to eq("nao_e_o_responsavel")
    expect(described_class.call(ticket_id: ticket.id, brand_id: infinitepay.id, user: ana, text: "").reason).to eq("texto_vazio")
  end
end
