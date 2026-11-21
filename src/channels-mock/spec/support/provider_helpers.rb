# Monta o envio que a plataforma faz ao provedor do chat (interface do bloco 05, seção 2).
module ProviderHelpers
  ACCOUNT = "infinitepay-chat-mock".freeze

  def send_body(text: "Vamos verificar o seu repasse.", reply_to: "chat_msg_cliente1", customer_ref: "cus_ref_000021")
    { "customer_ref" => customer_ref, "text" => text, "reply_to" => reply_to }.compact
  end

  def provider_headers(body, key: "dlv-1", conversation: "tkt_41", seq: 2, secret: nil, account: ACCOUNT)
    secret ||= ChannelsMock::PlatformClient.secret_for(account)
    {
      "CONTENT_TYPE" => "application/json",
      "HTTP_IDEMPOTENCY_KEY" => key,
      "HTTP_X_CONVERSATION_ID" => conversation,
      "HTTP_X_CONVERSATION_SEQ" => seq&.to_s,
      "HTTP_TRACEPARENT" => "00-#{'a' * 32}-#{'b' * 16}-01",
      "HTTP_X_HELPDESK_SIGNATURE" => HelpdeskContracts::Signature.header(body, secret:, at: ChannelsMock::Clock.now)
    }.compact
  end

  def provider_send(payload = send_body, account: ACCOUNT, raw: nil, **headers)
    body = raw || JSON.generate(payload)
    post "/provider/chat/#{account}/messages", body, provider_headers(body, account:, **headers)
    last_response
  end

  def json = JSON.parse(last_response.body)
end
