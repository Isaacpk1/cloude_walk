RSpec.describe AgentMock::Tools do
  describe "RF-32, RN-35: catálogo fechado de consultas" do
    it "só tem consultas: repasse, transação e taxa" do
      expect(described_class::CATALOG.keys).to contain_exactly("get_settlement_status", "get_transaction_status", "get_fee")
    end

    it "tool fora do catálogo não existe" do
      expect { described_class.fetch("refund_transaction") }.to raise_error(ArgumentError, /desconhecida/)
    end

    it "toda tool do config/scenarios.yml existe no catálogo" do
      expect(AgentMock::Config.load(env: {}).tools.keys).to match_array(described_class::CATALOG.keys)
    end
  end

  describe "RNF-30, invariante 12: resultados sintéticos e determinísticos" do
    let(:args) { { "customer_id" => "cus_1", "date" => "2026-11-16" } }

    it "mesmos argumentos e mesma semente dão o mesmo resultado e a mesma duração" do
      tool = described_class.fetch("get_settlement_status")

      expect(tool.new(seed: 42).call(args)).to eq(tool.new(seed: 42).call(args))
    end

    it "a semente muda o resultado" do
      tool = described_class.fetch("get_settlement_status")
      results = (1..10).map { tool.new(seed: _1).call(args).result }

      expect(results.uniq.size).to be > 1
    end

    it "cada chamada vira um item de tool_calls válido" do
      described_class::CATALOG.each_value do |tool|
        call = tool.new(seed: 42).call({ "customer_id" => "cus_1", "date" => "2026-11-16", "brand" => "jim", "method" => "pix",
                                         "reference" => "ultima" })

        expect(call.to_h.keys).to eq(%w[tool args result duration_ms])
        expect(call.duration_ms).to be_between(80, 400)
        expect(call.result).to be_a(Hash)
      end
    end
  end
end
