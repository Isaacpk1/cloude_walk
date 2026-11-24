# Envio real de um webhook assinado e da sua repetição. Só contas sintéticas de validação.
require "net/http"
require "json"
require "openssl"
require "securerandom"
require "time"

account, identity, text = ARGV
allowed = account&.match?(/\A(?:validacao-\d+|infinitepay|jim)-chat-mock\z/)
abort "uso: live_chat.rb conta-chat-mock acc_validacao_<id> texto" unless allowed && identity&.start_with?("acc_validacao_") && text
id = "validacao-#{SecureRandom.uuid}"
body = JSON.generate(message_id: id, account_id: identity, customer_ref: "ref_#{identity}", text:, sent_at: Time.now.utc.iso8601(3))
t = Time.now.to_i
signature = "t=#{t},v1=#{OpenSSL::HMAC.hexdigest('SHA256', "dev-secret-#{account}", "#{t}.#{body}")}"
uri = URI("#{ENV.fetch('PLATFORM_URL', 'http://web:3000')}/webhooks/chat/#{account}")
responses = [ signature, signature, "t=#{t},v1=#{'0' * 64}" ].map do |header|
  request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "X-Helpdesk-Signature" => header)
  request.body = body
  response = Net::HTTP.start(uri.host, uri.port, read_timeout: 60) { _1.request(request) }
  { status: response.code.to_i, trace_id: response["X-Trace-Id"], body: JSON.parse(response.body) }
end
puts JSON.pretty_generate(message_id: id, account:, identity:, responses:)
exit(responses.map { _1[:status] } == [ 202, 200, 401 ] ? 0 : 1)
