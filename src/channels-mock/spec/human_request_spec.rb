RSpec.describe "Simulador: pedir humano e aviso de transferência (ROADMAP 10; RN-34, RN-42, RF-43)" do
  include ProviderHelpers

  def app = ChannelsMock::App.freeze.app

  let(:ip_url) { "http://localhost:3000/webhooks/chat/infinitepay-chat-mock" }
  let(:jim_url) { "http://localhost:3000/webhooks/chat/jim-chat-mock" }

  before do
    [ ip_url, jim_url ].each do |url|
      stub_request(:post, url).to_return(status: 202, body: { status: "accepted", ticket_id: 41 }.to_json)
      stub_request(:post, "#{url}/status").to_return(status: 202, body: "{}")
    end
  end

  def page = get("/").body
  def sent_text(url) = WebMock::RequestRegistry.instance.requested_signatures.hash.keys
                                                .select { _1.uri.to_s == url }.map { JSON.parse(_1.body)["text"] }

  describe "botão Pedir humano" do
    it "fica no formulário do chat, como outro envio do mesmo formulário" do
      form = page[%r{<form method="post" action="/chat/messages">.*?</form>}m]

      expect(form).to include(%(<button type="submit" name="pedir_humano" value="1"), "Pedir humano")
    end

    it "RN-34: envia o pedido pela mesma rota do chat, no idioma da marca da conta, ignorando o texto digitado" do
      post "/chat/messages", account: "infinitepay-chat-mock", account_id: "acc_1", customer_ref: "cus_1",
                             text: "meu repasse não caiu", pedir_humano: "1"
      post "/chat/messages", account: "jim-chat-mock", account_id: "acc_2", customer_ref: "cus_2", text: "", pedir_humano: "1"

      expect(sent_text(ip_url)).to eq([ "Quero falar com um atendente" ])
      expect(sent_text(jim_url)).to eq([ "I want to talk to a human agent" ])
      expect(ChannelsMock::Inbox.all.map { _1.payload["text"] }).to include("Quero falar com um atendente")
    end

    it "sem o botão, o texto digitado vai como sempre" do
      post "/chat/messages", account: "infinitepay-chat-mock", account_id: "acc_1", customer_ref: "cus_1", text: "oi"

      expect(sent_text(ip_url)).to eq([ "oi" ])
    end
  end

  describe "RN-42: aviso de transferência destacado" do
    def customer_sends
      post "/chat/messages", account: "infinitepay-chat-mock", account_id: "acc_1", customer_ref: "cus_1", text: "", pedir_humano: "1"
      ChannelsMock::Inbox.all.first
    end

    it "o aviso aparece como mensagem do sistema, ligado ao pedido, com o estado da entrega" do
      sent = customer_sends
      notice = "Estou te transferindo para um especialista. Ele já recebeu o histórico da nossa conversa."

      provider_send(send_body(text: notice, reply_to: sent.payload["message_id"]), key: "dlv-aviso", seq: 2)
      body = page

      item = body[%r{<li class="reply reply--system".*?</li>}m]
      expect(item).to include("Aviso de transferência", "Sistema", notice, "dlv-aviso", "seq 2")
      expect(body.index("Quero falar com um atendente")).to be < body.index(notice)
    end

    it "o aviso da JIM (inglês) também" do
      provider_send(send_body(text: "I'm transferring you to a specialist. They already have the history of our conversation.",
                              reply_to: "chat_msg_x"), key: "dlv-en", seq: 2)

      expect(page).to include(%(<li class="reply reply--system"))
    end

    it "resposta comum continua como resposta, sem o destaque" do
      provider_send(send_body(text: "Seu repasse cai hoje.", reply_to: "chat_msg_x"), key: "dlv-r", seq: 2)

      expect(page).not_to include(%(<li class="reply reply--system"))
    end
  end
end
