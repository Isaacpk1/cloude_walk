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
end
