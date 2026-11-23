RSpec.describe "Provedores simulados de WhatsApp e e-mail (bloco 15; RF-02, RF-03, RF-06, ADR-018, ADR-019)" do
  include ProviderHelpers

  def app = ChannelsMock::App.freeze.app

  before do
    ChannelsMock::Providers::Whatsapp.clear
    ChannelsMock::Providers::Gmail.clear
    ChannelsMock::Inbox.clear
  end

  def signed(body, account) = { "CONTENT_TYPE" => "application/json", "HTTP_IDEMPOTENCY_KEY" => "dlv-1",
                                "HTTP_X_HELPDESK_SIGNATURE" => HelpdeskContracts::Signature.header(body, secret: ChannelsMock::PlatformClient.secret_for(account), at: ChannelsMock::Clock.now) }

  describe "WhatsApp" do
    let(:account) { "infinitepay-whatsapp-mock" }
    let(:path) { "/provider/whatsapp/#{account}/100000000000001/messages" }
    let(:body) { JSON.generate("messaging_product" => "whatsapp", "to" => "5511900000021", "type" => "text", "text" => { "body" => "Olá" }) }

    it "RF-06: aceita o envio assinado e devolve o id da mensagem; repetir a chave não duplica" do
      post path, body, signed(body, account)
      first = JSON.parse(last_response.body)
      post path, body, signed(body, account)

      expect(last_response.status).to eq(200)
      expect(first["messages"].first["id"]).to start_with("wamid.")
      expect(JSON.parse(last_response.body)).to eq(first)
      expect(ChannelsMock::Providers::Whatsapp.sent.size).to eq(1)
    end

    it "ADR-019: assinatura de outra marca é 401, sem efeito" do
      post path, body, signed(body, "jim-whatsapp-mock")

      expect(last_response.status).to eq(401)
      expect(ChannelsMock::Providers::Whatsapp.sent).to be_empty
    end

    it "phone_number_id que não é da conta: 404" do
      post "/provider/whatsapp/#{account}/999/messages", body, signed(body, account)

      expect(last_response.status).to eq(404)
    end

    it "corpo fora do contrato: 422" do
      bad = JSON.generate("to" => "x")
      post path, bad, signed(bad, account)

      expect(last_response.status).to eq(422)
    end

    it "falha simulada: 503 antes de qualquer efeito" do
      ChannelsMock::Faults.set(:unavailable, times: 1)
      post path, body, signed(body, account)

      expect(last_response.status).to eq(503)
      expect(ChannelsMock::Providers::Whatsapp.sent).to be_empty
    ensure
      ChannelsMock::Faults.clear
    end

    it "o webhook do simulador cumpre o contrato whatsapp_webhook" do
      payload = ChannelsMock::Providers::Whatsapp.webhook(account:, from: "5511900000021", text: "oi")

      expect(payload.dig("entry", 0, "changes", 0, "value", "metadata", "phone_number_id")).to eq("100000000000001")
    end
  end

  describe "e-mail (Gmail)" do
    let(:account) { "infinitepay-email-mock" }
    let(:address) { "suporte@infinitepay.example" }
    let(:base) { "/provider/email/#{account}/gmail/v1/users/#{address}" }

    def get_signed(path, acct = account)
      get path, {}, { "HTTP_X_HELPDESK_SIGNATURE" => HelpdeskContracts::Signature.header("", secret: ChannelsMock::PlatformClient.secret_for(acct), at: ChannelsMock::Clock.now) }
    end

    it "RF-03: o e-mail recebido gera o push, aparece no histórico e na busca da mensagem, no contrato do Gmail" do
      push = ChannelsMock::Providers::Gmail.deliver_mail(account:, from: "Loja <loja@example.com>", subject: "Repasse", text: "Meu repasse não caiu", attachments: [ "comprovante.pdf" ])
      expect { HelpdeskContracts.validate!(:email_push, push) }.not_to raise_error

      get_signed("#{base}/history?startHistoryId=0")
      history = JSON.parse(last_response.body)
      expect { HelpdeskContracts.validate!(:email_history, history) }.not_to raise_error
      id = history.dig("history", 0, "messages", 0, "id")

      get_signed("#{base}/messages/#{id}?format=full")
      expect(last_response.status).to eq(200)
      expect { HelpdeskContracts.validate!(:email_message, JSON.parse(last_response.body)) }.not_to raise_error
    end

    it "o histórico só devolve o que veio depois do cursor" do
      ChannelsMock::Providers::Gmail.deliver_mail(account:, from: "a@example.com", subject: "1", text: "um")
      get_signed("#{base}/history?startHistoryId=1001")

      expect(JSON.parse(last_response.body)).not_to have_key("history")
    end

    it "ADR-019: busca com assinatura de outra marca é 401" do
      get_signed("#{base}/history?startHistoryId=0", "jim-email-mock")

      expect(last_response.status).to eq(401)
    end

    it "RF-06: recebe a resposta, extrai destino e assunto do MIME, e é idempotente pela chave" do
      mime = "From: #{address}\r\nTo: Loja <loja@example.com>\r\nSubject: Re: Repasse\r\n\r\nSeu repasse cai hoje."
      body = JSON.generate("raw" => Base64.urlsafe_encode64(mime, padding: false), "threadId" => "thr1")
      post "#{base}/messages/send", body, signed(body, account)
      first = JSON.parse(last_response.body)
      post "#{base}/messages/send", body, signed(body, account)

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq(first)
      expect(ChannelsMock::Providers::Gmail.sent.size).to eq(1)
      expect(ChannelsMock::Providers::Gmail.sent.first).to have_attributes(to: "Loja <loja@example.com>", subject: "Re: Repasse", text: "Seu repasse cai hoje.", thread_id: "thr1")
    end

    it "caixa que não é da conta: 404" do
      get_signed("/provider/email/#{account}/gmail/v1/users/outra@x.example/history")

      expect(last_response.status).to eq(404)
    end
  end

  describe "simulador (formulários)" do
    it "o WhatsApp é entregue à plataforma como webhook assinado e entra no histórico" do
      stub = WebMock.stub_request(:post, "#{ChannelsMock::App::PLATFORM_URL}/webhooks/whatsapp/infinitepay-whatsapp-mock")
                    .to_return(status: 202, body: { "status" => "accepted" }.to_json)

      post "/whatsapp/messages", { "account" => "infinitepay-whatsapp-mock", "from" => "5511900000021", "text" => "oi" }

      expect(stub).to have_been_requested
      expect(ChannelsMock::Inbox.all.first).to have_attributes(channel: "whatsapp", outcome: "Confirmada")
    end

    it "o e-mail grava na caixa e avisa a plataforma com o push" do
      stub = WebMock.stub_request(:post, "#{ChannelsMock::App::PLATFORM_URL}/webhooks/email/infinitepay-email-mock")
                    .to_return(status: 202, body: { "status" => "accepted" }.to_json)

      post "/email/messages", { "account" => "infinitepay-email-mock", "from" => "a@example.com", "subject" => "Oi", "text" => "texto" }

      expect(stub).to have_been_requested
      status, body = ChannelsMock::Providers::Gmail.history(
        account: "infinitepay-email-mock", address: "suporte@infinitepay.example", start: 0,
        signature: HelpdeskContracts::Signature.header("", secret: ChannelsMock::PlatformClient.secret_for("infinitepay-email-mock"), at: ChannelsMock::Clock.now)
      )
      expect([ status, body["history"].size ]).to eq([ 200, 1 ])
    end

    it "a tela principal lista os formulários de WhatsApp e e-mail" do
      get "/"

      expect(last_response.body).to include("Enviar pelo WhatsApp", "Enviar por e-mail")
    end
  end
end
