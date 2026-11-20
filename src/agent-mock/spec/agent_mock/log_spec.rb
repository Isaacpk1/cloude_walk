RSpec.describe AgentMock::Log do
  describe "invariante 13, RNF-20: logs em JSON com trace_id" do
    it "extrai o trace_id de um traceparent W3C válido e ignora o inválido" do
      expect(described_class.trace_id("00-#{'a' * 32}-#{'b' * 16}-01")).to eq("a" * 32)
      expect(described_class.trace_id("lixo")).to be_nil
      expect(described_class.trace_id(nil)).to be_nil
    end

    it "o logger do Karafka também sai em JSON" do
      io = StringIO.new

      described_class.karafka_logger(io).info("Running Karafka server")

      expect(JSON.parse(io.string)).to include("service" => "agent-mock", "event" => "karafka", "level" => "info",
                                               "message" => "Running Karafka server")
    end
  end
end
