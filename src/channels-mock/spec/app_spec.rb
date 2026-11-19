RSpec.describe "Simulador do cliente (RF-04)" do
  # Congelado como no config.ru: pega estado mutável na classe.
  def app = ChannelsMock::App.freeze.app

  let(:webhook_url) { %r{http://localhost:3000/webhooks/chat/infinitepay-chat-mock} }

  it "mostra o formulário do chat com as contas das duas marcas" do
    get "/"

    expect(last_response).to be_ok
    expect(last_response.body).to include("Simulador do cliente", "infinitepay-chat-mock", "jim-chat-mock")
  end

  it "envia a mensagem como webhook do provedor e mostra a confirmação da plataforma" do
    stub_request(:post, webhook_url).to_return(
      status: 202, body: { status: "accepted", ticket_id: 41, message_id: 9, seq: 1 }.to_json
    )

    post "/chat/messages", account: "infinitepay-chat-mock", account_id: "acc_infinitepay_000021",
                           customer_ref: "cus_ref_000021", text: "meu repasse não caiu"
    follow_redirect!

    expect(WebMock).to have_requested(:post, webhook_url).with { JSON.parse(_1.body)["text"] == "meu repasse não caiu" }
    expect(last_response.body).to include("202", "Confirmada", "http://localhost:3000/conversas/41")
  end

  it "reenvia o mesmo webhook (mesmo ID externo) e mostra a duplicata" do
    stub_request(:post, webhook_url)
      .to_return({ status: 202, body: { status: "accepted", ticket_id: 41 }.to_json },
                 { status: 200, body: { status: "duplicate", ticket_id: 41 }.to_json })
    post "/chat/messages", account: "infinitepay-chat-mock", account_id: "acc_1", customer_ref: "cus_1", text: "oi"
    sent = ChannelsMock::Inbox.all.first

    post "/chat/messages/#{sent.id}/resend"
    follow_redirect!

    bodies = []
    expect(WebMock).to(have_requested(:post, webhook_url).twice.with { bodies << _1.body })
    expect(bodies.uniq.size).to eq(1)
    expect(last_response.body).to include("Duplicada")
  end

  it "RNF-23: com a opção de assinatura inválida, mostra a recusa da plataforma" do
    stub_request(:post, webhook_url).to_return(status: 401, body: { status: "unauthorized", reason: "nao_confere" }.to_json)

    post "/chat/messages", account: "infinitepay-chat-mock", account_id: "acc_1", customer_ref: "cus_1", text: "oi",
                           tamper_signature: "1"
    follow_redirect!

    expect(last_response.body).to include("Recusada", "401", "nao_confere", "assinatura inválida")
  end

  it "não envia texto vazio e mostra o motivo" do
    post "/chat/messages", account: "infinitepay-chat-mock", account_id: "acc_1", customer_ref: "cus_1", text: ""
    follow_redirect!

    expect(WebMock).not_to have_requested(:post, webhook_url)
    expect(last_response.body).to include("fora do contrato")
  end

  it "recusa conta que não está na lista" do
    post "/chat/messages", account: "outra", account_id: "acc_1", customer_ref: "cus_1", text: "oi"

    expect(last_response.status).to eq(422)
  end
end
