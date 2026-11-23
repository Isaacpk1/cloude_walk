# Adaptador do e-mail, no formato da API do Gmail (RF-03, RF-05, RF-06; 07, seções 5.0 e 5.1; ADR-018). A notificação push
# traz só `emailAddress` e `historyId`: o adaptador lista o histórico desde o cursor da conta e busca cada mensagem nova.
# `Message-ID` vira o `external_id` (deduplicação) e o endereço do `From`, a identidade do cliente. Anexos viram só
# metadados. Devolve também o recurso cru de cada mensagem, que fica em `messages.provider_payload` e é de onde a
# resposta tira `threadId`, `Message-ID` e assunto.
module ChannelAdapters
  module Email
    Parsed = Data.define(:messages, :raw, :history_id)
    ADDRESS = /<([^<>\s]+@[^<>\s]+)>|\A\s*([^<>\s]+@[^<>\s]+)\s*\z/

    module_function

    def fetch(raw_body, account:, trace_id:, received_at:, client: GmailClient.new(account))
      push = JSON.parse(HelpdeskContracts.validate!(:email_push, raw_body))
      notice = JSON.parse(Base64.decode64(push.dig("message", "data")))
      raise AccountMismatch, "caixa #{notice['emailAddress']} não é da conta #{account.slug}" unless notice["emailAddress"] == account.email_address

      pushed = notice.fetch("historyId").to_i
      start = account.history_id || [ pushed - 1, 0 ].max
      history = JSON.parse(HelpdeskContracts.validate!(:email_history, client.history(start)))
      ids = history.fetch("history", []).flat_map { |h| h.fetch("messagesAdded", []).map { _1.dig("message", "id") } }.uniq
      raws = ids.map { JSON.parse(HelpdeskContracts.validate!(:email_message, client.message(_1))) }
      messages = raws.map { normalized(_1, account:, trace_id:, received_at:) }
      Parsed.new(messages:, raw: messages.zip(raws).to_h { |msg, resource| [ msg["external_id"], resource ] },
                 history_id: [ history["historyId"].to_i, pushed ].max)
    end

    # Corpo do envio (users.messages.send): MIME em base64url e o threadId da conversa (07, seção 5.0).
    def outbound(from:, to:, subject:, text:, thread_id:, in_reply_to:)
      reply_subject = subject.to_s.match?(/\Are:/i) ? subject.to_s : "Re: #{subject}"
      lines = [ "From: #{from}", "To: #{to}", "Subject: #{reply_subject}", ("In-Reply-To: #{in_reply_to}" if in_reply_to),
                ("References: #{in_reply_to}" if in_reply_to), "Content-Type: text/plain; charset=UTF-8", "", text ].compact
      { "raw" => Base64.urlsafe_encode64(lines.join("\r\n"), padding: false), "threadId" => thread_id }
    end

    def normalized(resource, account:, trace_id:, received_at:)
      headers = resource.dig("payload", "headers").to_h { [ _1["name"].downcase, _1["value"] ] }
      sender = headers["from"].to_s[ADDRESS, 1] || headers["from"].to_s[ADDRESS, 2]
      raise InvalidMessage, "mensagem #{resource['id']} sem remetente utilizável" unless sender

      content = { "type" => "text", "text" => body(resource["payload"]), "attachments" => attachments(resource["payload"]) }
      content["subject"] = headers["subject"] if headers["subject"].present?
      content.delete("attachments") if content["attachments"].empty?
      message = {
        "schema" => "helpdesk.normalized_message.v1", "channel" => "email", "brand" => account.brand_slug,
        "provider_account" => account.slug, "external_id" => headers.fetch("message-id"),
        "sender" => { "channel_identity" => sender.downcase }, "content" => content,
        "received_at" => Time.at(resource["internalDate"].to_i / 1000).utc.iso8601(3).then { _1 }, "trace_id" => trace_id
      }
      HelpdeskContracts.validate!(:normalized_message, message)
    rescue KeyError => e
      raise InvalidMessage, "mensagem #{resource['id']} sem #{e.key}"
    end

    def body(payload)
      part = text_part(payload)
      decode(part&.dig("body", "data")).presence || "(sem texto)"
    end

    def text_part(payload)
      return payload if payload["mimeType"] == "text/plain" && payload.dig("body", "data")

      Array(payload["parts"]).filter_map { text_part(_1) }.first
    end

    def attachments(payload)
      Array(payload["parts"]).flat_map do |part|
        own = part["filename"].present? ? [ { "filename" => part["filename"], "content_type" => part["mimeType"], "size_bytes" => part.dig("body", "size").to_i } ] : []
        own + attachments(part)
      end
    end

    def decode(data) = data.to_s.empty? ? "" : Base64.urlsafe_decode64(data.ljust((data.length + 3) / 4 * 4, "=")).force_encoding("UTF-8")
  end
end
