require "net/http"

# Saída para o provedor do chat do app (07, seção 5.0; interface do bloco 05, item 2):
# POST {CHANNELS_URL}/provider/chat/:provider_account/messages. Assina o corpo bruto com o segredo da
# conta (RNF-23, ADR-019) e manda o delivery_id como Idempotency-Key (RNF-15). Não decide nada: só
# devolve a resposta ou Unreachable para timeout e erro de conexão.
module Deliveries
  class ChatClient
    Response = Data.define(:status, :body, :replayed)
    Unreachable = Class.new(StandardError)

    NETWORK_ERRORS = [ SystemCallError, Timeout::Error, SocketError, IOError, OpenSSL::SSL::SSLError,
                       Net::HTTPBadResponse ].freeze

    def self.base_url = ENV.fetch("CHANNELS_URL", "http://localhost:4000")

    def deliver(provider_account:, body:, secret:, headers:)
      uri = URI("#{self.class.base_url.chomp('/')}/provider/chat/#{provider_account}/messages")
      request = Net::HTTP::Post.new(uri, headers.merge("Content-Type" => "application/json",
                                                       HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(body, secret:)))
      request.body = body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: Policy::OPEN_TIMEOUT,
                                                     read_timeout: Policy::READ_TIMEOUT) { _1.request(request) }
      Response.new(status: response.code.to_i, body: parse(response.body), replayed: response["Idempotent-Replayed"] == "true")
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
