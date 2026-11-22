# Perfil do agente mock escolhido pelo simulador (RF-38; ROADMAP, bloco 08, Frontend; RN-46, RN-57).
# O simulador grava no Redis de controle; o agent-mock lê a cada evento (src/agent-mock/README.md).
RSpec.describe "RF-38: perfil escolhido pelo simulador" do
  def app = ChannelsMock::App.freeze.app

  let(:redis) { ChannelsMock::AgentProfile.redis }
  let(:out) { StringIO.new }

  before { ChannelsMock::AgentProfile.reset!(redis: FakeControlRedis.new, out:) }

  def json = JSON.parse(last_response.body)
  def post_json(body) = post("/simulador/agente/perfil", JSON.generate(body), "CONTENT_TYPE" => "application/json")
  def scope(name) = json["scopes"].find { _1["scope"] == name }

  describe "RF-38: endpoint de controle" do
    it "grava o perfil global nas chaves que o agent-mock lê" do
      post_json "profile" => "lento", "scope" => "global"

      expect(last_response.status).to eq(200)
      expect(redis.get("helpdesk:agent-mock:profile:global")).to eq("lento")
      expect(scope("global")).to include("profile" => "lento")
      expect(scope("infinitepay-chat-mock")).to include("brand" => "infinitepay", "profile" => nil, "effective" => "lento",
                                                        "source" => "global")
    end

    it "grava o perfil por conta do provedor, na chave da marca, com precedência sobre o global" do
      post_json "profile" => "lento", "scope" => "global"
      post_json "profile" => "mudo", "scope" => "jim-chat-mock"

      expect(redis.get("helpdesk:agent-mock:profile:brand:jim")).to eq("mudo")
      expect(scope("jim-chat-mock")).to include("effective" => "mudo", "source" => "brand")
      expect(scope("infinitepay-chat-mock")).to include("effective" => "lento", "source" => "global")
    end

    it "padrao apaga a escolha: volta a valer o AGENT_PROFILE do agente" do
      post_json "profile" => "mudo", "scope" => "infinitepay-chat-mock"
      post_json "profile" => "padrao", "scope" => "infinitepay-chat-mock"

      expect(redis.get("helpdesk:agent-mock:profile:brand:infinitepay")).to be_nil
      expect(scope("infinitepay-chat-mock")).to include("profile" => nil, "effective" => nil, "source" => "env")
    end

    it "repetir a mesma escolha não muda nada (idempotente)" do
      2.times { post_json "profile" => "lento", "scope" => "global" }

      expect(last_response.status).to eq(200)
      expect(redis.get("helpdesk:agent-mock:profile:global")).to eq("lento")
    end

    it "GET devolve o estado atual com o que cada perfil demonstra" do
      get "/simulador/agente/perfil"

      expect(last_response.status).to eq(200)
      expect(json["available"]).to be(true)
      expect(json["profiles"].map { _1["name"] }).to eq(%w[rapido lento mudo])
      expect(json["scopes"].map { _1["scope"] }).to eq(%w[global infinitepay-chat-mock jim-chat-mock])
    end

    it "recusa perfil desconhecido com 422, sem gravar" do
      post_json "profile" => "turbo", "scope" => "global"

      expect(last_response.status).to eq(422)
      expect(json).to include("error" => "perfil_desconhecido")
      expect(redis.get("helpdesk:agent-mock:profile:global")).to be_nil
    end

    it "marca errada: recusa escopo fora da lista com 422, sem gravar" do
      post_json "profile" => "mudo", "scope" => "outra-conta"

      expect(last_response.status).to eq(422)
      expect(json).to include("error" => "escopo_desconhecido")
      expect(redis.writes).to eq(0)
    end

    it "recusa JSON malformado com 422" do
      post "/simulador/agente/perfil", "{", "CONTENT_TYPE" => "application/json"

      expect(last_response.status).to eq(422)
      expect(json).to include("error" => "pedido_invalido")
    end

    it "Redis de controle fora do ar: 503, sem derrubar o simulador" do
      redis.down!

      post_json "profile" => "lento", "scope" => "global"
      expect(last_response.status).to eq(503)
      expect(json).to include("error" => "controle_indisponivel")

      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to include("Redis de controle indisponível")
    end

    it "sem AGENT_CONTROL_REDIS_URL o controle fica desligado: 503 e aviso na tela" do
      ChannelsMock::AgentProfile.reset!(redis: nil, out:)

      post_json "profile" => "lento", "scope" => "global"
      expect(last_response.status).to eq(503)
      expect(json).to include("error" => "controle_desligado")

      get "/"
      expect(last_response.body).to include("AGENT_CONTROL_REDIS_URL")
    end

    it "com o Redis de verdade inalcançável, falha rápido com 503" do
      ChannelsMock::AgentProfile.configure_from({ "AGENT_CONTROL_REDIS_URL" => "redis://127.0.0.1:1/1" }, out:)
      expect(ChannelsMock::AgentProfile.redis._client.config).to have_attributes(connect_timeout: 0.2, read_timeout: 0.2)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      post_json "profile" => "lento", "scope" => "global"

      expect(last_response.status).to eq(503)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect(JSON.parse(out.string.lines.last)).to include("event" => "agent_profile.unavailable")
    end

    it "loga em JSON a troca, sem dado de cliente (RN-51)" do
      post_json "profile" => "mudo", "scope" => "jim-chat-mock"

      line = JSON.parse(out.string.lines.last)
      expect(line).to eq("event" => "agent_profile.set", "scope" => "jim-chat-mock", "brand" => "jim", "profile" => "mudo",
                         "at" => "2026-11-20T12:00:00.000Z")
    end
  end

  describe "RF-38: na tela" do
    it "aceita o formulário e volta à seção do agente" do
      post "/simulador/agente/perfil", { "profile" => "lento", "scope" => "infinitepay-chat-mock" }

      expect(last_response.status).to eq(302)
      expect(last_response["Location"]).to end_with("/#agente")
      expect(redis.get("helpdesk:agent-mock:profile:brand:infinitepay")).to eq("lento")
    end

    it "mostra o perfil ativo por escopo e o que cada perfil demonstra" do
      redis.set("helpdesk:agent-mock:profile:global", "mudo")

      get "/"

      body = last_response.body
      expect(body).to include('id="agente"', "Perfil do agente mock", "Sem resposta", "Rápido", "Lento")
      expect(body).to include("aviso de progresso aos 15 s", "timeout do turno aos 20 s", "fila humana")
      expect(body).to match(%r{<td>global</td>\s*<td>[^<]*</td>\s*<td><strong>Sem resposta</strong>})
    end

    it "escapa o valor gravado no Redis por outro processo" do
      redis.set("helpdesk:agent-mock:profile:global", "<script>alert(1)</script>")

      get "/"

      expect(last_response.body).not_to include("<script>alert(1)</script>")
      expect(last_response.body).to include("&lt;script&gt;")
    end
  end
end
