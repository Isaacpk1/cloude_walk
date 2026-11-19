require "rails_helper"

# ADR-016: réplicas do scheduler ao mesmo tempo, com o Postgres de verdade, fora da transação de teste.
RSpec.describe "Scheduler concorrente", :concurrency do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:now) { Time.zone.parse("2026-11-18T21:00:10Z") }

  describe "ADR-016: dois schedulers varrem os mesmos prazos vencidos" do
    it "emitem exatamente um item por chave" do
      tickets = Array.new(5) { |i| pending_dispatch(due_at: now - 1.second, identity: "acc_corrida_#{i}") }

      results = run_concurrently(threads: 2) { Deadlines::DispatchDue.call(now:, limit: 100) }

      expect(results).to all(be_an(Array))
      expect(results.flatten.size).to eq(5)
      expect(dispatch_items.pluck(:ticket_id)).to match_array(tickets.map(&:id))
      expect(dispatch_items.pluck(:dedup_key).uniq.size).to eq(5)
      expect(AuditEvent.where(event_type: "turn.dispatch_scheduled").count).to eq(5)
    end
  end

  describe "ADR-016: SKIP LOCKED" do
    it "pula o atendimento travado por outra transação e o emite na volta seguinte" do
      ticket = pending_dispatch(due_at: now - 1.second)
      locked = Queue.new
      release = Queue.new
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Ticket.transaction do
            Ticket.lock.find(ticket.id)
            locked << true
            release.pop
          end
        end
      end
      locked.pop

      during = ActiveRecord::Base.connection_pool.with_connection { Deadlines::DispatchDue.call(now:, limit: 100) }
      release << true
      holder.join

      expect(during).to eq([])
      expect(Deadlines::DispatchDue.call(now:, limit: 100).size).to eq(1)
    end
  end
end
