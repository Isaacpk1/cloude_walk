RSpec.describe ChannelsMock::PlatformClient do
  let(:client) { described_class.new(base_url: "http://web:3000") }
  let(:payload) { { "message_id" => "chat_msg_1" } }

  it "envia o webhook à URL da conta com JSON e traceparent (RF-56)" do
    stub = stub_request(:post, "http://web:3000/webhooks/chat/infinitepay-chat-mock")
      .with(body: payload.to_json, headers: { "Content-Type" => "application/json" }) { _1.headers["Traceparent"].match?(/\A00-\h{32}-\h{16}-01\z/) }
      .to_return(status: 202, body: { status: "accepted", ticket_id: 7 }.to_json)

    result = client.deliver(channel: "chat", account: "infinitepay-chat-mock", payload:)

    expect(stub).to have_been_requested
    expect(result).to have_attributes(status: 202, body: { "status" => "accepted", "ticket_id" => 7 })
  end

  it "RNF-23 / ADR-019: assina o corpo bruto com o segredo da conta" do
    stub = stub_request(:post, "http://web:3000/webhooks/chat/infinitepay-chat-mock").with { |request|
      HelpdeskContracts::Signature.verify!(request.body, request.headers["X-Helpdesk-Signature"],
                                           secret: "dev-secret-infinitepay-chat-mock", now: ChannelsMock::Clock.now)
    }.to_return(status: 202, body: "{}")

    client.deliver(channel: "chat", account: "infinitepay-chat-mock", payload:)

    expect(stub).to have_been_requested
  end

  it "assina com outro segredo quando a demonstração pede assinatura inválida" do
    stub_request(:post, %r{/webhooks/}).to_return(status: 401, body: { status: "unauthorized" }.to_json)

    client.deliver(channel: "chat", account: "infinitepay-chat-mock", payload:, tamper_signature: true)

    expect(WebMock).to(have_requested(:post, %r{/webhooks/}).with do |request|
      HelpdeskContracts::Signature.verify!(request.body, request.headers["X-Helpdesk-Signature"],
                                           secret: "dev-secret-infinitepay-chat-mock", now: ChannelsMock::Clock.now)
      false
    rescue HelpdeskContracts::Signature::Invalid
      true
    end)
  end

  it "lê o segredo da conta do ambiente quando definido" do
    expect(described_class.secret_for("jim-chat-mock", env: { "PROVIDER_SECRET_JIM_CHAT_MOCK" => "s3" })).to eq("s3")
    expect(described_class.secret_for("jim-chat-mock", env: {})).to eq("dev-secret-jim-chat-mock")
  end

  it "registra a plataforma fora do ar sem quebrar o simulador" do
    stub_request(:post, %r{/webhooks/}).to_raise(Errno::ECONNREFUSED)

    result = client.deliver(channel: "chat", account: "infinitepay-chat-mock", payload:)

    expect(result.status).to be_nil
    expect(result.error).to match(/Connection refused/)
  end
end
