require "rails_helper"

# RN-57 (07, seção 3.4, "Regras de tempo"; ADR-016): a ingestão grava o prazo do aviso de progresso quando abre
# o ciclo pendente, uma vez por ciclo. As mensagens seguintes do mesmo ciclo não mexem nele.
RSpec.describe Ingestion::Receive, "RN-57: prazo do aviso de progresso gravado na ingestão" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }

  def ingest_at(time, text = "oi", brand: "infinitepay")
    travel_to(time, with_usec: true) { ingest(text, brand:, identity: "acc_progresso_#{brand}") }
  end

  def last_received_audit(ticket)
    AuditEvent.where(ticket_id: ticket.id, event_type: "message.received").order(:id).last
  end

  describe "RN-57: a primeira mensagem pendente abre o ciclo e o prazo do aviso" do
    it "grava progress_due_at = first_pending_at + 15 s" do
      ticket = ingest_at(t0).ticket.reload

      expect(ticket).to have_attributes(first_pending_seq: 1, first_pending_at: t0, progress_due_at: t0 + 15.seconds)
    end

    it "RF-54: a auditoria message.received traz o progress_due_at" do
      ticket = ingest_at(t0).ticket

      expect(last_received_audit(ticket).data).to include("progress_due_at" => (t0 + 15.seconds).iso8601(3))
    end

    it "marca: a JIM usa o mesmo prazo da política (até o bloco 12)" do
      ticket = ingest_at(t0, brand: "jim").ticket.reload

      expect(ticket).to have_attributes(brand_id: jim.id, progress_due_at: t0 + 15.seconds)
    end
  end

  describe "RN-57: um aviso por ciclo, não um por mensagem" do
    it "o cliente escreve a cada 2 s e o prazo continua aos 15 s da primeira pendente" do
      ingest_at(t0)
      ticket = (1..7).map { ingest_at(t0 + (2 * _1).seconds).ticket }.last.reload

      expect(ticket).to have_attributes(latest_customer_seq: 8, first_pending_seq: 1, progress_due_at: t0 + 15.seconds)
      expect(last_received_audit(ticket).data).to include("progress_due_at" => (t0 + 15.seconds).iso8601(3))
    end

    it "ordem: o ciclo novo, depois da resposta aplicada, ganha um prazo novo desde a sua primeira mensagem" do
      ticket = ingest_at(t0).ticket
      ticket.update_columns(first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil,
                            progress_due_at: nil)

      ticket = ingest_at(t0 + 30.seconds).ticket.reload

      expect(ticket).to have_attributes(first_pending_seq: 2, progress_due_at: t0 + 45.seconds)
    end
  end

  describe "caso fora da IA" do
    it "não ganha prazo de aviso" do
      ticket = ingest_at(t0).ticket
      ticket.update_columns(state: "com_analista", assignee_id: create(:user).id, first_pending_seq: nil,
                            first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil, progress_due_at: nil)

      ticket = ingest_at(t0 + 1.second).ticket.reload

      expect(ticket.progress_due_at).to be_nil
      expect(last_received_audit(ticket).data).to include("progress_due_at" => nil)
    end
  end

  it "o banco recusa progress_due_at sem ciclo aberto (tickets_progress_requires_cycle_check)" do
    ticket = ingest_at(t0).ticket

    expect do
      ticket.update_columns(first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil,
                            progress_due_at: t0 + 15.seconds)
    end.to raise_error(ActiveRecord::CheckViolation, /tickets_progress_requires_cycle_check/)
  end
end
