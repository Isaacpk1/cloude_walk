require "rails_helper"

RSpec.describe Outbox::Sweeper, "RNF-14: varredura de recuperação no worker" do
  it "chama a recuperação a cada volta" do
    allow(Outbox::Recover).to receive(:call).and_return([])

    described_class.run_once

    expect(Outbox::Recover).to have_received(:call)
  end

  it "falha de dependência: Postgres fora do ar não mata o laço" do
    allow(Outbox::Recover).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { described_class.run_once }.not_to raise_error
  end
end
