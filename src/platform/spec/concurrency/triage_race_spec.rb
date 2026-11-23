require "rails_helper"

# Worker do message.received (Triage::OnMessage) e Turns::Open no mesmo caso novo, ao mesmo tempo, com o Postgres de
# verdade e fora da transação de teste. A trava do atendimento decide: uma triagem só, um routing.decided só, e o
# turno abre com o caso já triado (07, seção 3.1, passo 2; common11.md).
RSpec.describe "RF-12, RF-24: triagem concorrente com a abertura do turno", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:config) { triage_setup(infinitepay) }
  let(:worker_trace) { "a" * 32 }
  let(:open_trace) { "b" * 32 }

  def prepare(identity: "acc_infinitepay_000021")
    received = ingest("meu repasse não caiu", identity:, trace_id: worker_trace)
    ticket = start_cycle(received.ticket, dispatch_due_at: Time.current)
    [ received_item(received), create(:turn_dispatch, for_ticket: ticket, trace_id: open_trace), ticket ]
  end

  def audits(ticket, type) = AuditEvent.where(ticket_id: ticket.id, event_type: type)

  def expect_single_triage(ticket)
    expect(audits(ticket, "triage.classified").count).to eq(1)
    expect(audits(ticket, "routing.decided").count).to eq(1)
    expect(audits(ticket, "ticket.assigned").count).to eq(1)
    expect(ticket.reload).to have_attributes(state: "com_ia", assignee_id: config[:bot].id, category: "repasses")
    turn = AiTurn.where(ticket_id: ticket.id).sole
    expect(OutboxEvent.find(turn.event_id).payload["ticket"]).to include("state" => "com_ia")
  end

  # Segura a linha do atendimento, solta o primeiro chamador, espera ele ficar na fila da trava, solta o segundo e
  # espera de novo: o Postgres entrega a trava na ordem de chegada.
  def in_order(ticket, first, second)
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
    threads = [ first, second ].each_with_index.map do |callable, index|
      thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection { callable.call } }
      wait_for_lock_waiters(index + 1)
      thread
    end
    release << true
    holder.join
    threads.map(&:value)
  end

  def wait_for_lock_waiters(count)
    200.times do
      waiting = ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.select_value("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' " \
                                "AND datname = current_database()").to_i
      end
      return if waiting >= count

      Thread.pass
    end
    raise "as threads não chegaram à trava"
  end

  it "worker primeiro, Open depois: o worker faz a triagem e o Open só abre o turno" do
    item, dispatch, ticket = prepare

    results = in_order(ticket, -> { Triage::OnMessage.call(item.id) }, -> { Turns::Open.call(dispatch.id) })

    expect(results.map(&:status)).to eq(%i[triaged_to_ai opened])
    expect_single_triage(ticket)
    expect(audits(ticket, "routing.decided").sole.trace_id).to eq(worker_trace)
  end

  it "Open primeiro, worker depois: o Open faz a triagem e abre o turno; o worker só conclui o aviso (ja_triado)" do
    item, dispatch, ticket = prepare

    results = in_order(ticket, -> { Turns::Open.call(dispatch.id) }, -> { Triage::OnMessage.call(item.id) })

    expect(results.map(&:status)).to eq(%i[opened skipped])
    expect(results.last.reason).to eq("ja_triado")
    expect_single_triage(ticket)
    expect(audits(ticket, "routing.decided").sole.trace_id).to eq(open_trace)
    expect(item.reload.completed_at).to be_present
  end

  it "ao mesmo tempo, em vários casos: uma triagem e um turno por caso" do
    cases = Array.new(4) { |i| prepare(identity: "acc_corrida_#{i}") }

    results = run_concurrently(threads: 8) do |i|
      item, dispatch, = cases[i / 2]
      i.even? ? Triage::OnMessage.call(item.id) : Turns::Open.call(dispatch.id)
    end

    expect(results).to all(be_a(Data))
    cases.each { |(_, _, ticket)| expect_single_triage(ticket) }
  end
end
