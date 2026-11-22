RSpec.describe HelpdeskContracts::DeadLetter do
  let(:headers) do
    { "dlq_source" => "broker", "dlq_reason" => "contrato", "event_id" => "e-1", "traceparent" => "",
      "dlq_violations" => JSON.generate([ { pointer: "/turn", type: "required", message: "falta turn" } ]) }
  end

  describe "RN-44, RF-37: vista da mensagem da DLQ" do
    it "decodifica dlq_violations e mantém o corpo como texto" do
      view = described_class.view(headers:, payload: "{nao é json", key: "tkt_1")

      expect(view).to eq("key" => "tkt_1", "payload" => "{nao é json",
                         "headers" => headers.merge("dlq_violations" => [
                                                      { "pointer" => "/turn", "type" => "required", "message" => "falta turn" }
                                                    ]))
      expect(HelpdeskContracts.errors(:dead_letter, view)).to eq([])
    end

    it "aceita cabeçalhos do Kafka como lista (Karafka) e chaves em símbolo" do
      view = described_class.view(headers: { dlq_reason: [ "contrato" ], "dlq_source" => [ "broker" ] }, payload: "x")

      expect(view["headers"]).to include("dlq_reason" => "contrato", "dlq_source" => "broker")
    end

    it "deixa dlq_violations ilegível como texto, para o contrato apontar o defeito" do
      view = described_class.view(headers: headers.merge("dlq_violations" => "[nao"), payload: "x")

      expect(HelpdeskContracts.errors(:dead_letter, view).map(&:pointer)).to eq([ "/headers/dlq_violations" ])
    end

    it "lê o corpo binário como UTF-8 e troca bytes inválidos por U+FFFD" do
      view = described_class.view(headers:, payload: "ok\xFF".b)

      expect(view["payload"]).to eq("ok�")
      expect(view["payload"].encoding).to eq(Encoding::UTF_8)
    end
  end
end
