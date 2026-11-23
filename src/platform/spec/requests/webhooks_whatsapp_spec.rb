require "rails_helper"

# Bloco 15 (RF-02, RF-05, RF-07, ADR-018, ADR-019): webhook da Cloud API do WhatsApp, no formato da Meta.
RSpec.describe "Webhook de entrada do WhatsApp (POST /webhooks/whatsapp/:provider_account)", :anonymous do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:ip_wa) { create(:provider_account, brand: infinitepay, channel: "whatsapp", slug: "infinitepay-whatsapp-mock", phone_number_id: "106540352242922") }
  let!(:jim_wa) { create(:provider_account, brand: jim, channel: "whatsapp", slug: "jim-whatsapp-mock", phone_number_id: "106540352242999") }

  def message(text: "Meu repasse de ontem não caiu", id: "wamid.AAA", from: "5511900000021", type: "text", timestamp: "1763386800")
    base = { "from" => from, "id" => id, "timestamp" => timestamp, "type" => type }
    type == "text" ? base.merge("text" => { "body" => text }) : base.merge(type => { "id" => "1479537139650973", "mime_type" => "image/jpeg" })
  end

  def webhook(*messages, phone_number_id: "106540352242922", statuses: nil)
    value = { "messaging_product" => "whatsapp", "metadata" => { "display_phone_number" => "551130000001", "phone_number_id" => phone_number_id } }
    value["contacts"] = [ { "wa_id" => "5511900000021" } ]
    value["messages"] = messages if messages.any?
    value["statuses"] = statuses if statuses
    { "object" => "whatsapp_business_account", "entry" => [ { "id" => "102290129340398", "changes" => [ { "field" => "messages", "value" => value } ] } ] }
  end

  def post_wa(payload, account: "infinitepay-whatsapp-mock", secret: nil)
    raw = payload.is_a?(String) ? payload : payload.to_json
    secret ||= ProviderAccount.find_by(slug: account)&.secret || "x"
    post "/webhooks/whatsapp/#{account}", params: raw,
                                          headers: { "CONTENT_TYPE" => "application/json",
                                                     HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret:) }
  end

  it "RF-02, RF-05: texto vira mensagem do canal whatsapp, com o webhook cru guardado" do
    post_wa(webhook(message))

    expect(response).to have_http_status(:accepted)
    saved = Message.sole
    expect(saved).to have_attributes(body: "Meu repasse de ontem não caiu", channel: "whatsapp", external_id: "wamid.AAA",
                                     provider_account: "infinitepay-whatsapp-mock", direction: "inbound", author_type: "customer")
    expect(saved.provider_payload).to include("from" => "5511900000021", "id" => "wamid.AAA")
    expect(saved.ticket).to have_attributes(channel: "whatsapp", brand_id: infinitepay.id)
    expect(response.parsed_body).to include("status" => "accepted", "messages" => [ include("message_id" => saved.id, "seq" => 1) ])
  end

  it "RF-07: o telefone identifica o cliente na marca; a mesma pessoa em outra marca é outro cliente" do
    post_wa(webhook(message(id: "wamid.1")))
    post_wa(webhook(message(id: "wamid.2", text: "oi de novo")))
    post_wa(webhook(message(id: "wamid.3"), phone_number_id: "106540352242999"), account: "jim-whatsapp-mock")

    expect(Customer.count).to eq(2)
    expect(Ticket.where(brand_id: infinitepay.id).count).to eq(1)
    expect(Message.where(brand_id: infinitepay.id).pluck(:seq)).to eq([ 1, 2 ])
    expect(Ticket.where(brand_id: jim.id).count).to eq(1)
  end

  it "repetição: o mesmo wamid duas vezes não duplica (200 duplicate)" do
    post_wa(webhook(message))
    post_wa(webhook(message))

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["status"]).to eq("duplicate")
    expect(Message.count).to eq(1)
  end

  it "lote com texto e imagem: o texto entra e a imagem é ignorada sem derrubar o lote" do
    post_wa(webhook(message, message(id: "wamid.IMG", type: "image")))

    expect(response).to have_http_status(:accepted)
    expect(Message.pluck(:external_id)).to eq([ "wamid.AAA" ])
    expect(response.parsed_body["unsupported"]).to eq([ { "id" => "wamid.IMG", "type" => "image" } ])
  end

  it "lote de várias mensagens de texto grava todas, em ordem" do
    post_wa(webhook(message(id: "wamid.1", text: "um"), message(id: "wamid.2", text: "dois")))

    expect(Message.order(:seq).pluck(:seq, :body)).to eq([ [ 1, "um" ], [ 2, "dois" ] ])
  end

  it "só status de entrega (sem mensagens): 200 e nada gravado" do
    post_wa(webhook(statuses: [ { "id" => "wamid.OUT", "status" => "delivered", "timestamp" => "1763386900", "recipient_id" => "5511900000021" } ]))

    expect(response).to have_http_status(:ok)
    expect(Message.count).to eq(0)
  end

  it "ADR-019: sem assinatura válida é 401 e nada é gravado" do
    post_wa(webhook(message), secret: "errado")

    expect(response).to have_http_status(:unauthorized)
    expect(Message.count).to eq(0)
  end

  it "phone_number_id de outra conta é 422 (a URL manda, o corpo tem que bater)" do
    post_wa(webhook(message, phone_number_id: "106540352242999"))

    expect(response).to have_http_status(:unprocessable_content)
    expect(Message.count).to eq(0)
  end

  it "RN-44: corpo fora do contrato é 422" do
    post_wa({ "object" => "whatsapp_business_account" })

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "marca errada: assinar com o segredo de outra marca é 401" do
    post_wa(webhook(message), secret: jim_wa.secret)

    expect(response).to have_http_status(:unauthorized)
  end
end
