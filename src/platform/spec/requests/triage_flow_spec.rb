require "rails_helper"

# Bloco 11, ponta a ponta pelo caminho real: webhook do canal → ingestão → OutboxJob (message.received) → triagem e
# atribuição (Triage::OnMessage) → scheduler (Deadlines::DispatchDue) → OutboxJob → Turns::Open → publicação no broker
# (stub de spec/support/broker.rb). O roteamento é o Routing::Evaluate da base: sem conjunto de regras, a fila padrão.
RSpec.describe "RF-12, RF-24, RN-28, RN-34: triagem de ponta a ponta" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let!(:config) { triage_setup(infinitepay) }
  let(:t0) { Time.utc(2026, 11, 22, 14, 0, 0) }

  around { |example| travel_to(t0) { example.run } }

  def post_chat(text, message_id: SecureRandom.uuid)
    raw = { message_id:, account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021", text:,
            sent_at: "2026-11-22T14:00:00.000Z" }.to_json
    post "/webhooks/chat/infinitepay-chat-mock", params: raw, headers: {
      "CONTENT_TYPE" => "application/json",
      HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret: account.secret)
    }
  end

  def scheduler_tick
    allow(DatabaseClock).to receive(:now) { Time.current }
    ids = Deadlines::DispatchDue.call(now: Time.current, limit: 10)
    perform_enqueued_jobs { ids.each { OutboxJob.perform_later(_1) } }
    ids
  end

  def audits(ticket, type) = AuditEvent.where(ticket_id: ticket.id, event_type: type).order(:id)

  it "RF-24: fila IA primeiro: o worker tria e atribui ao bot, e o turno abre e sai ao broker no fim da janela" do
    stub_broker
    perform_enqueued_jobs { post_chat("minha maquininha não liga") }
    expect(response).to have_http_status(:accepted)

    ticket = Ticket.sole
    expect(ticket).to have_attributes(state: "com_ia", assignee_id: config[:bot].id, category: "maquininha",
                                      priority: "critica", queue_id: config[:default].id, queue_version: 1,
                                      assignment_version: 0)
    expect(audits(ticket, "routing.decided").sole.data).to include("moment" => "criacao", "default" => true,
                                                                   "queue_name" => "Geral")
    expect(AiTurn.count).to eq(0)

    travel 2.seconds
    scheduler_tick

    turn = AiTurn.sole
    expect(turn).to have_attributes(status: "eligible", assignment_version: 0)
    expect(broker_requests.size).to eq(1)
    expect(JSON.parse(broker_requests.sole.body).dig("ticket", "state")).to eq("com_ia")
    expect(audits(ticket, "triage.classified").count).to eq(1)
    trace = Message.sole.trace_id
    expect(audits(ticket, "triage.classified").sole.trace_id).to eq(trace)
  end

  it "RN-28: categoria somente humana vai à fila de escalas sem turno nem chamada ao broker" do
    stub_broker
    perform_enqueued_jobs { post_chat("preciso trocar o e-mail do cadastro") }

    ticket = Ticket.sole
    expect(ticket).to have_attributes(state: "aguardando_humano", queue_id: config[:escalation].id, assignee_id: nil,
                                      category: "cadastro", dispatch_due_at: nil, first_pending_seq: nil)
    travel 5.seconds
    expect(scheduler_tick).to be_empty
    travel 60.seconds
    expect(Deadlines::CycleTimeout.call(now: Time.current, limit: 10)).to be_empty
    expect(AiTurn.count).to eq(0)
    expect(broker_requests).to be_empty
  end

  it "RN-34 (ordem): pedido de humano na primeira mensagem: sem triagem, o caso termina na fila de escalas" do
    stub_broker
    stub_channels({ status: 200, message_id: "chat_out_notice" })
    perform_enqueued_jobs { post_chat("quero falar com um atendente") }

    ticket = Ticket.sole
    # RN-11: classificado (outros) mesmo sem roteamento; a fila é a do handoff.
    expect(ticket).to have_attributes(state: "aguardando_humano", queue_id: config[:escalation].id, category: "outros")
    expect(audits(ticket, "triage.skipped").sole.data["reason"]).to be_in(%w[handoff_pedido fora_de_novo])
    expect(audits(ticket, "routing.decided")).to be_empty
    expect(audits(ticket, "ticket.escalated").sole.data).to include("reason" => "pedido_do_cliente")
    travel 5.seconds
    scheduler_tick
    expect(broker_requests).to be_empty
  end

  it "falha: Redis fora na ingestão não importa; o Open tria no fim da janela e o aviso reoferecido só conclui" do
    stub_broker
    allow(OutboxJob).to receive(:perform_later).and_raise(RedisClient::CannotConnectError)
    post_chat("meu repasse não caiu")
    expect(response).to have_http_status(:accepted)
    ticket = Ticket.sole
    expect(ticket.state).to eq("novo")
    allow(OutboxJob).to receive(:perform_later).and_call_original

    travel 2.seconds
    scheduler_tick

    expect(ticket.reload).to have_attributes(state: "com_ia", category: "repasses")
    expect(AiTurn.sole.status).to eq("eligible")
    perform_enqueued_jobs { OutboxJob.perform_later(OutboxEvent.find_by!(event_type: "message.received").id) }
    expect(audits(ticket, "routing.decided").count).to eq(1)
    expect(audits(ticket, "triage.skipped").sole.data["reason"]).to eq("ja_triado")
  end
end
