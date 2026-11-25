require "rails_helper"

# ADR-032: com o atendimento travado por outra conexão, o job desiste em centésimos (lock_timeout) e se reenfileira,
# em vez de ocupar a thread esperando a trava.
RSpec.describe "ADR-032: lock_timeout no OutboxJob", :concurrency do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }

  it "não espera a trava do atendimento e volta para a fila" do
    received = ingest("meu repasse não caiu")
    ticket = start_cycle(received.ticket, dispatch_due_at: Time.current)
    dispatch = create(:turn_dispatch, for_ticket: ticket)
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Ticket.transaction do
          Ticket.lock(Ticket::ROW_LOCK).find(ticket.id)
          locked << true
          release.pop
        end
      end
    end
    locked.pop
    clear_enqueued_jobs

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    OutboxJob.perform_now(dispatch.id)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    release << true
    holder.join

    expect(elapsed).to be < 2
    expect(OutboxJob).to have_been_enqueued.with(dispatch.id)
    expect(dispatch.reload.completed_at).to be_nil
    expect(ActiveRecord::Base.connection.select_value("SHOW lock_timeout")).to eq("0")
  end
end
