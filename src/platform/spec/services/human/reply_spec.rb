require "rails_helper"

# Bloco 14 (07, seção 3.6; RF-46, RN-27, RN-38, RN-50, invariantes 2, 3, 4, 6, 7): resposta do analista ao cliente.
RSpec.describe Human::Reply, "RF-46: resposta do analista" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:setup) { distribution_setup(infinitepay) }
  let!(:ana) { analyst_in(setup[:team], name: "Ana") }
  let!(:ticket) { case_with(ana, brand: infinitepay, queue: setup[:queue], identity: "acc_1") }

  def reply(text: "Oi, vou verificar o seu repasse.", user: ana, brand_id: infinitepay.id, ticket_id: ticket.id)
    described_class.call(ticket_id:, brand_id:, user:, text:)
  end

  it "grava a mensagem do analista, a entrega pendente e o item do outbox, e audita" do
    result = reply

    expect(result.status).to eq(:sent)
    message = Message.where(ticket_id: ticket.id, direction: "outbound").sole
    expect(message).to have_attributes(author_type: "analyst", author_id: ana.id, body: "Oi, vou verificar o seu repasse.",
                                       internal: false, seq: 2, channel: "chat")
    delivery = Delivery.find_by!(message_id: message.id)
    expect(delivery).to have_attributes(kind: "analyst", status: "pending", seq: 2, brand_id: infinitepay.id)
    expect(OutboxEvent.where(event_type: "delivery.requested", dedup_key: "delivery:#{delivery.delivery_id}")).to exist
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "analyst.replied").sole.data)
      .to include("message_id" => message.id, "delivery_id" => delivery.delivery_id, "user_id" => ana.id)
    expect(result.delivery_event_id).to be_present
  end

  it "sobe a versão do contexto e mantém o caso com o analista" do
    before = ticket.reload.context_version

    reply

    expect(ticket.reload).to have_attributes(state: "com_analista", assignee_id: ana.id, assignment_version: 1,
                                             context_version: before + 1)
  end

  it "texto em branco é recusado e nada é gravado" do
    expect(reply(text: "   ").reason).to eq("texto_vazio")
    expect(Message.where(direction: "outbound")).to be_empty
  end

  it "outro analista da mesma equipe não responde pelo caso" do
    other = analyst_in(setup[:team], name: "Bia")

    result = reply(user: other)

    expect([ result.status, result.reason ]).to eq([ :rejected, "nao_e_o_responsavel" ])
    expect(Message.where(direction: "outbound")).to be_empty
  end

  it "caso que não está com o analista (esperando fila, resolvido, com a IA) é recusado" do
    %w[aguardando_humano resolvido com_ia].each do |state|
      ticket.update_columns(state:)
      expect(reply.reason).to eq("caso_fora_do_analista"), state
    end
  end

  it "marca errada: o caso é de outra marca e a resposta é recusada como inexistente" do
    result = reply(brand_id: jim.id)

    expect([ result.status, result.reason ]).to eq([ :rejected, "atendimento_inexistente" ])
    expect(Message.where(direction: "outbound")).to be_empty
  end

  it "repetição: duas respostas seguidas geram duas mensagens com seq crescente e entregas distintas" do
    reply(text: "primeira")
    reply(text: "segunda")

    expect(Message.where(direction: "outbound").order(:seq).pluck(:seq, :body)).to eq([ [ 2, "primeira" ], [ 3, "segunda" ] ])
    expect(Delivery.pluck(:delivery_id).uniq.size).to eq(2)
  end

  it "falha no meio desfaz tudo (nada fica pela metade)" do
    allow(OutboxEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "falhou")

    expect { reply }.to raise_error(ActiveRecord::StatementInvalid)
    expect(Message.where(direction: "outbound")).to be_empty
    expect(Delivery.count).to eq(0)
  end
end
