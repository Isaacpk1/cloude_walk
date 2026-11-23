require "rails_helper"

RSpec.describe Availability::Set, "RF-27: disponibilidade do analista" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:now) { Time.zone.parse("2026-11-24 10:00:00") }
  let(:analyst) { create(:user, status: "online").tap { TeamMembership.create!(user: _1, team: create(:team, brand: infinitepay)) } }

  it "RF-27: muda o status e marca quando mudou" do
    described_class.call(user: analyst, status: "offline", now:)

    expect(analyst.reload).to have_attributes(status: "offline", status_changed_at: now)
  end

  it "RN-31: não mexe no status_changed_at quando o status não muda (desde quando está offline)" do
    described_class.call(user: analyst, status: "offline", now:)
    described_class.call(user: analyst, status: "offline", now: now + 5.minutes)

    expect(analyst.reload.status_changed_at).to eq(now)
    expect(AuditEvent.where(event_type: "analyst.availability_changed").count).to eq(1)
  end

  it "RF-27: recusa status que não existe" do
    expect { described_class.call(user: analyst, status: "ocupado", now:) }.to raise_error(ArgumentError, /ocupado/)
    expect(analyst.reload.status).to eq("online")
  end

  it "RF-54: audita em cada marca das equipes do analista, sem atendimento" do
    TeamMembership.create!(user: analyst, team: create(:team, brand: jim))

    described_class.call(user: analyst, status: "pausa", now:)

    audits = AuditEvent.where(event_type: "analyst.availability_changed")
    expect(audits.pluck(:brand_id)).to match_array([ infinitepay.id, jim.id ])
    expect(audits).to all(have_attributes(ticket_id: nil, actor_type: "user",
                                          data: a_hash_including("user_id" => analyst.id, "from" => "online", "to" => "pausa")))
  end

  it "voltar a ficar online registra a nova hora" do
    described_class.call(user: analyst, status: "offline", now:)
    described_class.call(user: analyst, status: "online", now: now + 3.minutes)

    expect(analyst.reload).to have_attributes(status: "online", status_changed_at: now + 3.minutes)
  end
end
