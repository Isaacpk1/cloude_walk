require "rails_helper"

RSpec.describe Ticket do
  let(:brand) { create(:brand, :infinitepay) }
  let(:customer) { create(:customer, brand:) }

  def ticket(state: "novo", assignee: nil) = described_class.new(brand:, customer:, channel: "chat", state:, assignee:)

  describe "07, seção 3.3: o caso está com a IA (#with_ai?)" do
    it "sem responsável, fora dos estados humanos, está com a IA" do
      %w[novo em_triagem com_ia aguardando_cliente].each do |state|
        expect(ticket(state:)).to be_with_ai, state
      end
    end

    it "nos estados humanos ou terminais não está com a IA" do
      %w[aguardando_humano com_analista resolvido fechado].each do |state|
        expect(ticket(state:)).not_to be_with_ai, state
      end
    end

    it "com responsável humano não está com a IA; com o bot, está" do
      expect(ticket(assignee: build(:user))).not_to be_with_ai
      expect(ticket(assignee: build(:user, :bot))).to be_with_ai
    end
  end

  describe "RN-55, RF-33: versão do contexto (#bump_context_version!)" do
    let(:saved) { described_class.create!(brand:, customer:, channel: "chat", state: "novo") }

    it "começa em 0 e sobe 1 no banco, devolvendo o novo valor" do
      expect(saved.context_version).to eq(0)

      expect(saved.bump_context_version!).to eq(1)
      expect(saved.bump_context_version!).to eq(2)
      expect(saved.reload.context_version).to eq(2)
    end

    it "soma ao valor do banco, não ao valor em memória (cópia desatualizada não perde incremento)" do
      stale = described_class.find(saved.id)
      saved.bump_context_version!
      # Outra gravação sobe o lock_version: um update_columns da cópia antiga filtraria por ele e mudaria 0 linhas.
      saved.update!(latest_customer_seq: 5)
      expect(saved.reload.lock_version).to be > stale.lock_version

      expect(stale.bump_context_version!).to eq(2)
      expect(saved.reload.context_version).to eq(2)
    end

    it "deixa o atributo em memória igual ao banco e sem alteração pendente" do
      saved.bump_context_version!

      expect(saved.context_version).to eq(1)
      expect(saved).not_to be_changed
      saved.update!(latest_customer_seq: 1)
      expect(saved.reload.context_version).to eq(1)
    end

    it "invariante 6: atendimento inexistente (ou de outra marca) é erro" do
      other = described_class.new(id: saved.id, brand: create(:brand, :jim), customer:, channel: "chat")

      expect { other.bump_context_version! }.to raise_error(ActiveRecord::RecordNotFound)
      expect(saved.reload.context_version).to eq(0)
    end
  end
end
