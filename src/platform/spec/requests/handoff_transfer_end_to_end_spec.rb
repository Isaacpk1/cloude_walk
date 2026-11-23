require "rails_helper"

# Bloco 10, ponta a ponta pelo caminho real (exemplo da RN-38; RF-06 + RF-39 + RF-43 "entrega no handoff"):
# webhook do chat → ingestão → scheduler → turno → ação reply aplicada (saída pending) → o cliente pede humano →
# pedido de handoff → OutboxJob (Handoff::Escalate) → OutboxJob (Deliveries::Send) → provedor do chat simulado
# (WebMock no formato do channels-mock). O AgentActions::Apply usa o relógio do banco: aqui não há travel_to.
#
# A detecção do pedido na ingestão (RN-34) é do agente E1 do bloco 10: aqui o pedido é gravado como ela gravará,
# com Handoff::Request(reason: "pedido_do_cliente", source: "ingestion").
RSpec.describe "RN-38, RN-42: cliente pede humano com uma resposta do bot ainda na fila", type: :request do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let!(:escalas) do
    queue = create(:queue_record, team: create(:team, brand: infinitepay), escalation: true)
    queue.publish_version!(name: "Escalas N1", created_by: nil, ai_first: false)
    queue.reload
  end

  def post_chat(text)
    raw = { message_id: SecureRandom.uuid, account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021",
            text:, sent_at: Time.current.utc.iso8601(3) }.to_json
    post "/webhooks/chat/infinitepay-chat-mock", params: raw, headers: {
      "CONTENT_TYPE" => "application/json", "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret: account.secret)
    }
    expect(response).to have_http_status(:accepted)
  end

  it "recebe o aviso de transferência sem aquela resposta, e o caso entra na fila de escalas" do
    stub_broker
    stub_channels({ status: 200, message_id: "chat_out_notice" })

    post_chat("meu repasse não caiu")
    ticket = Ticket.sole
    # A janela vence (o scheduler grava a ação; aqui sem travel_to, pelo Apply) e o worker abre o turno e publica.
    perform_enqueued_jobs(only: OutboxJob) { OutboxJob.perform_now(due_dispatch(ticket).id) }
    turn = AiTurn.sole
    expect(AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT).status).to eq(:applied)
    reply = Delivery.find_by!(ticket_id: ticket.id, kind: "reply")
    expect(reply.status).to eq("pending") # o worker ainda não pegou a resposta

    clear_enqueued_jobs
    post_chat("quero falar com um atendente") # RN-34: a ingestão detecta o pedido e grava o handoff
    handoff_id = OutboxEvent.find_by!(ticket_id: ticket.id, event_type: "handoff.requested").id
    expect(OutboxEvent.find(handoff_id).payload).to include("reason" => "pedido_do_cliente", "source" => "ingestion")
    clear_enqueued_jobs

    perform_enqueued_jobs(only: OutboxJob) { OutboxJob.perform_now(handoff_id) }
    # O job da resposta chega atrasado: ela já foi cancelada e não sai.
    OutboxJob.perform_now(delivery_item(reply).id)

    expect(reply.reload).to have_attributes(status: "cancelled", last_error: "handoff")
    request = channel_requests.sole
    verify_channel_request!(request, secret: account.secret)
    expect(JSON.parse(request.body)).to include("text" => Handoff::Policy::DEFAULT.transfer_notice_text("pt-BR"),
                                                "customer_ref" => "cus_ref_000021")
    notice = Delivery.find_by!(ticket_id: ticket.id, kind: "handoff_notice")
    expect(notice).to have_attributes(status: "delivered", provider_message_id: "chat_out_notice")
    expect(request.headers["Idempotency-Key"]).to eq(notice.delivery_id)
    expect(request.headers["X-Conversation-Seq"]).to eq(notice.seq.to_s)
    expect(ticket.reload).to have_attributes(state: "aguardando_humano", queue_id: escalas.id)
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.escalated").sole.data)
      .to include("queue_kind" => "escalation", "transfer_delivery_id" => notice.delivery_id, "summary_status" => "pending")
  end

  it "C1 (revisão do bloco 10): o job da resposta roda entre o pedido e o Escalate: mesmo assim, só o aviso sai" do
    stub_broker
    stub_channels({ status: 200, message_id: "chat_out_notice" })

    post_chat("meu repasse não caiu")
    ticket = Ticket.sole
    perform_enqueued_jobs(only: OutboxJob) { OutboxJob.perform_now(due_dispatch(ticket).id) }
    turn = AiTurn.sole
    AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)
    reply = Delivery.find_by!(ticket_id: ticket.id, kind: "reply")

    clear_enqueued_jobs
    post_chat("quero falar com um atendente")
    clear_enqueued_jobs
    OutboxJob.perform_now(delivery_item(reply).id) # antes do Escalate
    handoff_id = OutboxEvent.find_by!(ticket_id: ticket.id, event_type: "handoff.requested").id
    perform_enqueued_jobs(only: OutboxJob) { OutboxJob.perform_now(handoff_id) }

    expect(reply.reload.status).to eq("cancelled")
    expect(channel_requests.map { JSON.parse(_1.body)["text"] }).to eq([ Handoff::Policy::DEFAULT.transfer_notice_text("pt-BR") ])
  end
end
