require "rails_helper"

# RN-38 (exemplo: "se o cliente pedir humano com uma resposta do bot ainda na fila, recebe o aviso de transferência
# sem aquela resposta") e RN-34 ("escala imediatamente"): o marco é o commit do pedido, não a execução do Escalate.
# Achado C1/I1 da revisão de arquitetura do bloco 10.
RSpec.describe "RN-38, RN-34: saídas da IA canceladas no commit do pedido de handoff" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }

  before do
    default_queue(infinitepay)
    stub_channels({ status: 200, message_id: "chat_out_1" }, { status: 200, message_id: "chat_out_2" })
  end

  def applied_reply
    turn = opened_turn
    expect(AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT).status).to eq(:applied)
    [ turn.ticket.reload, Delivery.find_by!(ticket_id: turn.ticket_id, kind: "reply") ]
  end

  # O envio real até o canal, pelo webhook, está no spec/requests/handoff_transfer_end_to_end_spec.rb.
  it "C1: o job da resposta roda entre o pedido e o Escalate: a resposta não sai, só o aviso fica vivo" do
    ticket, reply = applied_reply
    ingest("quero falar com um atendente")

    expect(reply.reload).to have_attributes(status: "cancelled", last_error: "handoff")
    Deliveries::Send.call(delivery_item(reply).id) # o job atrasado da resposta
    expect(channel_requests).to be_empty
    Handoff::Escalate.call(handoff_items(ticket).sole.id)

    live = Delivery.where(ticket_id: ticket.id).where.not(status: "cancelled")
    expect(live.pluck(:kind)).to eq([ "handoff_notice" ])
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "delivery.cancelled").sole.data)
      .to include("delivery_id" => reply.delivery_id, "reason" => "handoff", "handoff_reason" => "pedido_do_cliente")
  end

  it "todo gatilho cancela no pedido (falha de integração pela DLQ)" do
    ticket, reply = applied_reply
    request_handoff(ticket, reason: "falha_de_integracao", source: "dlq")

    expect(reply.reload.status).to eq("cancelled")
  end

  it "limite de trocas: as respostas aplicadas ficam e saem antes do aviso" do
    ticket, reply = applied_reply
    request_handoff(ticket, reason: "limite_de_trocas", source: "agent")

    expect(reply.reload.status).to eq("pending")
  end

  it "I1: limite de trocas já pedido e o cliente pede humano antes do Escalate: a resposta pendente cai" do
    ticket, reply = applied_reply
    request_handoff(ticket, reason: "limite_de_trocas", source: "agent")

    ingest("quero falar com um atendente")

    expect(reply.reload.status).to eq("cancelled")
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "customer.human_requested").sole.data["outcome"])
      .to eq("handoff_ja_pedido")
  end

  it "uma saída já em sending não é cancelada (a conciliação decide, RN-38)" do
    ticket, reply = applied_reply
    reply.update_columns(status: "sending", lease_until: 1.minute.from_now)

    ingest("quero falar com um atendente")

    expect(reply.reload.status).to eq("sending")
    expect(ticket.reload.state).to eq("com_ia").or eq("novo")
  end

  it "invariante 6: a saída pendente de outra marca não é tocada" do
    _, reply = applied_reply
    jim = create(:brand, :jim)
    create(:provider_account, brand: jim, slug: "jim-chat-mock")
    ingest("I want to talk to a human", brand: "jim")

    expect(reply.reload.status).to eq("pending")
  end
end
