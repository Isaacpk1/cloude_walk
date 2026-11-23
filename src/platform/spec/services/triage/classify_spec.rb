require "rails_helper"

RSpec.describe Triage::Classify, "RF-12: triagem por palavras-chave" do
  let(:infinitepay) { build(:brand, :infinitepay) }
  let(:jim) { build(:brand, :jim, locale: "en") }

  def classify(text, brand: infinitepay) = described_class.call(brand:, text:)

  describe "RN-11: uma categoria da lista da marca" do
    {
      "Minha maquininha não liga" => "maquininha",
      "o repasse de ontem não caiu" => "repasses",
      "fiz um Pix e não chegou" => "pix",
      "quero saber do meu empréstimo" => "credito",
      "qual o saldo da conta digital?" => "conta_digital",
      "preciso trocar o e-mail do cadastro" => "cadastro",
      "dúvida sobre a taxa da venda" => "transacoes_e_pagamentos"
    }.each do |text, category|
      it "#{text.inspect} → #{category}" do
        expect(classify(text)).to have_attributes(category:, unclassified: false)
      end
    end

    it "compara sem acento e sem maiúsculas e registra as palavras que decidiram" do
      result = classify("MÁQUINA PARADA, NÃO LIGA")

      expect(result).to have_attributes(category: "maquininha", priority: "critica")
      expect(result.matched).to include("maquina", "nao liga")
    end

    it "com palavras de duas categorias, vence a que tem mais palavras" do
      expect(classify("o repasse da antecipação não caiu, e a venda?").category).to eq("repasses")
    end

    it "a lista de categorias é a da RN-11" do
      expect(Triage::Policy.for(infinitepay).categories).to eq(
        %w[transacoes_e_pagamentos repasses pix credito conta_digital maquininha cadastro outros]
      )
    end
  end

  describe "RN-12: prioridade pelo impacto no negócio do lojista" do
    {
      "minha maquininha está parada" => "critica",
      "repasse não recebido" => "alta",
      "dúvida sobre taxa" => "media",
      "troca de e-mail" => "baixa"
    }.each do |text, priority|
      it "#{text.inspect} → #{priority}" do
        expect(classify(text).priority).to eq(priority)
      end
    end

    it "a palavra de impacto mais forte vale, mesmo em categoria de base baixa" do
      expect(classify("troquei o email e a conta está bloqueada, não consigo vender").priority).to eq("critica")
    end
  end

  it "RN-12 em inglês: formas sem contração também contam (verificação do bloco 11)" do
    jim = build(:brand, :jim, locale: "en")
    {
      "my settlement did not arrive" => "alta", "I did not receive my payout" => "alta",
      "my card machine does not turn on" => "critica", "I can not sell" => "critica", "I cannot sell anything" => "critica"
    }.each do |text, priority|
      expect(described_class.call(brand: jim, text:).priority).to eq(priority), text
    end
  end

  describe "RN-13: o que não casa" do
    it "\"oi\" → outros, média, sem classificação" do
      expect(classify("oi")).to have_attributes(category: "outros", priority: "media", tags: [], matched: [],
                                                unclassified: true)
    end

    it "texto vazio ou nulo → outros, média" do
      expect(classify(nil)).to have_attributes(category: "outros", priority: "media", unclassified: true)
      expect(classify("")).to have_attributes(category: "outros", priority: "media", unclassified: true)
    end

    it "não casa pedaço de palavra (\"pixel\" não é Pix; \"taxativo\" não é taxa)" do
      expect(classify("o pixel da tela é taxativo")).to have_attributes(category: "outros", unclassified: true)
    end
  end

  describe "RF-10: tags por palavra-chave" do
    it "urgente, reclamacao e fraude" do
      result = classify("URGENTE: vou no Procon, tem um golpe na minha conta digital")

      expect(result.tags).to eq(%w[urgente reclamacao fraude])
    end

    it "sem palavra de tag, sem tags" do
      expect(classify("meu repasse não caiu").tags).to eq([])
    end
  end

  describe "RN-11, RN-12: idioma da marca (JIM em inglês)" do
    {
      "My card machine won't turn on" => %w[maquininha critica],
      "I haven't received my payout" => %w[repasses alta],
      "question about the fee on a sale" => %w[transacoes_e_pagamentos media],
      "I need to change my email" => %w[cadastro baixa],
      "hello" => %w[outros media]
    }.each do |text, (category, priority)|
      it "#{text.inspect} → #{category}, #{priority}" do
        expect(classify(text, brand: jim)).to have_attributes(category:, priority:)
      end
    end

    it "texto em português numa marca em inglês não casa (palavras do idioma da marca)" do
      expect(classify("minha maquininha não liga", brand: jim)).to have_attributes(category: "outros", unclassified: true)
    end

    it "tags em inglês" do
      expect(classify("urgent: this is a scam, I will file a complaint", brand: jim).tags).to eq(%w[urgente reclamacao fraude])
    end

    it "idioma sem palavras configuradas cai na RN-13, sem erro" do
      expect(classify("hola", brand: build(:brand, locale: "es"))).to have_attributes(category: "outros", unclassified: true)
    end
  end
end
