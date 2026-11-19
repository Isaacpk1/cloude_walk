require "rails_helper"

RSpec.describe "Webhook de entrada dos canais (POST /webhooks/:channel/:provider_account)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let!(:ip_chat) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let!(:jim_chat) { create(:provider_account, brand: jim, slug: "jim-chat-mock") }
  let!(:ip_whatsapp) { create(:provider_account, brand: infinitepay, channel: "whatsapp", slug: "infinitepay-whatsapp-mock") }
  let(:body) do
    { message_id: "chat_msg_000123", account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021",
      text: "meu repasse não caiu", sent_at: "2026-11-17T13:40:00.000Z" }
  end
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }

  # Assina como o provedor: com o segredo da conta da URL (ADR-019).
  def post_chat(payload = body, account: "infinitepay-chat-mock", extra_headers: {}, secret: nil, signed_at: Time.current)
    raw = payload.is_a?(String) ? payload : payload.to_json
    secret ||= ProviderAccount.find_by(slug: account)&.secret || "segredo-de-conta-inexistente"
    signature = { HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret:, at: signed_at) }
    post "/webhooks/chat/#{account}", params: raw, headers: headers.merge(signature).merge(extra_headers)
  end

  describe "RF-01 / RNF-14: mensagem nova" do
    it "responde 202 com a mensagem já gravada" do
      post_chat

      expect(response).to have_http_status(:accepted)
      message = Message.sole
      expect(response.parsed_body).to include("status" => "accepted", "message_id" => message.id,
                                              "ticket_id" => message.ticket_id, "seq" => 1, "trace_id" => message.trace_id)
      expect(message).to have_attributes(body: "meu repasse não caiu", external_id: "chat_msg_000123")
      expect(message.provider_payload).to eq(body.stringify_keys)
    end

    it "RF-56: usa o trace-id do cabeçalho traceparent" do
      post_chat(extra_headers: { "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" })

      expect(Message.sole.trace_id).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
      expect(response.headers["X-Trace-Id"]).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
    end

    it "RF-56: gera um trace-id quando o traceparent é inválido" do
      post_chat(extra_headers: { "traceparent" => "lixo" })

      expect(Message.sole.trace_id).to match(/\A\h{32}\z/)
    end

    it "não depende de navegador moderno nem de token CSRF (o provedor não é um navegador)" do
      post_chat(extra_headers: { "HTTP_USER_AGENT" => "provedor/1.0" })

      expect(response).to have_http_status(:accepted)
    end
  end

  describe "RNF-15: o provedor reentrega o mesmo webhook (repetição)" do
    it "responde 200 e preserva uma única mensagem" do
      post_chat
      first_id = response.parsed_body["message_id"]

      post_chat

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("status" => "duplicate", "message_id" => first_id)
      expect(Message.count).to eq(1)
    end
  end

  describe "RN-44: payload fora do contrato" do
    it "responde 422 com a violação e não grava nada" do
      post_chat(body.except(:text))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["violations"]).to include(include("pointer" => "/text", "type" => "required"))
      expect(Message.count).to eq(0)
    end

    it "responde 422 para corpo que não é JSON" do
      post_chat("{")

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "07, seção 5.0: conta e canal vêm da URL" do
    it "responde 404 para conta desconhecida" do
      post_chat(account: "nao-existe")

      expect(response).to have_http_status(:not_found)
      expect(Message.count).to eq(0)
    end

    it "responde 404 para conta desativada" do
      ip_chat.update!(active: false)

      post_chat

      expect(response).to have_http_status(:not_found)
    end

    it "responde 404 para conta de outro canal (marca e canal errados)" do
      post "/webhooks/chat/infinitepay-whatsapp-mock", params: body.to_json, headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "a marca sai da conta, não do corpo" do
      post_chat(body.merge(brand: "infinitepay"), account: "jim-chat-mock")

      expect(Message.sole.brand.slug).to eq("jim")
    end
  end

  describe "RNF-23 / ADR-019: webhook sem a assinatura da conta" do
    it "responde 401 sem assinatura e não grava nada" do
      post_chat(extra_headers: { HelpdeskContracts::Signature::HEADER => "" })

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to include("status" => "unauthorized", "reason" => "ausente")
      expect(Message.count).to eq(0)
    end

    it "responde 401 com o segredo de outra conta (marca errada)" do
      post_chat(secret: jim_chat.secret)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["reason"]).to eq("nao_confere")
    end

    it "responde 401 para assinatura de mais de 5 min atrás (replay)" do
      post_chat(signed_at: 301.seconds.ago)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["reason"]).to eq("fora_da_janela")
    end

    it "responde 401 quando o corpo foi alterado depois de assinado" do
      raw = body.to_json
      signature = HelpdeskContracts::Signature.header(raw, secret: ip_chat.secret)

      post "/webhooks/chat/infinitepay-chat-mock", params: raw.sub("não caiu", "caiu"),
                                                   headers: headers.merge(HelpdeskContracts::Signature::HEADER => signature)

      expect(response).to have_http_status(:unauthorized)
    end

    it "confere a assinatura antes do contrato: corpo inválido sem assinatura é 401, não 422" do
      post_chat("{", extra_headers: { HelpdeskContracts::Signature::HEADER => "t=1,v1=#{'0' * 64}" })

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "RNF-14 / RNF-19: Postgres indisponível" do
    it "responde 503 e não confirma" do
      allow(Ingestion::Receive).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

      post_chat

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to be_present
    end
  end
end
