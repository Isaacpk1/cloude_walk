require "rails_helper"

RSpec.describe "Callback de status do chat (POST /webhooks/chat/:provider_account/status)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let!(:ip_chat) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let!(:jim_chat) { create(:provider_account, brand: jim, slug: "jim-chat-mock") }
  let(:start) { Time.zone.parse("2026-11-20T13:40:00Z") }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:delivery) { delivered(customer_message.ticket, "chat_out_000456") }

  around { |example| travel_to(start) { example.run } }

  def delivered(ticket, message_id)
    requested_delivery(ticket).tap do |d|
      d.update_columns(status: "delivered", provider_message_id: message_id, delivered_at: start, attempts: 1)
    end
  end

  def body(status: "delivered", message_id: "chat_out_000456", timestamp: "2026-11-20T13:40:04.000Z")
    { message_id:, status:, timestamp: }
  end

  def post_status(payload = body, account: "infinitepay-chat-mock", secret: nil)
    raw = payload.is_a?(String) ? payload : payload.to_json
    secret ||= ProviderAccount.find_by(slug: account)&.secret || "segredo-de-conta-inexistente"
    signature = { HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret:) }
    post "/webhooks/chat/#{account}/status", params: raw, headers: headers.merge(signature)
  end

  def audits(type) = AuditEvent.where(event_type: type).order(:id)

  describe "07, seção 5.0: status normalizado na entrega pela provider_message_id" do
    %w[sent delivered read].each do |status|
      it "#{status}: 202 e só registra delivery.status_received, sem mudar a entrega" do
        delivery

        post_status(body(status:))

        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body).to include("status" => "accepted")
        expect(delivery.reload.status).to eq("delivered")
        expect(audits("delivery.status_received").sole).to have_attributes(brand_id: infinitepay.id, actor_type: "system",
                                                                           trace_id: delivery.trace_id)
        expect(audits("delivery.status_received").sole.data).to eq(
          "delivery_id" => delivery.delivery_id, "provider_message_id" => "chat_out_000456", "status" => status,
          "provider_timestamp" => "2026-11-20T13:40:04.000Z"
        )
        expect(audits("delivery.failed")).to be_empty
      end
    end

    it "failed: a entrega vira failed e audita delivery.failed com reason provider_failed" do
      delivery

      post_status(body(status: "failed"))

      expect(response).to have_http_status(:accepted)
      expect(delivery.reload).to have_attributes(status: "failed", provider_message_id: "chat_out_000456", delivered_at: nil)
      expect(audits("delivery.failed").sole.data).to include("delivery_id" => delivery.delivery_id, "reason" => "provider_failed",
                                                             "http_status" => nil, "attempt" => 1,
                                                             "provider_timestamp" => "2026-11-20T13:40:04.000Z")
    end

    it "failed depois de a entrega já estar encerrada como failed não audita outra falha" do
      delivery.update_columns(status: "failed", delivered_at: nil)

      post_status(body(status: "failed"))

      expect(response).to have_http_status(:accepted)
      expect(audits("delivery.failed")).to be_empty
      expect(audits("delivery.status_received").count).to eq(1)
    end
  end

  describe "RN-47, RNF-15: callback repetido" do
    it "o mesmo callback duas vezes não duplica efeito nem auditoria" do
      delivery

      2.times { post_status(body(status: "failed")) }

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to include("status" => "duplicate")
      expect(audits("delivery.failed").count).to eq(1)
      expect(audits("delivery.status_received").count).to eq(1)
    end

    it "status diferentes da mesma mensagem são registrados cada um" do
      delivery

      post_status(body(status: "delivered"))
      post_status(body(status: "read", timestamp: "2026-11-20T13:41:00.000Z"))

      expect(audits("delivery.status_received").map { _1.data["status"] }).to eq(%w[delivered read])
    end
  end

  describe "message_id desconhecido" do
    it "responde 202 sem efeito" do
      delivery

      post_status(body(message_id: "chat_out_999999"))

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to include("status" => "unknown")
      expect(AuditEvent.where("event_type LIKE 'delivery.status%' OR event_type = 'delivery.failed'")).to be_empty
      expect(ProcessedEvent.count).to eq(0)
    end
  end

  describe "invariante 6: marca errada" do
    it "a conta de outra marca não alcança a entrega com o mesmo message_id" do
      delivery

      post_status(body(status: "failed"), account: "jim-chat-mock")

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to include("status" => "unknown")
      expect(delivery.reload.status).to eq("delivered")
      expect(audits("delivery.failed")).to be_empty
    end

    it "cada marca atualiza só a sua entrega, mesmo com o mesmo message_id do provedor" do
      delivery
      jim_delivery = delivered(customer_message(brand: "jim").ticket, "chat_out_000456")

      post_status(body(status: "failed"), account: "jim-chat-mock")

      expect(jim_delivery.reload.status).to eq("failed")
      expect(delivery.reload.status).to eq("delivered")
      expect(audits("delivery.failed").sole.brand_id).to eq(jim.id)
    end
  end

  describe "RNF-23, ADR-019: autenticação antes de ler o corpo" do
    it "assinatura com o segredo errado: 401 sem efeito" do
      delivery

      post_status(body(status: "failed"), secret: "outro-segredo")

      expect(response).to have_http_status(:unauthorized)
      expect(delivery.reload.status).to eq("delivered")
      expect(AuditEvent.where(event_type: "delivery.failed")).to be_empty
    end

    it "assinatura de outra conta: 401" do
      post_status(body, secret: jim_chat.secret)

      expect(response).to have_http_status(:unauthorized)
    end

    it "corpo inválido com assinatura errada é 401, não 422 (o corpo nem é lido)" do
      post_status("{lixo", secret: "outro-segredo")

      expect(response).to have_http_status(:unauthorized)
    end

    it "conta inexistente: 404" do
      post_status(body, account: "conta-que-nao-existe")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "invariante 10: contrato chat_status" do
    [ "{lixo", { message_id: "x", status: "entregue", timestamp: "2026-11-20T13:40:04.000Z" }.to_json,
      { message_id: "x", status: "read" }.to_json ].each do |raw|
      it "corpo fora do contrato (#{raw.first(30)}): 422 sem efeito" do
        delivery

        post_status(raw)

        expect(response).to have_http_status(:unprocessable_content)
        expect(audits("delivery.status_received")).to be_empty
      end
    end
  end
end
