RSpec.describe "Provedor do chat: POST /provider/chat/:conta/messages (RF-06, ADR-018, ADR-019)" do
  include ProviderHelpers

  def app = ChannelsMock::App.freeze.app

  describe "RF-06: aceite no contrato chat_send" do
    it "aceita o envio assinado e devolve o message_id do app" do
      provider_send

      expect(last_response.status).to eq(200)
      expect(json).to include("status" => "accepted")
      expect(json["message_id"]).to match(/\Achatmsg_\h{16}\z/)
      expect(last_response.headers["Idempotent-Replayed"]).to be_nil
      expect(ChannelsMock::ChatDeliveries.all.size).to eq(1)
      expect(ChannelsMock::ChatDeliveries.all.first).to have_attributes(
        message_id: json["message_id"], key: "dlv-1", conversation_id: "tkt_41", seq: 2, reply_to: "chat_msg_cliente1",
        text: "Vamos verificar o seu repasse.", account: ProviderHelpers::ACCOUNT, trace_id: "a" * 32
      )
    end

    it "responde 404 para conta desconhecida, sem efeito" do
      provider_send(account: "outra-conta")

      expect(last_response.status).to eq(404)
      expect(ChannelsMock::ChatDeliveries.all).to be_empty
    end
  end

  describe "RNF-23 / ADR-019: assinatura do corpo" do
    it "recusa com 401 a assinatura com outro segredo" do
      provider_send(secret: "segredo-errado")

      expect(last_response.status).to eq(401)
      expect(json).to include("error" => "assinatura_invalida", "reason" => "nao_confere")
      expect(ChannelsMock::ChatDeliveries.all).to be_empty
    end

    it "recusa com 401 o segredo de outra marca (marca errada)" do
      provider_send(secret: ChannelsMock::PlatformClient.secret_for("jim-chat-mock"))

      expect(last_response.status).to eq(401)
    end

    it "recusa com 401 a assinatura fora da janela de 5 minutos" do
      body = JSON.generate(send_body)
      headers = provider_headers(body)
      ChannelsMock::Clock.advance(301)

      post "/provider/chat/#{ProviderHelpers::ACCOUNT}/messages", body, headers

      expect(last_response.status).to eq(401)
      expect(json["reason"]).to eq("fora_da_janela")
    end
  end

  describe "RNF-28 / RN-44: contrato" do
    it "recusa com 422 o corpo fora do contrato, sem efeito" do
      provider_send(send_body(text: ""))

      expect(last_response.status).to eq(422)
      expect(json["error"]).to eq("contrato_invalido")
      expect(ChannelsMock::ChatDeliveries.all).to be_empty
    end

    it "recusa com 422 o corpo que não é JSON" do
      provider_send(raw: "{nao é json")

      expect(last_response.status).to eq(422)
    end
  end

  describe "RNF-15: idempotência por Idempotency-Key" do
    it "recusa com 400 o envio sem Idempotency-Key" do
      provider_send(key: nil)

      expect(last_response.status).to eq(400)
      expect(json["error"]).to eq("idempotency_key_ausente")
      expect(ChannelsMock::ChatDeliveries.all).to be_empty
    end

    it "recusa com 400 o envio sem conversa ou com seq inválida" do
      provider_send(conversation: nil)
      expect(last_response.status).to eq(400)

      provider_send(seq: "abc")
      expect(last_response.status).to eq(400)
      expect(ChannelsMock::ChatDeliveries.all).to be_empty
    end

    it "devolve a mesma resposta gravada para a mesma chave, com Idempotent-Replayed, sem novo efeito" do
      first = provider_send.body

      provider_send
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq(first)
      expect(last_response.headers["Idempotent-Replayed"]).to eq("true")
      expect(ChannelsMock::ChatDeliveries.all.size).to eq(1)
      expect(ChannelsMock::ChatDeliveries.all.first.replays).to eq(1)
    end

    it "RNF-15: duas requisições simultâneas com a mesma chave produzem um só efeito", :concurrency do
      body = JSON.generate(send_body)
      gate = Queue.new
      threads = Array.new(8) do
        Thread.new do
          session = Rack::Test::Session.new(Rack::MockSession.new(app))
          gate.pop
          session.post "/provider/chat/#{ProviderHelpers::ACCOUNT}/messages", body, provider_headers(body)
          session.last_response
        end
      end
      8.times { gate << true }
      responses = threads.map(&:value)

      expect(responses.map(&:status).uniq).to eq([ 200 ])
      expect(responses.map { JSON.parse(_1.body)["message_id"] }.uniq.size).to eq(1)
      expect(responses.count { _1.headers["Idempotent-Replayed"] == "true" }).to eq(7)
      expect(ChannelsMock::ChatDeliveries.all.size).to eq(1)
    end
  end

  describe "07 §3.2: ordem por X-Conversation-Seq" do
    it "recusa com 409 uma seq anterior à última aceita, com chave nova" do
      provider_send(key: "dlv-5", seq: 5)

      provider_send(key: "dlv-3", seq: 3)

      expect(last_response.status).to eq(409)
      expect(json).to eq("error" => "seq_anterior", "last_seq" => 5)
      expect(ChannelsMock::ChatDeliveries.all.map(&:seq)).to eq([ 5 ])
    end

    it "trata a seq igual com a mesma chave como repetição, não 409" do
      provider_send(key: "dlv-5", seq: 5)
      provider_send(key: "dlv-6", seq: 6)

      provider_send(key: "dlv-5", seq: 5)

      expect(last_response.status).to eq(200)
      expect(last_response.headers["Idempotent-Replayed"]).to eq("true")
    end

    it "recusa com 409 outra chave na mesma seq já aceita (duas entregas na mesma posição)" do
      provider_send(key: "dlv-5", seq: 5)

      provider_send(key: "dlv-outra", seq: 5)

      expect(last_response.status).to eq(409)
      expect(json).to eq("error" => "seq_repetida", "last_seq" => 5)
    end

    it "aceita seq maior e separa as conversas" do
      provider_send(key: "a", seq: 5)
      provider_send(key: "b", seq: 7)
      provider_send(key: "c", seq: 1, conversation: "tkt_99")

      expect(ChannelsMock::ChatDeliveries.all.map(&:seq)).to contain_exactly(5, 7, 1)
    end
  end

  describe "RNF-15 / 07 §6: falhas simuladas" do
    it "perde a confirmação uma vez: grava o efeito, responde 504, e a retentativa recebe a confirmação gravada" do
      ChannelsMock::Faults.set(:lose_ack)

      provider_send
      expect(last_response.status).to eq(504)
      expect(json["error"]).to eq("confirmacao_perdida")
      expect(ChannelsMock::ChatDeliveries.all.size).to eq(1)
      stored = ChannelsMock::ChatDeliveries.all.first.message_id

      provider_send
      expect(last_response.status).to eq(200)
      expect(json["message_id"]).to eq(stored)
      expect(last_response.headers["Idempotent-Replayed"]).to eq("true")
      expect(ChannelsMock::ChatDeliveries.all.size).to eq(1)
      expect(ChannelsMock::Faults.current).to eq(:none)
    end

    it "recusa com 503 sem efeito, e o envio seguinte com a mesma chave é aceito" do
      ChannelsMock::Faults.set(:unavailable)

      provider_send
      expect(last_response.status).to eq(503)
      expect(ChannelsMock::ChatDeliveries.all).to be_empty

      provider_send
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Idempotent-Replayed"]).to be_nil
    end

    it "mantém o 503 pelo número de vezes pedido" do
      ChannelsMock::Faults.set(:unavailable, times: 2)

      2.times { provider_send }
      expect(last_response.status).to eq(503)
      provider_send
      expect(last_response.status).to eq(200)
    end

    it "recusa definitivamente com 422 sem efeito" do
      ChannelsMock::Faults.set(:reject)

      provider_send

      expect(last_response.status).to eq(422)
      expect(json["error"]).to eq("recusada_pelo_provedor")
      expect(ChannelsMock::ChatDeliveries.all).to be_empty
    end

    it "lê a falha inicial do ambiente" do
      ChannelsMock::Faults.configure_from(
        { "CHAT_PROVIDER_FAULT" => "unavailable", "CHAT_PROVIDER_FAULT_TIMES" => "3" }
      )

      expect(ChannelsMock::Faults.current).to eq(:unavailable)
      expect(ChannelsMock::Faults.remaining).to eq(3)
    end

    it "troca a falha pelo endpoint de controle" do
      post "/provider/chat/faults", { "fault" => "lose_ack", "times" => "1" }.to_json, "CONTENT_TYPE" => "application/json"

      expect(last_response.status).to eq(200)
      expect(json).to eq("fault" => "lose_ack", "remaining" => 1)

      post "/provider/chat/faults", { "fault" => "qualquer" }.to_json, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(422)
    end
  end
end
