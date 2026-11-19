require "net/http"

# Webhook plataforma → broker (07, seção 5.2; ADR-007). Assina o corpo bruto com HMAC (RNF-23) e
# manda event_id e traceparent nos cabeçalhos (RF-56). Não decide nada: só devolve a resposta.
module Outbox
  class BrokerClient
    Response = Data.define(:status, :body)
    Unreachable = Class.new(StandardError)

    DEV_SECRET = "dev-secret-broker".freeze # o mesmo do broker fora de produção
    OPEN_TIMEOUT = 2
    # O broker espera até KAFKA_MESSAGE_TIMEOUT_MS (5 s) pela confirmação do Kafka.
    READ_TIMEOUT = 10
    NETWORK_ERRORS = [ SystemCallError, Timeout::Error, SocketError, IOError, OpenSSL::SSL::SSLError,
                       Net::HTTPBadResponse ].freeze

    def self.url = ENV.fetch("BROKER_URL", "http://localhost:4100/webhooks")

    def self.secret
      Rails.env.production? ? ENV.fetch("BROKER_WEBHOOK_SECRET") : ENV.fetch("BROKER_WEBHOOK_SECRET", DEV_SECRET)
    end

    def deliver(body:, event_id:, traceparent:)
      uri = URI(self.class.url)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "X-Helpdesk-Event-Id" => event_id,
                                         "traceparent" => traceparent,
                                         HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(body, secret: self.class.secret))
      request.body = body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT,
                                                     read_timeout: READ_TIMEOUT) { _1.request(request) }
      Response.new(status: response.code.to_i, body: parse(response.body))
    rescue *NETWORK_ERRORS => e
      raise Unreachable, "#{e.class}: #{e.message}"
    end

    private

    def parse(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
