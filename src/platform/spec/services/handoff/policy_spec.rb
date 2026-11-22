require "rails_helper"

RSpec.describe Handoff::Policy do
  let(:policy) { described_class.for(build(:brand, :infinitepay)) }

  describe "RN-42: aviso de transferência por idioma" do
    it "pt-BR e inglês; idioma sem texto é erro" do
      expect(policy.transfer_notice_text("pt-BR")).to eq("Estou te transferindo para um especialista. Ele já recebeu o histórico da nossa conversa.")
      expect(policy.transfer_notice_text("en")).to eq("I'm transferring you to a specialist. They already have the history of our conversation.")
      expect { policy.transfer_notice_text("es") }.to raise_error(KeyError)
    end
  end

  describe "RN-34: pedido explícito de humano" do
    it "reconhece as expressões do idioma, sem diferenciar maiúsculas e acentos" do
      [ "Quero falar com uma pessoa", "quero falar com um ATENDENTE", "me passa pra um humano por favor",
        "Atendimento humano!", "quero falar com alguem de verdade" ].each do |text|
        expect(policy.human_request?(text, "pt-BR")).to be(true), text
      end
      expect(policy.human_request?("I want to talk to a human", "en")).to be(true)
      expect(policy.human_request?("can I speak to a real person?", "en")).to be(true)
    end

    it "não confunde com menção comum" do
      [ "meu repasse não caiu", "a pessoa do caixa disse que caiu", "o atendente da loja", "humanos erram" ].each do |text|
        expect(policy.human_request?(text, "pt-BR")).to be(false), text
      end
      expect(policy.human_request?("quero falar com uma pessoa", "en")).to be(false)
    end

    it "texto vazio ou ausente não é pedido" do
      expect(policy.human_request?(nil, "pt-BR")).to be(false)
      expect(policy.human_request?("", "pt-BR")).to be(false)
    end
  end

  it "RN-41: gatilhos de tempo e de falha de integração sobem a prioridade, um nível, sem passar de crítica" do
    expect(policy.raise_priority?("prazo_do_turno")).to be(true)
    expect(policy.raise_priority?("falha_de_integracao")).to be(true)
    expect(policy.raise_priority?("pedido_do_cliente")).to be(false)
    expect(policy.raised_priority("media")).to eq("alta")
    expect(policy.raised_priority("critica")).to eq("critica")
    expect(policy.raised_priority(nil)).to eq("alta") # sem triagem (bloco 11): média é a padrão (RN-13)
  end
end
