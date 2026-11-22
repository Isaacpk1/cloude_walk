require "rails_helper"

RSpec.describe Turns::Policy, "ADR-020: os tempos do atendimento pela IA ficam num lugar só" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }

  it "RN-55, RN-46, RN-57: padrões da marca sem configuração própria" do
    policy = described_class.for(infinitepay)

    expect(policy).to have_attributes(ceiling: 4.seconds, turn_deadline: 20.seconds, cycle_deadline: 60.seconds,
                                      progress_notice: 15.seconds)
    expect(policy.window_for("chat")).to eq(1.5.seconds)
    expect(policy.window_for("whatsapp")).to eq(1.5.seconds)
    expect(policy.window_for("email")).to eq(0.seconds)
  end

  it "RN-49: limites de tamanho do contexto em caracteres de texto (06, parâmetros)" do
    expect(described_class.for(infinitepay)).to have_attributes(pending_chars_limit: 16_000, context_chars_limit: 32_000)
  end

  it "vale para qualquer marca até o bloco 12 ligar a configuração por marca" do
    expect(described_class.for(jim)).to eq(described_class.for(infinitepay))
  end

  describe "RN-57: texto do aviso de progresso por idioma da marca, num lugar só" do
    it "pt-BR para a InfinitePay e inglês para a JIM" do
      policy = described_class.for(infinitepay)

      expect(policy.progress_notice_text("pt-BR")).to eq("Ainda estou verificando as informações para te responder. Só mais um instante.")
      expect(policy.progress_notice_text("en")).to eq("I'm still checking the details to answer you. Just a moment more.")
    end

    it "idioma sem texto é erro, não texto padrão" do
      expect { described_class.for(infinitepay).progress_notice_text("es") }.to raise_error(KeyError)
    end
  end

  it "canal desconhecido é erro, não janela padrão" do
    expect { described_class.for(infinitepay).window_for("telegram") }.to raise_error(KeyError)
  end

  describe "ADR-020: prazo do turno" do
    let(:t0) { Time.zone.parse("2026-11-19T00:39:35Z") }
    let(:policy) { described_class.for(infinitepay) }

    it "20 s desde a abertura do turno quando cabe no teto do ciclo" do
      expect(policy.turn_deadline_at(opened_at: t0 + 21.seconds, cycle_deadline_at: t0 + 60.seconds))
        .to eq(t0 + 41.seconds)
    end

    it "nunca passa do teto do ciclo (tempo no limite)" do
      expect(policy.turn_deadline_at(opened_at: t0 + 50.seconds, cycle_deadline_at: t0 + 60.seconds))
        .to eq(t0 + 60.seconds)
      expect(policy.turn_deadline_at(opened_at: t0 + 40.seconds, cycle_deadline_at: t0 + 60.seconds))
        .to eq(t0 + 60.seconds)
    end
  end
end
