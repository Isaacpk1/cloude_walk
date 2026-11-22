require "rails_helper"

# Interface dos blocos 08 e 09, item 1; RN-57 (07, seção 3.4): o aviso de progresso só sai enquanto o ciclo está com a IA.
# Pedido o handoff, o aviso do ciclo deixa de ser devido: nem o scheduler o registra, nem o painel o mostra como atrasado.
RSpec.describe "RN-57, RN-46: Handoff::Request encerra o aviso de progresso devido" do
  let!(:infinitepay) { create(:brand, :infinitepay) }

  def request(ticket)
    ActiveRecord::Base.transaction do
      locked = Ticket.lock.find(ticket.id)
      Handoff::Request.call(ticket: locked, reason: "contexto_excede_limite", source: "turns", turn: nil, trace_id: "a" * 32)
    end
  end

  it "zera progress_due_at junto com o pedido" do
    ticket = ingest.ticket
    expect(ticket.reload.progress_due_at).to be_present

    expect(request(ticket)).to be_present
    expect(ticket.reload.progress_due_at).to be_nil
  end

  it "o scheduler não registra o aviso depois do pedido" do
    ticket = ingest.ticket
    request(ticket)

    travel 16.seconds do
      allow(DatabaseClock).to receive(:now) { Time.current }
      expect(Deadlines::ProgressDue.call(now: Time.current, limit: 10)).to be_empty
    end
  end

  it "repetição: o segundo pedido na mesma atribuição não grava nada e não mexe no ciclo" do
    ticket = ingest.ticket
    request(ticket)
    before = ticket.reload.attributes.slice("first_pending_seq", "ai_deadline_at", "assignment_version")

    expect(request(ticket)).to be_nil
    expect(ticket.reload.attributes.slice("first_pending_seq", "ai_deadline_at", "assignment_version")).to eq(before)
  end
end
