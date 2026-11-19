RSpec.describe HelpdeskContracts::Signature do
  let(:body) { '{"message_id":"chat_msg_1","text":"oi"}' }
  let(:secret) { "segredo-da-conta" }
  let(:now) { Time.at(1_763_500_000) }

  describe "RNF-23: assinatura válida" do
    it "aceita o cabeçalho gerado com o mesmo segredo e corpo" do
      header = described_class.header(body, secret:, at: now)

      expect(header).to match(/\At=1763500000,v1=\h{64}\z/)
      expect(described_class.verify!(body, header, secret:, now:)).to be(true)
    end

    it "aceita no limite exato da janela de 5 min" do
      header = described_class.header(body, secret:, at: now - 300)

      expect(described_class.verify!(body, header, secret:, now:)).to be(true)
    end
  end

  describe "RNF-23: assinatura inválida é recusada" do
    def rejection(header, body: self.body, secret: self.secret)
      described_class.verify!(body, header, secret:, now:)
      nil
    rescue described_class::Invalid => e
      e.reason
    end

    it("ausente") { expect(rejection(nil)).to eq(:ausente) }
    it("malformada") { expect(rejection("sha256=abc")).to eq(:malformada) }
    it("de outro segredo (outra conta)") { expect(rejection(described_class.header(body, secret: "outro", at: now))).to eq(:nao_confere) }
    it("corpo alterado") { expect(rejection(described_class.header(body, secret:, at: now), body: body.sub("oi", "ok"))).to eq(:nao_confere) }
    it("um segundo depois da janela (replay)") { expect(rejection(described_class.header(body, secret:, at: now - 301))).to eq(:fora_da_janela) }
    it("do futuro além da janela") { expect(rejection(described_class.header(body, secret:, at: now + 301))).to eq(:fora_da_janela) }
    it("segredo vazio nunca valida") { expect(rejection(described_class.header(body, secret: "", at: now), secret: "")).to eq(:sem_segredo) }

    it "horário trocado mantendo a assinatura antiga" do
      v1 = described_class.header(body, secret:, at: now - 1000)[/v1=(\h+)/, 1]

      expect(rejection("t=#{now.to_i},v1=#{v1}")).to eq(:nao_confere)
    end
  end
end
