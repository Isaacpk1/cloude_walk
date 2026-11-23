require "rails_helper"

RSpec.describe Distribution::Slot, "RN-30: dois workers disputam a última vaga", :concurrency do
  it "RN-30: só um ocupa a última vaga do analista" do
    user = create(:user, status: "online", capacity: 3, active_count: 2)

    results = run_concurrently(threads: 6) { Distribution::Slot.claim!(user_id: user.id, now: Time.current) }

    expect(results).to all(satisfy { _1 == true || _1 == false })
    expect(results.count(true)).to eq(1)
    expect(user.reload.active_count).to eq(3)
  end

  it "RN-30: com a carga zero, as reservas nunca passam da capacidade" do
    user = create(:user, status: "online", capacity: 2, active_count: 0)

    results = run_concurrently(threads: 8) { Distribution::Slot.claim!(user_id: user.id, now: Time.current) }

    expect(results.count(true)).to eq(2)
    expect(user.reload.active_count).to eq(2)
  end
end
