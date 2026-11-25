require "rails_helper"

# ADR-032: o caminho que o cliente espera não divide a fila com prazos e tarefas de fundo, e um job que encontra o
# atendimento travado devolve a thread em vez de esperar (tenta de novo em poucos centésimos).
RSpec.describe OutboxJob, "ADR-032: fila por urgência e trava sem espera" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }

  describe ".queue_for" do
    it "caminho do cliente vai para critical" do
      %w[message.received turn.dispatch agent.event delivery.requested].each do |type|
        expect(described_class.queue_for(type)).to eq("critical"), type
      end
    end

    it "prazos que levam o caso a um humano (RN-46) vão para timers" do
      %w[turn.timeout cycle.timeout progress.notice handoff.requested analyst.offline].each do |type|
        expect(described_class.queue_for(type)).to eq("timers"), type
      end
    end

    it "tarefas de fundo vão para low" do
      %w[handoff.summary sla.alert sla.breach ticket.close customer.reminder customer.inactivity].each do |type|
        expect(described_class.queue_for(type)).to eq("low"), type
      end
    end

    it "todo tipo tratado tem fila, e tipo desconhecido fica na critical (nunca some)" do
      described_class::HANDLED.each { expect(%w[critical timers low]).to include(described_class.queue_for(_1)), _1 }
      expect(described_class.queue_for("tipo.novo")).to eq("critical")
      expect(described_class.queue_for(nil)).to eq("critical")
    end
  end

  it "enfileira na fila do tipo do item" do
    item = create_item("handoff.summary")
    clear_enqueued_jobs

    described_class.perform_later(item.id)

    expect(described_class).to have_been_enqueued.with(item.id).on_queue("low")
  end

  it "atendimento travado por outro: devolve o item à fila em vez de esperar" do
    item = create_item("turn.dispatch")
    allow(Turns::Open).to receive(:call).and_raise(ActiveRecord::LockWaitTimeout)
    clear_enqueued_jobs

    described_class.perform_now(item.id)

    expect(described_class).to have_been_enqueued.with(item.id).on_queue("critical")
  end

  def create_item(type)
    ticket = ingest.ticket
    OutboxEvent.create!(brand_id: ticket.brand_id, ticket:, event_type: type, payload: {}, trace_id: "d" * 32,
                        next_attempt_at: Time.current)
  end
end
