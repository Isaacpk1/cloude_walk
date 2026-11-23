RSpec.describe "Callback de status do chat (07 §5.0; interface do bloco 05, seção 3)" do
  include ProviderHelpers

  def app = ChannelsMock::App.freeze.app

  let(:status_url) { "http://localhost:3000/webhooks/chat/infinitepay-chat-mock/status" }

  def status_requests
    requests = []
    WebMock::RequestRegistry.instance.requested_signatures.hash.each do |signature, count|
      count.times { requests << signature } if signature.uri.to_s.end_with?("/status")
    end
    requests
  end

  describe "RF-06: delivered depois do aceite" do
    it "não chama a plataforma no caminho da resposta e envia delivered assinado e no contrato depois" do
      stub = stub_request(:post, status_url).to_return(status: 202, body: "{}")
      message_id = provider_send.then { json["message_id"] }

      expect(stub).not_to have_been_requested
      expect(ChannelsMock::StatusCallbacks.pending).to eq(1)

      ChannelsMock::StatusCallbacks.drain!

      expect(WebMock).to(have_requested(:post, status_url).once.with do |request|
        HelpdeskContracts::Signature.verify!(request.body, request.headers["X-Helpdesk-Signature"],
                                             secret: "dev-secret-infinitepay-chat-mock", now: ChannelsMock::Clock.now)
        payload = JSON.parse(request.body)
        HelpdeskContracts.valid?(:chat_status, payload) &&
          payload == { "message_id" => message_id, "status" => "delivered", "timestamp" => "2026-11-20T12:00:00.000Z" }
      end)
      expect(ChannelsMock::ChatDeliveries.find(message_id).last_status).to eq("delivered")
    end

    it "não envia um segundo delivered quando a mesma chave é repetida (RNF-15)" do
      stub_request(:post, status_url).to_return(status: 202, body: "{}")
      2.times { provider_send }

      ChannelsMock::StatusCallbacks.drain!

      expect(WebMock).to have_requested(:post, status_url).once
    end

    it "envia delivered também quando a confirmação ao envio se perdeu, porque o efeito existe" do
      stub_request(:post, status_url).to_return(status: 202, body: "{}")
      ChannelsMock::Faults.set(:lose_ack)
      provider_send

      ChannelsMock::StatusCallbacks.drain!

      expect(WebMock).to have_requested(:post, status_url).once
    end

    it "não envia status para envio recusado (503, 409, 401)" do
      ChannelsMock::Faults.set(:unavailable)
      provider_send
      provider_send(secret: "errado")

      expect(ChannelsMock::StatusCallbacks.pending).to eq(0)
    end
  end

  describe "RNF-14: retentativa quando a plataforma não responde" do
    it "repete com o mesmo corpo depois de conexão recusada e 5xx, até o 202" do
      stub_request(:post, status_url).to_raise(Errno::ECONNREFUSED).then
        .to_return(status: 503, body: "{}").then.to_return(status: 202, body: "{}")
      waits = []
      ChannelsMock::StatusCallbacks.reset!(mode: :manual, sleeper: ->(seconds) { waits << seconds })
      message_id = provider_send.then { json["message_id"] }

      ChannelsMock::StatusCallbacks.drain!

      expect(status_requests.size).to eq(3)
      expect(status_requests.map(&:body).uniq.size).to eq(1)
      expect(waits).to eq([ 0.5, 1.0 ])
      expect(ChannelsMock::ChatDeliveries.find(message_id).statuses.last)
        .to include("status" => "delivered", "attempts" => 3, "http_status" => 202)
    end

    it "desiste depois do limite de tentativas e registra o erro" do
      stub_request(:post, status_url).to_return(status: 500, body: "{}")
      message_id = provider_send.then { json["message_id"] }

      ChannelsMock::StatusCallbacks.drain!

      expect(WebMock).to have_requested(:post, status_url).times(ChannelsMock::StatusCallbacks::MAX_ATTEMPTS)
      expect(ChannelsMock::ChatDeliveries.find(message_id).statuses.last).to include("http_status" => 500)
    end

    it "não repete um 4xx (assinatura ou contrato recusados são definitivos)" do
      stub_request(:post, status_url).to_return(status: 401, body: "{}")
      provider_send

      ChannelsMock::StatusCallbacks.drain!

      expect(WebMock).to have_requested(:post, status_url).once
    end
  end

  describe "RF-06: read e failed pela tela" do
    it "envia read e failed pedidos no simulador para a mensagem escolhida" do
      stub_request(:post, status_url).to_return(status: 202, body: "{}")
      message_id = provider_send.then { json["message_id"] }
      ChannelsMock::StatusCallbacks.drain!

      post "/provider/chat/messages/#{message_id}/status", status: "read"
      expect(last_response.status).to eq(302)
      post "/provider/chat/messages/#{message_id}/status", status: "failed"
      ChannelsMock::StatusCallbacks.drain!

      sent = status_requests.map { JSON.parse(_1.body)["status"] }
      expect(sent).to eq(%w[delivered read failed])
      expect(ChannelsMock::ChatDeliveries.find(message_id).last_status).to eq("failed")
    end

    it "recusa status fora do contrato e mensagem desconhecida" do
      message_id = provider_send.then { json["message_id"] }

      post "/provider/chat/messages/#{message_id}/status", status: "lida"
      expect(last_response.status).to eq(422)
      post "/provider/chat/messages/chatmsg_nao_existe/status", status: "read"
      expect(last_response.status).to eq(404)
    end
  end

  it "processa a fila numa thread no modo padrão, fora da requisição" do
    stub_request(:post, status_url).to_return(status: 202, body: "{}")
    ChannelsMock::StatusCallbacks.reset!(mode: :thread)
    message_id = provider_send.then { json["message_id"] }

    Timeout.timeout(2) { Thread.pass until ChannelsMock::ChatDeliveries.find(message_id).statuses.any? }

    expect(WebMock).to have_requested(:post, status_url).once
  end
end
