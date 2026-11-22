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

  describe "bloco 10: gatilhos novos (RN-33, itens 1, 2 e 6; RN-34)" do
    def request_with(ticket, **kw)
      ActiveRecord::Base.transaction do
        Handoff::Request.call(ticket: Ticket.lock.find(ticket.id), trace_id: "b" * 32, turn: nil, **kw)
      end
    end

    it "aceita pedido do cliente pela ingestão, decisão do agente e limite de trocas" do
      { "pedido_do_cliente" => "ingestion", "decisao_do_agente" => "agent", "limite_de_trocas" => "agent" }.each do |reason, source|
        ticket = ingest(identity: "acc_infinitepay_#{reason}").ticket
        expect(request_with(ticket, reason:, source:)).to be_present
      end
    end

    it "RN-39: o resumo do agente vai no payload do pedido, e a auditoria só registra que ele veio" do
      ticket = ingest.ticket
      summary = HandoffSummary::FIELDS.index_with { "texto sintético" }
      id = request_with(ticket, reason: "decisao_do_agente", source: "agent", summary:)

      expect(OutboxEvent.find(id).payload["summary"]).to eq(summary)
      audit = AuditEvent.where(ticket_id: ticket.id, event_type: "handoff.requested").sole
      expect(audit.data).to include("summary_from_agent" => true)
      expect(audit.data).not_to have_key("summary")
    end

    it "sem resumo do agente, o payload não leva a chave e a auditoria marca false" do
      ticket = ingest.ticket
      id = request_with(ticket, reason: "pedido_do_cliente", source: "ingestion")

      expect(OutboxEvent.find(id).payload).not_to have_key("summary")
      expect(AuditEvent.where(ticket_id: ticket.id, event_type: "handoff.requested").sole.data["summary_from_agent"]).to be(false)
    end
  end
end
