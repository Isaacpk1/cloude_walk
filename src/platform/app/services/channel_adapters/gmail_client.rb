require "net/http"

# Cliente da API do provedor de e-mail, no formato do Gmail (07, seção 5.0; ADR-018): users.history.list e
# users.messages.get, na caixa da conta. Assina cada chamada com o segredo da conta (ADR-019). Falha de rede ou
# resposta 5xx vira Unavailable: o push é reenviado e nada foi gravado.
module ChannelAdapters
  class GmailClient
    Unavailable = Class.new(StandardError)

    def initialize(account)
      @account = account
    end

    def history(start_history_id)
      get("history", startHistoryId: start_history_id, historyTypes: "messageAdded")
    end

    def message(id) = get("messages/#{CGI.escape(id)}", format: "full")

    private

    def get(path, **query)
      base = ENV.fetch("CHANNELS_URL", "http://localhost:4000").chomp("/")
      uri = URI("#{base}/provider/email/#{@account.slug}/gmail/v1/users/#{@account.email_address}/#{path}")
      uri.query = URI.encode_www_form(query) if query.any?
      request = Net::HTTP::Get.new(uri, HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header("", secret: @account.secret))
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: 5) { _1.request(request) }
      raise Unavailable, "http #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body.to_s
    rescue SystemCallError, Timeout::Error, SocketError, IOError, Net::HTTPBadResponse => e
      raise Unavailable, "#{e.class}: #{e.message}"
    end
  end
end
