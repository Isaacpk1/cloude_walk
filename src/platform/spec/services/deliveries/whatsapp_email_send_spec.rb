require "rails_helper"

# Bloco 15 (RF-06, RNF-15; 07, seção 5.0): a saída para WhatsApp (Cloud API) e e-mail (Gmail) pelo mesmo envio ordenado.
RSpec.describe Deliveries::Send, "RF-06: saída para WhatsApp e e-mail" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-20T13:40:00Z") }
  let(:base) { DeliveryHelpers::CHANNELS_URL }

  around { |example| travel_to(start) { example.run } }

  def send_delivery(delivery) = described_class.call(delivery_item(delivery).id, jitter: -> { 0.0 })
  def audits(type) = AuditEvent.where(event_type: type).order(:id)

  describe "WhatsApp" do
    let!(:account) { create(:provider_account, brand:, channel: "whatsapp", slug: "infinitepay-whatsapp-mock", phone_number_id: "106540352242922") }
    let(:inbound) do
      raw = { "from" => "5511999990001", "id" => "wamid.A1", "timestamp" => start.to_i.to_s, "type" => "text", "text" => { "body" => "meu repasse não caiu" } }
      normalized = ChannelAdapters::Whatsapp.normalized(raw, account:, trace_id: SecureRandom.hex(16), received_at: Time.current)
      Ingestion::Receive.call(normalized, provider_payload: raw).message
    end

    def stub_whatsapp(status: 200, body: { "messaging_product" => "whatsapp", "messages" => [ { "id" => "wamid.OUT1" } ] })
      stub_request(:post, "#{base}/provider/whatsapp/infinitepay-whatsapp-mock/106540352242922/messages")
        .to_return(status:, body: JSON.generate(body), headers: { "Content-Type" => "application/json" })
    end

    it "envia o corpo da Cloud API ao telefone do cliente e guarda o id devolvido" do
      delivery = requested_delivery(inbound.ticket)
      stub = stub_whatsapp

      expect(send_delivery(delivery).status).to eq(:delivered)

      expect(stub.with { |r| JSON.parse(r.body) == { "messaging_product" => "whatsapp", "to" => "5511999990001", "type" => "text",
                                                      "text" => { "body" => "Seu repasse cai hoje até as 18h." } } &&
                              r.headers["Idempotency-Key"] == delivery.delivery_id }).to have_been_requested
      expect(delivery.reload).to have_attributes(status: "delivered", provider_message_id: "wamid.OUT1")
    end

    it "resposta 2xx sem o id é incerta e repete com o mesmo delivery_id" do
      delivery = requested_delivery(inbound.ticket)
      stub_whatsapp(body: {})

      expect(send_delivery(delivery).status).to eq(:retry_scheduled)
      expect(audits("delivery.retry_scheduled").sole.data).to include("outcome" => "incerto")
    end

    it "tempo no limite: 24 h depois da última mensagem do cliente ainda envia; um segundo depois, não" do
      delivery = requested_delivery(inbound.ticket)
      stub = stub_whatsapp

      travel_back
      travel_to(start + 24.hours)
      expect(send_delivery(delivery).status).to eq(:delivered)
      expect(stub).to have_been_requested.once

      late = requested_delivery(inbound.ticket)
      travel_back
      travel_to(start + 24.hours + 1.second)
      expect(send_delivery(late).status).to eq(:failed)
      expect(audits("delivery.failed").last.data).to include("platform_error" => "whatsapp_janela_24h")
      expect(stub).to have_been_requested.once
    end

    it "texto acima de 4096 caracteres não sai" do
      delivery = requested_delivery(inbound.ticket, text: "a" * 4097)
      stub = stub_whatsapp

      expect(send_delivery(delivery).status).to eq(:failed)
      expect(audits("delivery.failed").sole.data).to include("platform_error" => "whatsapp_texto_longo")
      expect(stub).not_to have_been_requested
    end
  end

  describe "e-mail" do
    let!(:account) { create(:provider_account, brand:, channel: "email", slug: "infinitepay-email-mock", email_address: "suporte@infinitepay.example") }
    let(:resource) do
      { "id" => "18c2f0a1", "threadId" => "thr1", "historyId" => "9", "internalDate" => (start.to_i * 1000).to_s,
        "payload" => { "mimeType" => "text/plain", "filename" => "", "body" => { "size" => 1, "data" => Base64.urlsafe_encode64("oi") },
                       "headers" => [ { "name" => "From", "value" => "Loja <loja@example.com>" }, { "name" => "Subject", "value" => "Repasse" },
                                      { "name" => "Message-ID", "value" => "<a1@mail.example.com>" } ] } }
    end
    let(:inbound) do
      normalized = ChannelAdapters::Email.normalized(resource, account:, trace_id: SecureRandom.hex(16), received_at: Time.current)
      Ingestion::Receive.call(normalized, provider_payload: resource).message
    end

    it "responde na mesma thread, com Re:, In-Reply-To e References, e aceita o id do Gmail" do
      delivery = requested_delivery(inbound.ticket)
      stub = stub_request(:post, "#{base}/provider/email/infinitepay-email-mock/gmail/v1/users/suporte@infinitepay.example/messages/send")
             .to_return(status: 200, body: { "id" => "18c2f0ff", "threadId" => "thr1" }.to_json, headers: { "Content-Type" => "application/json" })

      expect(send_delivery(delivery).status).to eq(:delivered)

      expect(stub.with do |r|
        body = JSON.parse(r.body)
        mime = Base64.urlsafe_decode64(body["raw"]).force_encoding("UTF-8")
        body["threadId"] == "thr1" && mime.include?("To: Loja <loja@example.com>") && mime.include?("Subject: Re: Repasse") &&
          mime.include?("In-Reply-To: <a1@mail.example.com>") && mime.include?("References: <a1@mail.example.com>")
      end).to have_been_requested
      expect(delivery.reload.provider_message_id).to eq("18c2f0ff")
    end

    it "400 do provedor é falha definitiva" do
      delivery = requested_delivery(inbound.ticket)
      stub_request(:post, %r{/messages/send}).to_return(status: 400, body: { "error" => "invalid" }.to_json, headers: { "Content-Type" => "application/json" })

      expect(send_delivery(delivery).status).to eq(:failed)
    end
  end
end
