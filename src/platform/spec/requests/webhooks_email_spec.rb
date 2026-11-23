require "rails_helper"

# Bloco 15 (RF-03, RF-05, RF-07, ADR-018, ADR-019): e-mail no formato do Gmail. A notificação push (Pub/Sub) só traz a
# caixa e o historyId; a plataforma busca o histórico e as mensagens na API do provedor.
RSpec.describe "Webhook de entrada do e-mail (POST /webhooks/email/:provider_account)", :anonymous do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:account) { create(:provider_account, brand: infinitepay, channel: "email", slug: "infinitepay-email-mock", email_address: "suporte@infinitepay.example") }
  let(:gmail) { "http://channels.test:4000/provider/email/infinitepay-email-mock/gmail/v1/users/suporte@infinitepay.example" }

  before { ENV["CHANNELS_URL"] = "http://channels.test:4000" }
  after { ENV.delete("CHANNELS_URL") }

  def b64url(text) = Base64.urlsafe_encode64(text, padding: false)

  def gmail_message(id: "18c2f0a1", from: "Loja Exemplo <loja.exemplo@example.com>", subject: "Repasse não recebido", body: "Meu repasse não caiu.",
                    message_id: "<a1b2c3@mail.example.com>", attachments: [], history_id: "101")
    parts = [ { "partId" => "0", "mimeType" => "text/plain", "filename" => "", "body" => { "size" => body.bytesize, "data" => b64url(body) } } ]
    attachments.each_with_index do |a, i|
      parts << { "partId" => (i + 1).to_s, "mimeType" => a[:type], "filename" => a[:name], "body" => { "attachmentId" => "att#{i}", "size" => a[:size] } }
    end
    headers = [ { "name" => "From", "value" => from }, { "name" => "To", "value" => "suporte@infinitepay.example" },
                { "name" => "Subject", "value" => subject }, { "name" => "Message-ID", "value" => message_id } ].compact
    { "id" => id, "threadId" => id, "historyId" => history_id, "internalDate" => "1763386800000", "labelIds" => %w[INBOX UNREAD],
      "payload" => { "mimeType" => "multipart/mixed", "filename" => "", "headers" => headers, "body" => { "size" => 0 }, "parts" => parts } }
  end

  def stub_gmail(messages, history_id: "102")
    stub_request(:get, %r{#{Regexp.escape(gmail)}/history}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { "history" => messages.map { |m| { "id" => m["historyId"], "messages" => [ { "id" => m["id"], "threadId" => m["threadId"] } ],
                                                  "messagesAdded" => [ { "message" => { "id" => m["id"], "threadId" => m["threadId"], "labelIds" => %w[INBOX UNREAD] } } ] } },
              "historyId" => history_id }.to_json
    )
    messages.each do |m|
      stub_request(:get, %r{#{Regexp.escape(gmail)}/messages/#{m["id"]}}).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: m.to_json)
    end
  end

  def push(history_id: "102", address: "suporte@infinitepay.example")
    { "message" => { "data" => Base64.strict_encode64({ "emailAddress" => address, "historyId" => history_id.to_s }.to_json),
                     "messageId" => "2070443601311540", "publishTime" => "2026-11-17T13:40:00.000Z" },
      "subscription" => "projects/helpdesk-mock/subscriptions/gmail-ip" }
  end

  def post_push(payload = push, secret: nil, slug: "infinitepay-email-mock")
    raw = payload.to_json
    secret ||= ProviderAccount.find_by(slug:)&.secret || "x"
    post "/webhooks/email/#{slug}", params: raw, headers: { "CONTENT_TYPE" => "application/json",
                                                           HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret:) }
  end

  it "RF-03, RF-05: busca a mensagem nova e grava com assunto e remetente normalizados" do
    stub_gmail([ gmail_message ])

    post_push

    expect(response).to have_http_status(:accepted)
    saved = Message.sole
    expect(saved).to have_attributes(channel: "email", body: "Meu repasse não caiu.", subject: "Repasse não recebido",
                                     external_id: "<a1b2c3@mail.example.com>", provider_account: "infinitepay-email-mock")
    expect(saved.provider_payload).to include("id" => "18c2f0a1", "threadId" => "18c2f0a1")
    expect(CustomerIdentity.find_by!(brand: infinitepay, channel: "email").external_id).to eq("loja.exemplo@example.com")
    expect(account.reload.history_id).to eq(102)
  end

  it "RF-03: anexos viram só metadados" do
    stub_gmail([ gmail_message(attachments: [ { type: "application/pdf", name: "comprovante.pdf", size: 48_211 } ]) ])

    post_push

    expect(Message.sole.attachments).to eq([ { "filename" => "comprovante.pdf", "content_type" => "application/pdf", "size_bytes" => 48_211 } ])
  end

  it "usa o cursor guardado como startHistoryId" do
    account.update!(history_id: 100)
    stub = stub_request(:get, %r{#{Regexp.escape(gmail)}/history\?.*startHistoryId=100}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" }, body: { "historyId" => "102" }.to_json
    )

    post_push

    expect(stub).to have_been_requested
    expect(response).to have_http_status(:ok)
  end

  it "repetição: o mesmo Message-ID não duplica" do
    stub_gmail([ gmail_message ])
    post_push
    post_push

    expect(Message.count).to eq(1)
  end

  it "a mesma pessoa escrevendo de novo no mesmo atendimento anexa a mensagem" do
    stub_gmail([ gmail_message(id: "m1", message_id: "<1@x>"), gmail_message(id: "m2", message_id: "<2@x>", body: "Segue o extrato.", history_id: "102") ])

    post_push

    expect(Message.order(:seq).pluck(:seq, :body)).to eq([ [ 1, "Meu repasse não caiu." ], [ 2, "Segue o extrato." ] ])
    expect(Ticket.count).to eq(1)
  end

  it "ADR-019: assinatura errada é 401 e a API do provedor nem é chamada" do
    post_push(secret: "errado")

    expect(response).to have_http_status(:unauthorized)
    expect(a_request(:get, /channels.test/)).not_to have_been_made
  end

  it "a caixa do push precisa ser a da conta da URL (422)" do
    post_push(push(address: "suporte@jim.example"))

    expect(response).to have_http_status(:unprocessable_content)
    expect(Message.count).to eq(0)
  end

  it "RN-44: push fora do contrato é 422" do
    post_push({ "message" => { "data" => "naoebase64" } })

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "provedor fora do ar ao buscar: 503 com Retry-After, para o push ser reenviado" do
    stub_request(:get, %r{#{Regexp.escape(gmail)}/history}).to_return(status: 503)

    post_push

    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to be_present
    expect(Message.count).to eq(0)
  end

  it "mensagem sem remetente utilizável é recusada em 422, sem gravar nada" do
    stub_gmail([ gmail_message(from: "sem-email") ])

    post_push

    expect(response).to have_http_status(:unprocessable_content)
    expect(Message.count).to eq(0)
  end
end
