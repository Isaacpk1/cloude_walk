require "rails_helper"

RSpec.describe "RF-32, RN-36: resolução do atendimento pela IA" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:turn) { opened_turn("funcionou, obrigado") }
  let(:ticket) { turn.ticket }
  let(:action) do
    agent_action_for(turn, action: "resolve", resolution: { "reason" => "confirmado_pelo_cliente" }).except("reply")
  end

  it "RF-32: resolve sem texto, encerra o caso e registra o motivo na auditoria" do
    expect(AgentActions::Apply.call(action).status).to eq(:applied)

    expect(ticket.reload.state).to eq("resolvido")
    expect(AuditEvent.where(brand_id: brand.id, ticket_id: ticket.id, event_type: "ticket.resolved").sole.data)
      .to include("reason" => "confirmado_pelo_cliente", "state_from" => "com_ia", "state_to" => "resolvido")
    expect(Delivery.where(ticket_id: ticket.id)).to be_empty
  end

  it "RN-08, RF-52: persiste o marco da resolução e um resumo do problema, sem notas internas" do
    before_call = db_now
    AgentActions::Apply.call(action)

    expect(ticket.reload).to have_attributes(resolution_source: "agent", resolution_reason: "confirmado_pelo_cliente")
    expect(ticket.resolved_at).to be_between(before_call, db_now)
    expect(ticket.close_due_at).to eq(ticket.resolved_at + 72.hours)
    summary = TicketSummary.where(brand_id: brand.id, ticket_id: ticket.id).sole
    expect(summary.body).to include("funcionou, obrigado", "confirmado_pelo_cliente")
    expect(summary.resolved_at).to eq(ticket.resolved_at)
  end

  it "RN-47: repetir a ação não repete a resolução nem o resumo" do
    AgentActions::Apply.call(action)
    expect { AgentActions::Apply.call(action) }.not_to change { AuditEvent.where(event_type: "ticket.resolved").count }
    expect(TicketSummary.where(ticket_id: ticket.id).count).to eq(1)
  end

  it "RN-56: uma mensagem nova invalida a resolução antes do commit da ação" do
    turn
    ingest("ainda não funcionou")

    expect(AgentActions::Apply.call(action).status).to eq(:rejected)
    expect(ticket.reload.state).to eq("com_ia")
    expect(TicketSummary.where(ticket_id: ticket.id)).to be_empty
  end

  it "RNF-24: ação com marca errada não resolve nem grava resumo" do
    create(:brand, :jim)
    expect(AgentActions::Apply.call(action.merge("brand" => "jim")).status).to eq(:rejected)
    expect(ticket.reload.state).to eq("com_ia")
    expect(TicketSummary.where(ticket_id: ticket.id)).to be_empty
  end

  it "RNF-18: no instante exato do prazo a resolução é rejeitada" do
    payload = action
    allow(DatabaseClock).to receive(:now).and_return(turn.deadline_at)
    expect(AgentActions::Apply.call(payload).reason).to eq("prazo_vencido")
    expect(ticket.reload.state).to eq("com_ia")
  end

  it "RNF-14: falha ao persistir o resumo desfaz a ação inteira para permitir retentativa" do
    payload = action
    allow(TicketSummary).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "banco indisponível")
    expect { AgentActions::Apply.call(payload) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(ticket.reload.state).to eq("com_ia")
    expect(turn.reload.status).to eq("eligible")
    expect(ProcessedEvent.where(event_id: payload["event_id"])).to be_empty
  end
end
