require "rails_helper"

RSpec.describe Outbox::RetryPolicy, "RN-43, RNF-16: política única de retentativa das saídas do outbox" do
  it "espera 1, 2, 4, 8 e 16 s sem jitter e até 25% a mais com o jitter máximo" do
    expect((1..5).map { described_class.backoff(_1, jitter: -> { 0.0 }) }).to eq([ 1, 2, 4, 8, 16 ].map(&:seconds))
    expect((1..5).map { described_class.backoff(_1, jitter: -> { 1.0 }) }).to eq([ 1.25, 2.5, 5, 10, 20 ].map(&:seconds))
  end

  it "tempo no limite: a 6ª tentativa (5ª retentativa) ainda vale; a 7ª passou do limite" do
    expect(described_class::MAX_ATTEMPTS).to eq(6)
    expect(described_class.exceeded?(6)).to be(false)
    expect(described_class.exceeded?(7)).to be(true)
  end

  it "publicação no broker e entrega ao canal usam os mesmos valores" do
    expect(Outbox::Publish::MAX_RETRIES).to eq(described_class::MAX_RETRIES)
    expect(Deliveries::Policy::MAX_ATTEMPTS).to eq(described_class::MAX_ATTEMPTS)
    expect(Deliveries::Policy.backoff(5, jitter: -> { 0.5 })).to eq(described_class.backoff(5, jitter: -> { 0.5 }))
  end
end
