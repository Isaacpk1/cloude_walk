# Perfil do agente escolhido pelo simulador sem reiniciar o agente (RF-38; ROADMAP, bloco 08, Frontend).
# O simulador grava o perfil num Redis de controle; o agent-mock lê a cada evento (README, "Perfil em
# tempo de execução"). Nunca lê o Postgres da plataforma (invariante 12).
RSpec.describe AgentMock::Profiles do
  let(:redis) { KafkaHelpers::FakeControlRedis.new }
  let(:io) { StringIO.new }
  let(:config) { AgentMock::Config.load(env: {}) }
  subject(:profiles) { described_class.new(config:, source: AgentMock::ProfileSource.new(redis:), log: AgentMock::Log.new(io)) }

  def brand_key(brand) = AgentMock::ProfileSource.key("brand:#{brand}")
  def global_key = AgentMock::ProfileSource.key("global")

  describe "RF-38: perfil escolhido pelo simulador" do
    it "usa as chaves de controle combinadas com o simulador" do
      expect(global_key).to eq("helpdesk:agent-mock:profile:global")
      expect(brand_key("jim")).to eq("helpdesk:agent-mock:profile:brand:jim")
    end

    it "sem perfil gravado vale o AGENT_PROFILE (perfil padrão)" do
      runtime = profiles.resolve("infinitepay")

      expect(runtime.config.profile).to eq("rapido")
      expect(runtime.source).to eq("env")
      lento = described_class.new(config: AgentMock::Config.load(env: { "AGENT_PROFILE" => "lento" }),
                                  source: AgentMock::ProfileSource.new(redis:), log: AgentMock::Log.new(io))
      expect(lento.resolve("infinitepay").config.profile).to eq("lento")
    end

    it "o perfil global vale para todas as marcas e o da marca tem precedência" do
      redis.set(global_key, "lento")
      redis.set(brand_key("jim"), "mudo")

      expect(profiles.resolve("infinitepay")).to have_attributes(source: "global")
      expect(profiles.resolve("infinitepay").config.profile).to eq("lento")
      expect(profiles.resolve("jim")).to have_attributes(source: "brand")
      expect(profiles.resolve("jim").config).to have_attributes(profile: "mudo", mute: true)
    end

    it "lê a cada resolução: a troca vale no evento seguinte, sem reiniciar" do
      expect(profiles.resolve("infinitepay").config.profile).to eq("rapido")

      redis.set(brand_key("infinitepay"), "mudo")
      expect(profiles.resolve("infinitepay").config.profile).to eq("mudo")

      redis.del(brand_key("infinitepay"))
      expect(profiles.resolve("infinitepay").config.profile).to eq("rapido")
      expect(redis.reads).to eq(3)
    end

    it "perfil desconhecido gravado é recusado: vale o padrão e loga, sem expor nada do cliente" do
      redis.set(brand_key("infinitepay"), "turbo")

      runtime = profiles.resolve("infinitepay", trace_id: "a" * 32)

      expect(runtime.config.profile).to eq("rapido")
      expect(runtime.source).to eq("env")
      expect(sole(log_lines(io))).to include("event" => "agent.profile_unknown", "level" => "warn", "profile" => "turbo",
                                             "scope" => "brand", "fallback" => "rapido", "trace_id" => "a" * 32)
    end

    it "valida todos os perfis na subida e as sobreposições do ambiente valem em qualquer perfil" do
      config = AgentMock::Config.load(env: { "AGENT_SEED" => "7" })
      profiles = described_class.new(config:, source: AgentMock::ProfileSource.new(redis:), log: AgentMock::Log.new(io))
      redis.set(global_key, "lento")

      expect(profiles.resolve("jim").config).to have_attributes(profile: "lento", seed: 7)
      expect(profiles.names).to eq(%w[rapido lento mudo])
    end
  end

  describe "RN-37: config_hash do perfil efetivo" do
    it "o config_hash muda com o perfil escolhido e é igual ao do mesmo perfil pelo ambiente" do
      rapido = profiles.resolve("jim").config.config_hash
      redis.set(global_key, "lento")
      lento = profiles.resolve("jim").config.config_hash

      expect(lento).not_to eq(rapido)
      expect(lento).to eq(AgentMock::Config.load(env: { "AGENT_PROFILE" => "lento" }).config_hash)
    end
  end

  describe "RF-38; 07, seção 6: fonte do perfil fora do ar" do
    it "Redis fora: cai no perfil padrão, loga e não levanta erro" do
      redis.down!

      runtime = profiles.resolve("infinitepay", trace_id: "b" * 32)

      expect(runtime.config.profile).to eq("rapido")
      expect(runtime.source).to eq("env")
      line = sole(log_lines(io))
      expect(line).to include("event" => "agent.profile_source_failed", "level" => "warn", "fallback" => "rapido",
                              "error" => "Redis::CannotConnectError", "trace_id" => "b" * 32)
    end

    it "com o Redis de verdade inalcançável, o cliente falha rápido e cai no padrão" do
      source = AgentMock::ProfileSource.build(env: { "AGENT_CONTROL_REDIS_URL" => "redis://127.0.0.1:1/1" })
      profiles = described_class.new(config:, source:, log: AgentMock::Log.new(io))
      expect(source.redis._client.config).to have_attributes(connect_timeout: 0.2, read_timeout: 0.2)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(profiles.resolve("jim").config.profile).to eq("rapido")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect(sole(log_lines(io))).to include("event" => "agent.profile_source_failed")
    end

    it "sem AGENT_CONTROL_REDIS_URL não há fonte: vale só o AGENT_PROFILE, sem tentar conectar" do
      source = AgentMock::ProfileSource.build(env: {})

      expect(source).to be_nil
      expect(described_class.new(config:, source:, log: AgentMock::Log.new(io)).resolve("jim").source).to eq("env")
      expect(io.string).to be_empty
    end
  end
end
