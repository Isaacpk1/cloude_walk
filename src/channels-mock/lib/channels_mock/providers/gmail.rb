require "securerandom"
require "base64"
require "json"
require "helpdesk_contracts"
require_relative "../clock"
require_relative "../faults"
require_relative "../platform_client"

module ChannelsMock
  module Providers
    # E-mail no formato da API do Gmail (07, seção 5.0; ADR-018). Guarda a caixa de cada conta em memória: o simulador
    # "recebe" um e-mail (gera o push Pub/Sub para a plataforma) e a plataforma busca o histórico e a mensagem em
    # GET .../users/:caixa/history e .../messages/:id. A resposta chega em POST .../messages/send, idempotente pela chave.
    module Gmail
      ACCOUNTS = { "infinitepay-email-mock" => "suporte@infinitepay.example", "jim-email-mock" => "suporte@jim.example" }.freeze
      Sent = Data.define(:id, :account, :to, :subject, :text, :thread_id, :key, :received_at)

      @lock = Mutex.new
      @mailboxes = Hash.new { |h, k| h[k] = { messages: {}, history: [], counter: 1000 } }
      @sent = []
      @by_key = {}

      module_function

      # Cria a mensagem na caixa e devolve o push (Pub/Sub) que avisa a plataforma.
      def deliver_mail(account:, from:, subject:, text:, message_id: nil, thread_id: nil, attachments: [])
        address = ACCOUNTS.fetch(account)
        @lock.synchronize do
          box = @mailboxes[account]
          box[:counter] += 1
          id = format("%016x", box[:counter] * 7919)
          parts = [ { "partId" => "0", "mimeType" => "text/plain", "filename" => "",
                      "body" => { "size" => text.bytesize, "data" => Base64.urlsafe_encode64(text, padding: false) } } ]
          attachments.each_with_index do |name, i|
            parts << { "partId" => (i + 1).to_s, "mimeType" => "application/octet-stream", "filename" => name,
                       "body" => { "attachmentId" => "att#{i}", "size" => 1024 } }
          end
          headers = [ { "name" => "From", "value" => from }, { "name" => "To", "value" => address }, { "name" => "Subject", "value" => subject },
                      { "name" => "Message-ID", "value" => message_id.to_s.empty? ? "<#{SecureRandom.hex(8)}@mail.simulado>" : message_id } ]
          resource = { "id" => id, "threadId" => thread_id.to_s.empty? ? id : thread_id, "historyId" => box[:counter].to_s,
                       "internalDate" => (Clock.now.to_f * 1000).to_i.to_s, "labelIds" => %w[INBOX UNREAD],
                       "payload" => { "mimeType" => "multipart/mixed", "filename" => "", "headers" => headers, "body" => { "size" => 0 }, "parts" => parts } }
          box[:messages][id] = resource
          box[:history] << { "id" => box[:counter].to_s, "messages" => [ { "id" => id, "threadId" => resource["threadId"] } ],
                             "messagesAdded" => [ { "message" => { "id" => id, "threadId" => resource["threadId"], "labelIds" => %w[INBOX UNREAD] } } ] }
          push(address, box[:counter])
        end
      end

      def push(address, history_id)
        { "message" => { "data" => Base64.strict_encode64(JSON.generate("emailAddress" => address, "historyId" => history_id)),
                         "messageId" => SecureRandom.random_number(10**15).to_s, "publishTime" => Clock.now.utc.iso8601(3) },
          "subscription" => "projects/helpdesk-mock/subscriptions/gmail-#{address[/@(\w+)\./, 1]}" }
      end

      def authorize(account, address, signature, raw_body = "")
        return [ 404, { "error" => "conta_desconhecida" } ] unless ACCOUNTS[account] == address
        return [ 503, { "error" => "provedor_indisponivel" } ] if Faults.take(:unavailable)

        HelpdeskContracts::Signature.verify!(raw_body, signature, secret: PlatformClient.secret_for(account), now: Clock.now)
        nil
      rescue HelpdeskContracts::Signature::Invalid => e
        [ 401, { "error" => "assinatura_invalida", "reason" => e.reason.to_s } ]
      end

      def history(account:, address:, signature:, start:)
        denied = authorize(account, address, signature)
        return denied if denied

        box = @lock.synchronize { @mailboxes[account] }
        start = start.to_i
        list = @lock.synchronize { box[:history].select { _1["id"].to_i > start } }
        [ 200, { "history" => list, "historyId" => box[:counter].to_s }.tap { _1.delete("history") if list.empty? } ]
      end

      def message(account:, address:, signature:, id:)
        denied = authorize(account, address, signature)
        return denied if denied

        resource = @lock.synchronize { @mailboxes[account][:messages][id] }
        resource ? [ 200, resource ] : [ 404, { "error" => "mensagem_inexistente" } ]
      end

      def receive(account:, address:, raw_body:, signature:, key:)
        denied = authorize(account, address, signature, raw_body)
        return denied if denied
        return [ 400, { "error" => "idempotency_key_ausente" } ] if key.to_s.strip.empty?

        body = JSON.parse(raw_body)
        HelpdeskContracts.validate!(:email_send, body)
        reply = @lock.synchronize do
          @by_key[[ account, key ]] ||= begin
            id = format("%016x", SecureRandom.random_number(2**60))
            mime = Base64.urlsafe_decode64(body["raw"].ljust((body["raw"].length + 3) / 4 * 4, "=")).force_encoding("UTF-8")
            head, _, text = mime.partition("\r\n\r\n")
            to = head[/^To: (.*)$/, 1].to_s.strip
            subject = head[/^Subject: (.*)$/, 1].to_s.strip
            @sent.unshift(Sent.new(id:, account:, to:, subject:, text:, thread_id: body["threadId"], key:, received_at: Clock.now))
            { "id" => id, "threadId" => body["threadId"], "labelIds" => %w[SENT] }
          end
        end
        [ 200, reply ]
      rescue JSON::ParserError, ArgumentError, HelpdeskContracts::InvalidPayload => e
        [ 422, { "error" => "contrato_invalido", "details" => e.message } ]
      end

      def sent = @lock.synchronize { @sent.dup }
      def clear = @lock.synchronize { @sent.clear && @by_key.clear && @mailboxes.clear }
    end
  end
end
