require "rails_helper"

# ROADMAP 10, "pronto quando": pedir humano durante uma consulta invalida o turno e o caso vai para a fila. Caminho
# real: webhook do canal → ingestão → scheduler (Deadlines::DispatchDue) → OutboxJob → Turns::Open → publicação no
# broker (stub de spec/support/broker.rb) → pedido de humano pelo webhook → OutboxJob → Handoff::Escalate → resposta
# atrasada do agente (AgentActions::Apply) rejeitada (RN-34, RF-39, RN-38, RN-56).
RSpec.describe "RN-34, RF-39: pedido de humano durante a consulta, de ponta a ponta" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let!(:queue) { default_queue(infinitepay) }
  let(:t0) { Time.utc(2026, 11, 22, 13, 40, 0) }

  around { |example| travel_to(t0) { example.run } }

  def post_chat(text, message_id: SecureRandom.uuid)
    raw = { message_id:, account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021", text:,
            sent_at: "2026-11-22T13:40:00.000Z" }.to_json
    post "/webhooks/chat/infinitepay-chat-mock", params: raw, headers: {
      "CONTENT_TYPE" => "application/json",
      HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret: account.secret)
    }
  end

  # O scheduler no fim da janela, e o worker processando o que ele registrou.
  def scheduler_tick
    allow(DatabaseClock).to receive(:now) { Time.current }
    ids = Deadlines::DispatchDue.call(now: Time.current, limit: 10)
    perform_enqueued_jobs { ids.each { OutboxJob.perform_later(_1) } }
  end

  it "o turno publicado expira, o caso vai a aguardando_humano e a resposta atrasada não sai ao cliente" do
    stub_broker
    stub_channels({ status: 200, message_id: "chat_out_notice" })
    perform_enqueued_jobs { post_chat("meu repasse não caiu") }
    travel 2.seconds
    scheduler_tick
    turn = AiTurn.sole
    expect(turn.status).to eq("eligible")
    expect(broker_requests.size).to eq(1)

    travel 1.second
    perform_enqueued_jobs { post_chat("quero falar com um atendente") }
    expect(response).to have_http_status(:accepted)

    ticket = Ticket.sole
    expect(ticket).to have_attributes(state: "aguardando_humano", assignment_version: 1, queue_id: queue.id,
                                      first_pending_seq: nil, dispatch_due_at: nil, ai_deadline_at: nil)
    expect(turn.reload.status).to eq("expired")
    expect(audits(ticket, "customer.human_requested").sole.data).to include("seq" => 2, "outcome" => "handoff_pedido")
    expect(audits(ticket, "ticket.escalated").sole.data).to include("reason" => "pedido_do_cliente", "source" => "ingestion")
    expect(handoff_items(ticket).sole.completed_at).to be_present

    travel 1.second
    late = AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)
    expect(late.status).to eq(:rejected)
    expect(late.reason).to be_in(%w[atribuicao_mudou handoff_pedido])

    travel 60.seconds
    scheduler_tick
    expect(Message.where(ticket_id: ticket.id, direction: "outbound", author_type: "bot")).to be_empty
    expect(Delivery.where(ticket_id: ticket.id, kind: %w[reply resolution progress])).to be_empty
    expect(broker_requests.size).to eq(1)
    expect(ticket.reload.ai_turns.count).to eq(1)
    # RN-42: o cliente recebe só o aviso de transferência.
    expect(channel_requests.map { JSON.parse(_1.body)["text"] }).to eq([ Handoff::Policy::DEFAULT.transfer_notice_text("pt-BR") ])
  end

  it "RF-39 a RF-42 (aceite): repetir o pedido na fila humana não duplica o handoff" do
    stub_broker
    stub_channels({ status: 200, message_id: "chat_out_notice" })
    perform_enqueued_jobs { post_chat("quero falar com um atendente") }
    perform_enqueued_jobs { post_chat("preciso falar com uma pessoa, por favor") }

    ticket = Ticket.sole
    expect(ticket.state).to eq("aguardando_humano")
    expect(handoff_items(ticket).count).to eq(1)
    expect(audits(ticket, "ticket.escalated").count).to eq(1)
    expect(audits(ticket, "customer.human_requested").map { _1.data["outcome"] }).to eq(%w[handoff_pedido registrado])
    expect(broker_requests).to be_empty
  end
end
