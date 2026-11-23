require "rails_helper"

# Bloco 14 (07, seção 3.6; RF-48, RN-30, RN-54): resolver com motivo, liberando a vaga.
RSpec.describe Human::Resolve, "RF-48: resolver o atendimento" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:setup) { distribution_setup(infinitepay) }
  let!(:ana) { analyst_in(setup[:team], active_count: 0) }
  let!(:ticket) { case_with(ana, brand: infinitepay, queue: setup[:queue], identity: "acc_1") }

  def resolve(reason: "problema_resolvido", text: nil, user: ana, brand_id: infinitepay.id)
    described_class.call(ticket_id: ticket.id, brand_id:, user:, reason:, text:)
  end

  it "vai a resolvido, libera a vaga e audita o motivo" do
    expect(ana.reload.active_count).to eq(1)

    result = resolve

    expect(result.status).to eq(:resolved)
    expect(ticket.reload).to have_attributes(state: "resolvido", assignee_id: ana.id)
    expect(ana.reload.active_count).to eq(0)
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.resolved").sole.data)
      .to include("reason" => "problema_resolvido", "user_id" => ana.id, "state_from" => "com_analista")
  end

  it "com texto de encerramento, grava a mensagem e a entrega kind resolution" do
    result = resolve(text: "Fico à disposição.")

    message = Message.where(ticket_id: ticket.id, direction: "outbound").sole
    expect(message).to have_attributes(author_type: "analyst", body: "Fico à disposição.")
    expect(Delivery.find_by!(message_id: message.id).kind).to eq("resolution")
    expect(result.delivery_event_id).to be_present
  end

  it "sem texto, não há mensagem nem entrega" do
    resolve

    expect(Message.where(direction: "outbound")).to be_empty
    expect(Delivery.count).to eq(0)
  end

  it "motivo fora da lista é recusado e nada muda" do
    expect(resolve(reason: "porque_sim").reason).to eq("motivo_invalido")
    expect(resolve(reason: nil).reason).to eq("motivo_invalido")
    expect(ticket.reload.state).to eq("com_analista")
    expect(ana.reload.active_count).to eq(1)
  end

  it "repetição: resolver duas vezes não libera a vaga duas vezes" do
    resolve
    second = resolve

    expect(second.status).to eq(:rejected)
    expect(second.reason).to eq("caso_fora_do_analista")
    expect(ana.reload.active_count).to eq(0)
  end

  it "só o responsável resolve; marca errada é como inexistente" do
    other = analyst_in(setup[:team])

    expect(resolve(user: other).reason).to eq("nao_e_o_responsavel")
    expect(resolve(brand_id: jim.id).reason).to eq("atendimento_inexistente")
    expect(ticket.reload.state).to eq("com_analista")
  end

  it "a vaga nunca fica abaixo de zero" do
    ana.update_columns(active_count: 0)

    resolve

    expect(ana.reload.active_count).to eq(0)
  end
end
