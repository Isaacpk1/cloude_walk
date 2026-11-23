require "rails_helper"

# Bloco 14, "pronto quando" (ROADMAP): o analista recebe o caso, responde e resolve no navegador; uma conta de outra
# marca não abre o detalhe nem recebe seus eventos (RF-45 a RF-48, RF-55, RF-59, RNF-24). Tudo real: ingestão, triagem,
# distribuição pelo scheduler, login, formulários, outbox e envio ao canal simulado.
RSpec.describe "Bloco 14: pronto quando", :anonymous do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:config) { triage_setup(infinitepay, ai_first: false) }
  let!(:jim_config) { distribution_setup(jim) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let!(:ana) { analyst_in(config[:team], name: "Ana Souza", email: "ana@ip.test") }
  let!(:joe) { analyst_in(jim_config[:team], name: "Joe", email: "joe@jim.test") }
  let(:t0) { Time.utc(2026, 11, 24, 13, 0, 0) }
  def doc = Nokogiri::HTML(response.body)

  around { |example| travel_to(t0) { example.run } }

  before do
    stub_broker
    stub_channels(*Array.new(4) { { status: 200, message_id: "chat_out_#{SecureRandom.hex(3)}" } })
    allow(DatabaseClock).to receive(:now) { Time.current }
  end

  def new_case
    ticket = customer_message("preciso falar sobre meu repasse").ticket
    run_triage(ticket)
    perform_enqueued_jobs { Deadlines::Loop.new.tick }
    ticket.reload
  end

  # O worker entrega o que está aberto no outbox: aqui, o aviso de transferência da triagem.
  def drain_deliveries
    travel 1.minute
    OutboxEvent.where(event_type: "delivery.requested", completed_at: nil).order(:id).each { OutboxJob.perform_now(_1.id) }
  end

  it "o analista recebe o caso, responde, anota e resolve; o cliente recebe a resposta e a vaga volta" do
    ticket = new_case
    expect(ticket).to have_attributes(state: "com_analista", assignee_id: ana.id)
    drain_deliveries # o aviso de transferência sai antes das respostas do analista (envio ordenado, RN-38)

    sign_in(ana)
    get human_queue_path
    expect(doc.at_css("#queue-ticket-#{ticket.id} .human-queue__assignee").text).to include("Ana Souza")

    get conversation_path(ticket.id)
    expect(response).to have_http_status(:ok)
    expect(doc.css("form.analyst-reply")).not_to be_empty

    perform_enqueued_jobs { post conversation_reply_path(ticket.id), params: { text: "Oi! Já estou olhando o seu repasse." } }
    post conversation_note_path(ticket.id), params: { text: "Repasse de 28/11, conferir" }
    reply = Message.find_by!(ticket_id: ticket.id, author_type: "analyst", internal: false)
    expect(Delivery.find_by!(message_id: reply.id)).to have_attributes(kind: "analyst", status: "delivered")
    expect(Delivery.where(message_id: Message.where(internal: true).select(:id))).to be_empty

    perform_enqueued_jobs { post conversation_resolution_path(ticket.id), params: { reason: "duvida_respondida", text: "Qualquer coisa, estamos aqui." } }

    expect(ticket.reload.state).to eq("resolvido")
    expect(ana.reload.active_count).to eq(0)
    expect(AuditEvent.where(ticket_id: ticket.id).pluck(:event_type))
      .to include("ticket.assigned", "analyst.replied", "analyst.noted", "ticket.resolved")
    get timeline_path(ticket.id)
    expect(response).to have_http_status(:ok) # RF-55: a auditoria do caso fica consultável
  end

  it "RNF-24: a conta da JIM não abre o detalhe, não vê o caso na fila e a página não traz o stream dele" do
    ticket = new_case
    sign_in(joe)

    get conversation_path(ticket.id)
    expect(response).to have_http_status(:not_found)
    get timeline_path(ticket.id)
    expect(response).to have_http_status(:not_found)

    get human_queue_path
    expect(response.body).not_to include("queue-ticket-#{ticket.id}")
    streams = doc.css("turbo-cable-stream-source").map { _1["signed-stream-name"] }
    own = Turbo::StreamsChannel.signed_stream_name([ HumanQueue::STREAM, infinitepay ])
    expect(streams).not_to include(own)
  end
end
