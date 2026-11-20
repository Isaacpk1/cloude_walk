RSpec.describe "Simulador: respostas recebidas pelo provedor (RF-04, RNF-05, ROADMAP 05)" do
  include ProviderHelpers

  def app = ChannelsMock::App.freeze.app

  let(:webhook_url) { "http://localhost:3000/webhooks/chat/infinitepay-chat-mock" }

  before do
    stub_request(:post, webhook_url).to_return(status: 202, body: { status: "accepted", ticket_id: 41 }.to_json)
    stub_request(:post, "#{webhook_url}/status").to_return(status: 202, body: "{}")
  end

  def customer_sends(text = "meu repasse não caiu")
    post "/chat/messages", account: "infinitepay-chat-mock", account_id: "acc_infinitepay_000021",
                           customer_ref: "cus_ref_000021", text:, message_id: ""
    ChannelsMock::Inbox.all.first
  end

  def page = get("/").body

  describe "RNF-05: tempo total percebido pelo cliente" do
    it "liga a resposta ao envio pelo reply_to e mostra o tempo total com o relógio controlado" do
      sent = customer_sends
      ChannelsMock::Clock.advance(2.4)

      provider_send(send_body(text: "Encontrei o seu repasse de ontem.", reply_to: sent.payload["message_id"]),
                    key: "0b6c3c1e-dlv", seq: 2)
      message_id = json["message_id"]
      body = page

      reply = body[/<li class="reply".*?<\/li>/m]
      expect(reply).to include("Encontrei o seu repasse de ontem.", message_id, sent.payload["message_id"],
                               "0b6c3c1e-dlv", "seq 2", "Tempo total", "2,4 s")
      expect(body.index("meu repasse não caiu")).to be < body.index("Encontrei o seu repasse de ontem.")
    end

    it "mostra o tempo de cada resposta quando o envio recebe mais de uma (progresso e resposta final)" do
      sent = customer_sends
      ChannelsMock::Clock.advance(15)
      provider_send(send_body(text: "Ainda estou verificando.", reply_to: sent.payload["message_id"]), key: "p", seq: 2)
      ChannelsMock::Clock.advance(3.25)
      provider_send(send_body(text: "Pronto, repasse localizado.", reply_to: sent.payload["message_id"]), key: "r", seq: 3)

      body = page

      expect(body).to include("15,0 s", "18,3 s")
    end

    it "marca a repetição da mesma Idempotency-Key, sem duplicar a resposta na conversa (RNF-15)" do
      sent = customer_sends
      2.times { provider_send(send_body(reply_to: sent.payload["message_id"])) }

      body = page

      expect(body.scan('<li class="reply"').size).to eq(1)
      expect(body).to include("repetida 1×")
    end

    it "lista à parte a resposta cujo reply_to não corresponde a nenhum envio do simulador" do
      provider_send(send_body(text: "Resposta órfã", reply_to: "chat_msg_de_outro_lugar"))

      body = page

      expect(body).to include("Respostas sem envio ligado", "Resposta órfã", "chat_msg_de_outro_lugar")
    end
  end

  describe "RF-56: rastreio até a mensagem original" do
    it "mostra o trace_id do envio e o link para a linha do tempo do atendimento" do
      sent = customer_sends

      body = page

      expect(body).to include(sent.response.trace_id, "http://localhost:3000/linha-do-tempo/41")
    end

    it "mostra o trace_id da resposta recebida (traceparent da entrega)" do
      sent = customer_sends
      provider_send(send_body(reply_to: sent.payload["message_id"]))

      expect(page).to include("a" * 32)
    end
  end

  describe "segurança: escape de HTML" do
    it "escapa o texto da resposta e o reply_to, que vêm de fora" do
      provider_send(send_body(text: "<script>alert(1)</script>", reply_to: "<img src=x onerror=alert(2)>"))

      body = page

      expect(body).not_to include("<script>alert(1)</script>", "<img src=x")
      expect(body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
    end
  end

  describe "status e falhas pela tela" do
    it "mostra o último status enviado à plataforma e os botões de lida e falha" do
      sent = customer_sends
      provider_send(send_body(reply_to: sent.payload["message_id"]))
      ChannelsMock::StatusCallbacks.drain!

      body = page

      expect(body).to include("delivered", "Marcar como lida", "Simular falha de entrega")
    end

    it "configura a falha simulada pelo formulário e mostra a falha ativa" do
      post "/simulador/falhas", fault: "lose_ack", times: "1"
      expect(last_response.status).to eq(302)

      expect(ChannelsMock::Faults.current).to eq(:lose_ack)
      expect(page).to include("Falha ativa", "lose_ack")
    end

    it "recusa falha desconhecida no formulário" do
      post "/simulador/falhas", fault: "explodir"

      expect(last_response.status).to eq(422)
    end
  end

  it "atualiza a página sozinha só quando pedido" do
    expect(page).not_to include('http-equiv="refresh"')

    get "/", atualizar: "3"
    expect(last_response.body).to include('<meta http-equiv="refresh" content="3">')
  end
end
