require "rails_helper"

RSpec.describe "RN-02: dois webhooks simultâneos com o mesmo identificador", :concurrency do
  it "só um cliente fica com o identificador" do
    brand = create(:brand)
    customers = create_list(:customer, 2, brand:)

    results = run_concurrently(threads: 2) do |i|
      CustomerIdentity.create!(brand:, customer: customers[i], channel: "whatsapp", external_id: "+5511977776666")
    end

    expect(results.count { _1.is_a?(CustomerIdentity) }).to eq(1)
    expect(results.count { _1.is_a?(ActiveRecord::RecordNotUnique) }).to eq(1)
    expect(CustomerIdentity.where(brand:, external_id: "+5511977776666").count).to eq(1)
  end
end
