require "json"
require "helpdesk_contracts"
require_relative "chat"
require_relative "../clock"
require_relative "../faults"
require_relative "../chat_deliveries"
require_relative "../platform_client"
require_relative "../status_callbacks"

module ChannelsMock
  module Providers
    # API de envio do chat do app: POST /provider/chat/:conta/messages (07, seção 5.0; interface do bloco 05,
    # seção 2). Faz o papel do app da CloudWalk recebendo a resposta que a plataforma manda ao cliente.
    #
    # Ordem das verificações: conta → falha 503 simulada → assinatura (401) → cabeçalhos (400) →
    # contrato chat_send (422) → idempotência, ordem e efeito, juntos sob o lock (ChatDeliveries).
    module ChatApi
      Reply = Data.define(:status, :body, :headers)
      TRACEPARENT = /\A00-(?<trace>\h{32})-\h{16}-\h{2}\z/

      module_function

      def call(account:, raw_body:, headers:)
        return error(404, "conta_desconhecida") unless Chat::ACCOUNTS.include?(account)
        return error(503, "provedor_indisponivel") if Faults.take(:unavailable)

        verify_signature!(account, raw_body, headers[HelpdeskContracts::Signature::HEADER])
        key, conversation_id, seq = conversation_headers(headers)
        return key if key.is_a?(Reply)

        payload = parse_contract(raw_body)
        return payload if payload.is_a?(Reply)

        result = ChatDeliveries.accept(account:, key:, conversation_id:, seq:, payload:, body: raw_body,
                                       trace_id: trace_id(headers["traceparent"]))
        log(result, account:, key:, conversation_id:, seq:)
        respond(result, account)
      rescue HelpdeskContracts::Signature::Invalid => e
        error(401, "assinatura_invalida", "reason" => e.reason.to_s)
      end

      def verify_signature!(account, raw_body, header)
        HelpdeskContracts::Signature.verify!(raw_body, header, secret: PlatformClient.secret_for(account), now: Clock.now)
      end

      def conversation_headers(headers)
        key = headers["Idempotency-Key"].to_s.strip
        return error(400, "idempotency_key_ausente") if key.empty? || key.size > 255

        conversation_id = headers["X-Conversation-Id"].to_s.strip
        return error(400, "conversa_ausente") if conversation_id.empty? || conversation_id.size > 255

        seq = headers["X-Conversation-Seq"].to_s
        return error(400, "seq_invalida") unless seq.match?(/\A[1-9]\d{0,17}\z/)

        [ key, conversation_id, Integer(seq, 10) ]
      end

      def parse_contract(raw_body)
        HelpdeskContracts.validate!(:chat_send, JSON.parse(raw_body))
      rescue JSON::ParserError
        error(422, "contrato_invalido", "details" => [ "corpo não é JSON" ])
      rescue HelpdeskContracts::InvalidPayload => e
        error(422, "contrato_invalido", "details" => e.violations.map(&:to_s))
      end

      def respond(result, account)
        record = result.record
        case result.outcome
        when :accepted, :ack_lost
          StatusCallbacks.enqueue(account:, message_id: record.message_id, status: "delivered")
          result.outcome == :accepted ? Reply.new(200, record.response, {}) : error(504, "confirmacao_perdida")
        when :replayed then Reply.new(200, record.response, { "Idempotent-Replayed" => "true" })
        when :stale then error(409, "seq_anterior", "last_seq" => result.last_seq)
        when :seq_taken then error(409, "seq_repetida", "last_seq" => result.last_seq)
        when :key_reused then error(422, "idempotency_key_reutilizada")
        when :rejected then error(422, "recusada_pelo_provedor")
        end
      end

      def trace_id(traceparent) = TRACEPARENT.match(traceparent.to_s)&.[](:trace)

      def error(status, code, extra = {}) = Reply.new(status, { "error" => code }.merge(extra), {})

      # Log em JSON com trace_id, sem o texto da mensagem (invariante 13, RN-51).
      def log(result, **fields)
        return if ENV["RACK_ENV"] == "test"

        $stdout.puts JSON.generate({ "event" => "chat_send.#{result.outcome}", "message_id" => result.record&.message_id,
                                     "trace_id" => result.record&.trace_id }.merge(fields.transform_keys(&:to_s)))
      end
    end
  end
end
