require "rails_helper"

RSpec.describe "ROADMAP 02: mensagem do simulador visível no ticket" do
  before { create(:provider_account, brand: create(:brand, :infinitepay), slug: "infinitepay-chat-mock") }

  def send_chat(message_id: "chat_msg_1")
    raw = { message_id:, account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021",
            text: "meu repasse não caiu", sent_at: "2026-11-18T21:00:00Z" }.to_json
    secret = ProviderAccount.find!(channel: "chat", slug: "infinitepay-chat-mock").secret
    post "/webhooks/chat/infinitepay-chat-mock", params: raw,
                                                 headers: { "CONTENT_TYPE" => "application/json",
                                                            HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret:) }
    response.parsed_body
  end

  it "a conversa mostra a mensagem gravada como confirmada, com origem do sistema" do
    ticket_id = send_chat["ticket_id"]

    get conversation_path(ticket_id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("meu repasse não caiu", "Confirmada", "Registro do sistema")
    expect(response.body).not_to include("Exemplo sintético")
  end

  it "reenviar o mesmo ID externo mantém uma única mensagem no ticket" do
    ticket_id = send_chat["ticket_id"]
    send_chat

    get conversation_path(ticket_id)

    expect(response.body.scan(%(class="message__body")).size).to eq(1)
  end

  it "a lista explica que os registros do sistema vêm antes dos exemplos sintéticos" do
    get conversations_path

    expect(response.body).to include("Registro do sistema", "Exemplo sintético")
    expect(response.body).not_to include("chegam no bloco 02")
  end

  it "a linha do tempo mostra recebimento e gravação da mensagem" do
    ticket_id = send_chat["ticket_id"]

    get timeline_path(ticket_id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Recebimento", "Gravação", "Registro do sistema")
  end
end
