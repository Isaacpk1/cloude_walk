require "rails_helper"

RSpec.describe "RN-08, RN-09: mensagem depois de uma resolução" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:turn) { opened_turn("funcionou") }
  let(:ticket) { turn.ticket }

  before do
    payload = agent_action_for(turn, action: "resolve", resolution: { "reason" => "confirmado_pelo_cliente" }).except("reply")
    AgentActions::Apply.call(payload)
  end

  it "RN-08: no instante exato de 72 h reabre o mesmo caso e incrementa a atribuição" do
    version = ticket.reload.assignment_version
    travel_to(ticket.resolved_at + 72.hours, with_usec: true) do
      received = ingest("voltou a falhar")
      expect(received.ticket.id).to eq(ticket.id)
      expect(ticket.reload).to have_attributes(state: "com_ia", assignment_version: version + 1, resolved_at: nil)
      expect(ticket.first_pending_seq).to eq(received.message.seq)
    end
  end

  it "RN-09: depois de 72 h fecha o anterior e cria outro vinculado" do
    travel_to(ticket.reload.resolved_at + 72.hours + 0.001.seconds, with_usec: true) do
      received = ingest("outro problema")
      expect(received.ticket.id).not_to eq(ticket.id)
      expect(received.ticket.linked_ticket_id).to eq(ticket.id)
      expect(ticket.reload.state).to eq("fechado")
    end
  end

  it "RN-34: pedido explícito de humano não devolve o caso à IA" do
    received = ingest("quero falar com um atendente")
    expect(received.ticket.id).to eq(ticket.id)
    expect(ticket.reload.state).to eq("aguardando_humano")
    expect(ticket.dispatch_due_at).to be_nil
  end

  it "RF-53: o novo atendimento recebe o resumo persistido do anterior" do
    travel_to(ticket.reload.resolved_at + 73.hours) do
      next_case = ingest("preciso de ajuda")
      context = Turns::ContextBuilder.call(ticket: next_case.ticket, policy: Turns::Policy.for(brand), now: Time.current)
      expect(context.previous_tickets.sole.summary).to include("funcionou", "confirmado_pelo_cliente")
      expect(context.previous_tickets.sole.summary).not_to include("Sem resumo gravado")
    end
  end
end
