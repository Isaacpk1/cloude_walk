require "rails_helper"

# V2 bloco 10, defeito: falsos positivos do pedido explícito de humano (RN-34: "o pedido é a mensagem inteira pedir
# um humano, não a menção a uma pessoa"). Cada um escala na hora, sem turno da IA, um caso que a IA atenderia.
RSpec.describe Handoff::Policy, "RN-34: frases que não pedem humano (verificação do bloco 10)" do
  subject(:policy) { described_class::DEFAULT }

  {
    "pt-BR" => [ "quero conversar sobre a taxa do pix", "preciso de atendimento: meu repasse não caiu",
                 "não quero falar com atendente, só quero saber a taxa", "nao preciso de atendente humano" ],
    "en" => [ "I do not want to talk to a human" ]
  }.each do |locale, texts|
    texts.each do |text|
      it "#{locale}: #{text.inspect} não é pedido de humano" do
        expect(policy.human_request?(text, locale)).to be(false)
      end
    end
  end

  it "RN-34: pedidos curtos e diretos continuam reconhecidos" do
    [ "atendente", "um atendente por favor", "humano, por favor", "quero um humano", "falar com atendente" ].each do |text|
      expect(policy.human_request?(text, "pt-BR")).to be(true), text
    end
    [ "agent please", "human please", "a human, please" ].each do |text|
      expect(policy.human_request?(text, "en")).to be(true), text
    end
  end
end
