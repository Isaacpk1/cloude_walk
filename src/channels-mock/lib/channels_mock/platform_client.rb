require "json"
require "net/http"
require "securerandom"

module ChannelsMock
  # Faz o papel do provedor que chama o webhook da plataforma (07, seção 3.1).
  class PlatformClient
    Response = Data.define(:status, :body, :error, :trace_id)
    TIMEOUT = 5

    # Mesma regra da plataforma (config/provider_accounts.yml): ambiente ou o padrão local.
    def self.secret_for(account, env: ENV)
      env.fetch("PROVIDER_SECRET_#{account.upcase.tr('-', '_')}", "dev-secret-#{account}")
    end

    def initialize(base_url:) = @base_url = base_url

    # tamper_signature: assina com outro segredo, para demonstrar a recusa (RNF-23).
    def deliver(channel:, account:, payload:, tamper_signature: false)
      trace_id = SecureRandom.hex(16)
      uri = URI.join(@base_url, "/webhooks/#{channel}/#{account}")
      body = JSON.generate(payload)
      secret = tamper_signature ? "segredo-errado-#{SecureRandom.hex(4)}" : self.class.secret_for(account)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json",
                                         "traceparent" => "00-#{trace_id}-#{SecureRandom.hex(8)}-01",
                                         HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(body, secret:))
      request.body = body

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { _1.request(request) }
      Response.new(status: response.code.to_i, body: parse(response.body), error: nil, trace_id:)
    rescue SystemCallError, Timeout::Error, SocketError, IOError => e
      Response.new(status: nil, body: nil, error: e.message, trace_id:)
    end

    private

    def parse(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      { "raw" => body.to_s }
    end
  end
end
