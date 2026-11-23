require "rails_helper"

RSpec.describe Distribution::Slot, "RN-30: a vaga do analista" do
  let(:now) { Time.zone.parse("2026-11-24 10:00:00") }

  describe ".claim!" do
    it "RN-30: reserva a vaga de um analista online abaixo da capacidade e marca quando recebeu" do
      user = create(:user, status: "online", capacity: 2, active_count: 1)

      expect(described_class.claim!(user_id: user.id, now:)).to be(true)

      expect(user.reload).to have_attributes(active_count: 2, last_assigned_at: now)
    end

    it "RN-30: recusa quando o analista está na capacidade" do
      user = create(:user, status: "online", capacity: 1, active_count: 1)

      expect(described_class.claim!(user_id: user.id, now:)).to be(false)
      expect(user.reload.active_count).to eq(1)
    end

    it "RN-31: recusa analista em pausa ou offline" do
      %w[pausa offline].each do |status|
        user = create(:user, status:)

        expect(described_class.claim!(user_id: user.id, now:)).to be(false), status
        expect(user.reload.active_count).to eq(0)
      end
    end

    it "RF-23: recusa o bot e quem não é analista" do
      bot = create(:user, :bot, status: "online")

      expect(described_class.claim!(user_id: bot.id, now:)).to be(false)
    end
  end

  describe ".release!" do
    it "libera a vaga ocupada" do
      user = create(:user, status: "online", active_count: 2)

      expect(described_class.release!(user_id: user.id)).to be(true)
      expect(user.reload.active_count).to eq(1)
    end

    it "nunca deixa a carga abaixo de zero" do
      user = create(:user, status: "online", active_count: 0)

      expect(described_class.release!(user_id: user.id)).to be(false)
      expect(user.reload.active_count).to eq(0)
    end
  end
end
