require "rails_helper"

RSpec.describe Outbox::Recover, "RNF-14: recuperação dos itens abertos do outbox (07, seção 6)" do
  include ActiveJob::TestHelper

  let!(:brand) { create(:brand, :infinitepay) }
  let(:now) { Time.zone.parse("2026-11-18T21:00:00Z") }
  let(:ticket) { Ticket.create!(brand:, customer: create(:customer, brand:), channel: "chat") }

  around { |example| travel_to(now) { example.run } }

  def item(**attrs)
    OutboxEvent.create!({ brand:, ticket:, event_type: "agent.event", payload: {}, trace_id: "t",
                          next_attempt_at: now - 10.seconds }.merge(attrs))
  end

  it "reoferece o item aberto cujo aviso se perdeu (web caiu depois do commit, Redis perdeu o job)" do
    lost = item

    expect(described_class.call).to eq([ lost.id ])
    expect(OutboxJob).to have_been_enqueued.with(lost.id)
  end

  it "ignora encerrados, reservados por outro worker e os que ainda não venceram a carência" do
    item(completed_at: now)
    item(lease_until: now + 10.seconds)
    item(next_attempt_at: now - 1.second)
    item(next_attempt_at: now + 5.seconds)

    expect(described_class.call).to eq([])
  end

  it "só reoferece tipos que o worker sabe processar" do
    item(event_type: "tipo.de.bloco.futuro")

    expect(described_class.call).to eq([])
  end

  it "tempo no limite: reoferece exatamente na carência de 5 s" do
    at_limit = item(next_attempt_at: now - 5.seconds)

    expect(described_class.call).to eq([ at_limit.id ])
  end

  it "reoferece uma reserva vencida (worker caiu durante a chamada)" do
    abandoned = item(lease_until: now - 1.second)

    expect(described_class.call).to eq([ abandoned.id ])
  end

  it "ordem: os mais antigos primeiro, até o limite do lote" do
    newer = item(next_attempt_at: now - 6.seconds)
    older = item(next_attempt_at: now - 60.seconds)

    expect(described_class.call(limit: 1)).to eq([ older.id ])
    expect(described_class.call(limit: 5)).to eq([ older.id, newer.id ])
  end

  it "falha de dependência: Redis fora do ar não interrompe a varredura com exceção" do
    item
    allow(OutboxJob).to receive(:perform_later).and_raise(RedisClient::CannotConnectError, "redis fora do ar")

    expect(described_class.call).to eq([])
  end
end
