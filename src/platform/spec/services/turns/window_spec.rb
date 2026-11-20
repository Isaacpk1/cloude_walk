require "rails_helper"

RSpec.describe Turns::Window do
  let(:now) { Time.utc(2026, 11, 18, 21, 0, 0) }

  describe "ADR-020: os tempos vêm da política da marca" do
    it "usa a janela, o teto e o prazo do ciclo da política recebida (configuração do bloco 12)" do
      custom = Turns::Policy::DEFAULT.with(windows: { "chat" => 3.seconds }, ceiling: 10.seconds, cycle_deadline: 90.seconds)

      expect(described_class.dispatch_due_at(channel: "chat", now:, first_pending_at: now, policy: custom)).to eq(now + 3.seconds)
      expect(described_class.dispatch_due_at(channel: "chat", now: now + 9.seconds, first_pending_at: now, policy: custom))
        .to eq(now + 10.seconds)
      expect(described_class.ai_deadline_at(first_pending_at: now, policy: custom)).to eq(now + 90.seconds)
    end
  end

  describe "RN-55: dispatch_due_at = min(agora + janela, first_pending_at + 4 s)" do
    it "primeira mensagem: fim da janela do canal" do
      expect(described_class.dispatch_due_at(channel: "chat", now:, first_pending_at: now)).to eq(now + 1.5.seconds)
    end

    it "mensagem aos 3 s com a primeira pendente: teto aos 4 s (tempo no limite)" do
      due = described_class.dispatch_due_at(channel: "chat", now: now + 3.seconds, first_pending_at: now)

      expect(due).to eq(now + 4.seconds)
    end

    it "mensagem aos 2,5 s: a janela ainda vence antes do teto (exatamente 4 s)" do
      due = described_class.dispatch_due_at(channel: "whatsapp", now: now + 2.5.seconds, first_pending_at: now)

      expect(due).to eq(now + 4.seconds)
    end

    it "mensagem aos 2 s: a janela vence antes do teto" do
      due = described_class.dispatch_due_at(channel: "chat", now: now + 2.seconds, first_pending_at: now)

      expect(due).to eq(now + 3.5.seconds)
    end

    it "e-mail: elegível na hora" do
      expect(described_class.dispatch_due_at(channel: "email", now:, first_pending_at: now)).to eq(now)
    end

    it "ciclo antigo (mensagem depois do teto): vence na gravação, nunca antes dela" do
      due = described_class.dispatch_due_at(channel: "chat", now: now + 10.seconds, first_pending_at: now)

      # O teto já passou: o turno sai na próxima volta do scheduler. O prazo não fica no passado, para o
      # delay_ms do scheduler medir o atraso real (E1) e não o tempo desde o teto antigo.
      expect(due).to eq(now + 10.seconds)
    end
  end

  describe "RN-46: prazo da IA no ciclo" do
    it "ADR-020: teto do ciclo de 60 s desde a primeira mensagem pendente" do
      expect(described_class.ai_deadline_at(first_pending_at: now)).to eq(now + 60.seconds)
    end
  end
end
