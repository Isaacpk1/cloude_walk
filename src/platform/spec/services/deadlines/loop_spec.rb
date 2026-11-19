require "rails_helper"

RSpec.describe Deadlines::Loop, "ADR-016: laço do scheduler (bin/scheduler)" do
  let(:sleeps) { [] }

  def build(batch: 100, ticks: 1)
    instance = nil
    sleeper = lambda do |seconds|
      sleeps << seconds
      instance.stop! if sleeps.size >= ticks
    end
    instance = described_class.new(interval: 0.25, batch:, sleeper:)
  end

  it "a cada volta registra os prazos vencidos com o horário atual e o tamanho do lote" do
    freeze_time do
      allow(Deadlines::DispatchDue).to receive(:call).and_return([])

      build(batch: 7).run

      expect(Deadlines::DispatchDue).to have_received(:call).with(now: Time.current, limit: 7)
      expect(sleeps).to eq([ 0.25 ])
    end
  end

  it "lote cheio: volta sem dormir, para escoar o atraso" do
    allow(Deadlines::DispatchDue).to receive(:call).and_return(%w[a b], [])

    build(batch: 2).run

    expect(Deadlines::DispatchDue).to have_received(:call).twice
    expect(sleeps).to eq([ 0.25 ])
  end

  it "falha de dependência: Postgres fora do ar não mata o laço" do
    allow(Deadlines::DispatchDue).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { build(ticks: 2).run }.not_to raise_error
    expect(Deadlines::DispatchDue).to have_received(:call).twice
  end

  it "desligamento: stop! antes de começar não faz nenhuma volta" do
    allow(Deadlines::DispatchDue).to receive(:call).and_return([])
    looper = build
    looper.stop!

    looper.run

    expect(Deadlines::DispatchDue).not_to have_received(:call)
  end

  it "lê o intervalo e o lote do ambiente" do
    env = { "SCHEDULER_INTERVAL" => "0.5", "SCHEDULER_BATCH" => "50" }

    expect(described_class.from_env(env)).to have_attributes(interval: 0.5, batch: 50)
    expect(described_class.from_env({})).to have_attributes(interval: 0.25, batch: 100)
  end
end
