# Saídas para o provedor do chat (bloco 05; 07, seção 3.2). Grava a saída no formato combinado com o
# AgentActions::Apply (mensagem outbound, deliveries pending, outbox "delivery.requested" e auditoria
# "delivery.requested"), para testar o envio sem depender da aplicação da ação. O provedor é outro
# serviço (channels-mock): a chamada HTTP é simulada com WebMock, conferindo a assinatura e o contrato.
module DeliveryHelpers
  CHANNELS_URL = "http://channels.test:4000".freeze
  CHANNELS_ENDPOINT = %r{\Ahttp://channels\.test:4000/provider/chat/[a-z0-9-]+/messages\z}

  # Mensagem do cliente pela ingestão real, com o webhook cru do chat (de onde sai o customer_ref).
  def customer_message(text = "meu repasse não caiu", brand: "infinitepay", external_id: "chat_msg_#{SecureRandom.hex(4)}",
                       customer_ref: "cus_ref_000021", trace_id: SecureRandom.hex(16))
    raw = { "message_id" => external_id, "account_id" => "acc_#{brand}_000021", "customer_ref" => customer_ref,
            "text" => text, "sent_at" => Time.current.utc.iso8601(3) }
    Ingestion::Receive.call(normalized_message(text:, brand:, external_id:, trace_id:), provider_payload: raw).message
  end

  # A saída como o AgentActions::Apply grava (interface combinada do bloco 05, item 1).
  def requested_delivery(ticket, text: "Seu repasse cai hoje até as 18h.", context_until_seq: nil, kind: "reply",
                         trace_id: SecureRandom.hex(16), audit: true)
    ActiveRecord::Base.transaction do
      ticket = Ticket.lock.find(ticket.id)
      last_in = ticket.messages.where(direction: "inbound").reorder(:seq).last
      seq = ticket.messages.maximum(:seq).to_i + 1
      message = ticket.messages.create!(brand_id: ticket.brand_id, provider_account: last_in.provider_account,
                                        channel: last_in.channel, direction: "outbound", author_type: "bot", body: text,
                                        seq:, trace_id:, received_at: Time.current)
      delivery = Delivery.create!(brand_id: ticket.brand_id, ticket:, message:, seq:, channel: message.channel,
                                  provider_account: message.provider_account, kind:, status: "pending",
                                  ai_assignment_version: ticket.assignment_version, trace_id:).reload
      OutboxEvent.create!(brand_id: ticket.brand_id, ticket:, event_type: Deliveries::Send::EVENT_TYPE,
                          dedup_key: "delivery:#{delivery.delivery_id}", trace_id:, next_attempt_at: Time.current,
                          payload: { delivery_id: delivery.delivery_id, ticket_id: ticket.id, seq: })
      if audit
        AuditEvent.create!(brand_id: ticket.brand_id, ticket:, actor_type: "system", event_type: "delivery.requested", trace_id:,
                           data: { delivery_id: delivery.delivery_id, message_id: message.id, seq:, kind:, turn: 1,
                                   context_until_seq: context_until_seq || last_in.seq })
      end
      delivery
    end
  end

  def delivery_item(delivery) = OutboxEvent.find_by!(dedup_key: "delivery:#{delivery.delivery_id}")

  # Respostas como as do channels-mock (interface combinada, item 2). `{ timeout: true }` simula o
  # tempo esgotado. Cada requisição guarda quantas transações havia abertas na conexão, além da do
  # próprio teste, no momento da chamada (invariante 2).
  def stub_channels(*responses)
    responses = [ { status: 200 } ] if responses.empty?
    @channel_requests = []
    @transactions_during_http = []
    baseline = ActiveRecord::Base.connection.open_transactions
    stub = stub_request(:post, CHANNELS_ENDPOINT).with do |request|
      @channel_requests << request
      @transactions_during_http << (ActiveRecord::Base.connection.open_transactions - baseline)
      true
    end
    responses.each_with_index do |response, i|
      stub = stub.then unless i.zero?
      stub = response[:timeout] ? stub.to_timeout : stub.to_return(channel_response(response))
    end
    stub
  end

  def channel_requests = @channel_requests || []
  def transactions_during_http = @transactions_during_http || []

  def channel_response(response)
    return response if response.key?(:body)

    response = response.dup
    replayed = response.delete(:replayed)
    body = case response[:status]
    when 200 then { message_id: response.delete(:message_id) || "chat_out_000456", status: "accepted" }
    when 401 then { error: "assinatura_invalida" }
    when 409 then { error: "seq_anterior", last_seq: 7 }
    when 422 then { error: "contrato_invalido" }
    when 503 then { error: "falha_simulada" }
    else {}
    end
    headers = { "Content-Type" => "application/json" }
    headers["Idempotent-Replayed"] = "true" if replayed
    response.merge(body: JSON.generate(body), headers:)
  end

  def verify_channel_request!(request, secret:)
    HelpdeskContracts::Signature.verify!(request.body, request.headers["X-Helpdesk-Signature"], secret:)
    HelpdeskContracts.validate!(:chat_send, request.body)
  end
end

RSpec.configure do |config|
  config.include DeliveryHelpers
  config.before do
    allow(Deliveries::ChatClient).to receive(:base_url).and_return(DeliveryHelpers::CHANNELS_URL)
  end
end
