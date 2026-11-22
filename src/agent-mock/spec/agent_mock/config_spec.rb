RSpec.describe AgentMock::Config do
  describe "RF-38: perfis rapido, lento e mudo" do
    it "usa o perfil padrão (rapido) sem AGENT_PROFILE" do
      config = described_class.load(env: {})

      expect(config.profile).to eq("rapido")
      expect(config).to have_attributes(mute: false, failure_rate: 0.0, seed: 42)
      expect(config.latency).to eq(described_class::Latency.new(min: 50, max: 150))
    end

    it "lento passa do aviso de progresso (15 s, RN-57) e fica abaixo do prazo do turno (20 s, RN-46); mudo não responde" do
      latency = described_class.load(env: { "AGENT_PROFILE" => "lento" }).latency
      expect(latency.min).to be > 15_000
      expect(latency.max).to be < 20_000
      expect(described_class.load(env: { "AGENT_PROFILE" => "mudo" }).mute).to be(true)
    end

    it "perfil desconhecido falha na subida, não em produção silenciosa" do
      expect { described_class.load(env: { "AGENT_PROFILE" => "turbo" }) }.to raise_error(described_class::Invalid, /turbo/)
    end
  end

  describe "RF-38: variáveis de ambiente sobrepõem o perfil" do
    it "AGENT_LATENCY_MS fixa ou em faixa, AGENT_FAILURE_RATE, AGENT_MUTE e AGENT_SEED" do
      config = described_class.load(env: { "AGENT_PROFILE" => "mudo", "AGENT_LATENCY_MS" => "1000-3000",
                                           "AGENT_FAILURE_RATE" => "0.25", "AGENT_MUTE" => "false", "AGENT_SEED" => "7" })

      expect(config.latency).to eq(described_class::Latency.new(min: 1000, max: 3000))
      expect(config).to have_attributes(failure_rate: 0.25, mute: false, seed: 7)
      expect(described_class.load(env: { "AGENT_LATENCY_MS" => "200" }).latency).to eq(described_class::Latency.new(min: 200, max: 200))
    end

    it "recusa valores inválidos" do
      [ { "AGENT_FAILURE_RATE" => "1.5" }, { "AGENT_FAILURE_RATE" => "abc" }, { "AGENT_LATENCY_MS" => "300-100" },
        { "AGENT_LATENCY_MS" => "-5" }, { "AGENT_MUTE" => "talvez" }, { "AGENT_SEED" => "x" } ].each do |env|
        expect { described_class.load(env:) }.to raise_error(described_class::Invalid), env.inspect
      end
    end
  end

  describe "RN-37: config_hash da configuração efetiva" do
    it "é sha256 estável para a mesma configuração" do
      expect(described_class.load(env: {}).config_hash).to eq(described_class.load(env: {}).config_hash)
      expect(described_class.load(env: {}).config_hash).to match(/\Asha256:\h{64}\z/)
    end

    it "muda quando muda o perfil, a semente, a latência, a taxa de falha ou as regras" do
      base = described_class.load(env: {}).config_hash
      variants = [ { "AGENT_PROFILE" => "lento" }, { "AGENT_SEED" => "1" }, { "AGENT_LATENCY_MS" => "51-150" },
                   { "AGENT_FAILURE_RATE" => "0.01" }, { "AGENT_MUTE" => "true" } ]

      hashes = variants.map { described_class.load(env: _1).config_hash }
      expect(hashes).not_to include(base)
      expect(hashes.uniq.size).to eq(variants.size)

      raw = YAML.safe_load_file(described_class::DEFAULT_PATH)
      raw["rules"].first["any"] << "supervisor"
      expect(described_class.new(raw, env: {}).config_hash).not_to eq(base)
    end

    it "não depende da ordem das chaves no YAML" do
      raw = YAML.safe_load_file(described_class::DEFAULT_PATH)
      reordered = raw.to_a.reverse.to_h
      reordered["tools"] = raw["tools"].to_a.reverse.to_h

      expect(described_class.new(reordered, env: {}).config_hash).to eq(described_class.new(raw, env: {}).config_hash)
    end
  end
end
