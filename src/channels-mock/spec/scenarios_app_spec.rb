# Tela e endpoint de controle dos cenários de rajada (ROADMAP, bloco 06, Frontend; RN-55, RN-56).
RSpec.describe "Simulador: cenários de rajada (RN-55, RN-56)" do
  def app = ChannelsMock::App.freeze.app

  let(:webhook_url) { "http://localhost:3000/webhooks/chat/infinitepay-chat-mock" }
  let(:client) { { account: "infinitepay-chat-mock", account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021" } }

  before { stub_request(:post, webhook_url).to_return(status: 202, body: { status: "accepted", ticket_id: 41 }.to_json) }

  def json = JSON.parse(last_response.body)

  def post_json(path, body)
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
  end

  describe "RN-56: corrida dos 3 s pelo endpoint de controle" do
    it "dispara por JSON e devolve o id da execução; o GET mostra o estado" do
      post_json "/simulador/cenarios/corrida-3s", client

      expect(last_response.status).to eq(202)
      expect(json).to include("scenario" => "corrida-3s", "status" => "queued", "run_id" => Integer)
      expect(json["status_url"]).to eq("/simulador/cenarios/#{json['run_id']}")

      ChannelsMock::Scenarios.drain!
      get json["status_url"]

      expect(last_response).to be_ok
      expect(last_response.content_type).to include("application/json")
      expect(json).to include("status" => "finished", "current_step" => 2, "total_steps" => 2)
      expect(json["steps"].map { _1.values_at("at", "planned_at", "http_status") })
        .to eq([ [ 0.0, "2026-11-20T12:00:00.000Z", 202 ], [ 3.0, "2026-11-20T12:00:03.000Z", 202 ] ])
    end

    it "mostra o passo atual enquanto a execução não terminou" do
      post_json "/simulador/cenarios/corrida-3s", client
      run_id = json["run_id"]

      get "/simulador/cenarios/#{run_id}"

      expect(json).to include("status" => "queued", "current_step" => 0)
      expect(json["steps"].map { _1["sent_at"] }).to eq([ nil, nil ])
    end

    it "aceita o disparo por formulário e volta à tela com atualização automática" do
      post "/simulador/cenarios/rajada-curta", client

      expect(last_response.status).to eq(302)
      expect(last_response["Location"]).to end_with("/?atualizar=1#cenarios")
      expect(ChannelsMock::Scenarios.runs.map(&:scenario).map(&:name)).to eq(%w[rajada-curta])
    end

    it "recusa cenário desconhecido com 404" do
      post_json "/simulador/cenarios/outro", client

      expect(last_response.status).to eq(404)
      expect(json).to include("error" => "cenario_desconhecido")
    end

    it "recusa conta fora da lista e cliente fora do contrato com 422, sem enviar nada" do
      post_json "/simulador/cenarios/corrida-3s", client.merge(account: "outra")
      expect(last_response.status).to eq(422)

      post_json "/simulador/cenarios/corrida-3s", client.merge(customer_ref: "")
      expect(last_response.status).to eq(422)
      expect(json).to include("error" => "contrato_invalido")

      expect(ChannelsMock::Scenarios.runs).to be_empty
    end

    it "responde 404 para execução que não existe" do
      get "/simulador/cenarios/999"

      expect(last_response.status).to eq(404)
    end
  end

  describe "tela" do
    it "tem um botão por cenário, com a conta e o cliente como no formulário" do
      get "/"

      body = last_response.body
      expect(body).to include("Cenários de rajada", 'formaction="/simulador/cenarios/corrida-3s"',
                              'formaction="/simulador/cenarios/rajada-curta"', 'formaction="/simulador/cenarios/rajada-longa"')
      expect(body).to include("Corrida dos 3 s", "RN-56", "RN-55")
    end

    it "mostra cada passo com horário planejado, real e HTTP, e as mensagens na conversa" do
      late = ->(at) { ChannelsMock::Clock.freeze(at + 0.04) }
      ChannelsMock::Scenarios.reset!(mode: :manual, waiter: late, out: StringIO.new)
      post "/simulador/cenarios/corrida-3s", client
      ChannelsMock::Scenarios.drain!

      get "/"

      body = last_response.body
      expect(body).to include("+3,0 s", "12:00:03.000", "12:00:03.040", "+40 ms", "Terminado", "2/2")
      expect(body.scan("é o de ontem, R$ 1.200").size).to be >= 2 # no passo e na conversa
      expect(body).to include("meu repasse não caiu")
    end

    it "mostra a falha da plataforma no passo" do
      stub_request(:post, webhook_url).to_return({ status: 503, body: "{}" }, { status: 202, body: "{}" })
      post "/simulador/cenarios/corrida-3s", client
      ChannelsMock::Scenarios.drain!

      get "/"

      expect(last_response.body).to include("Erro 503")
    end

    it "escapa o HTML dos dados do cliente e dos erros" do
      ChannelsMock::Scenarios.reset!(mode: :manual, out: StringIO.new, sender: ->(**) { raise "<b>quebrou</b>" },
                                     waiter: ->(at) { ChannelsMock::Clock.freeze(at) if at > ChannelsMock::Clock.now })
      post "/simulador/cenarios/corrida-3s", client.merge(account_id: "<script>alert(1)</script>")
      ChannelsMock::Scenarios.drain!

      get "/"

      expect(last_response.body).not_to include("<script>alert(1)</script>", "<b>quebrou</b>")
      expect(last_response.body).to include("&lt;script&gt;", "&lt;b&gt;quebrou&lt;/b&gt;")
    end
  end
end
