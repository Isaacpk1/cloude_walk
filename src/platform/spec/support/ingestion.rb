# Grava mensagens do cliente pelo caminho real da ingestão (bloco 02), para os testes do bloco 03.
module IngestionHelpers
  def normalized_message(text: "meu repasse não caiu", brand: "infinitepay", identity: "acc_#{brand}_000021",
                         external_id: SecureRandom.uuid, trace_id: SecureRandom.hex(16))
    {
      "schema" => "helpdesk.normalized_message.v1", "channel" => "chat", "brand" => brand,
      "provider_account" => "#{brand}-chat-mock", "external_id" => external_id,
      "sender" => { "channel_identity" => identity }, "content" => { "type" => "text", "text" => text },
      "received_at" => Time.current.utc.iso8601(3), "trace_id" => trace_id
    }
  end

  def ingest(text = "meu repasse não caiu", **)
    Ingestion::Receive.call(normalized_message(text:, **), provider_payload: {})
  end

  def received_item(result)
    OutboxEvent.where(event_type: "message.received", ticket_id: result.ticket.id)
               .find_by!("payload->>'message_id' = ?", result.message.id.to_s)
  end
end

RSpec.configure { |c| c.include IngestionHelpers }
