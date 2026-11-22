require "rails_helper"

# Corridas do bloco 08 com o Postgres de verdade, fora da transação de teste (RN-46, RN-56, invariante 4; 07,
# seção 3.4 e seção 6). A ordem é decidida sem sleep, como no commit_order_race_spec: uma conexão segura a
# trava do atendimento, as operações entram na fila da trava na ordem pedida (pg_stat_activity) e a trava é solta.
RSpec.describe "RN-46: timeout, resposta, handoff e ingestão concorrendo pelo atendimento", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:queue) { default_queue(infinitepay) }
  let(:t0) { Time.current.utc.change(usec: 0) }
  let(:identity) { "acc_infinitepay_timeout" }

  # O relógio do banco de cada operação (o consumer e o worker leem DatabaseClock depois do lock).
  before { allow(DatabaseClock).to receive(:now) { Thread.current[:test_clock] || Time.current } }

  def hold_ticket_lock(ticket_id)
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          Ticket.where(id: ticket_id).lock.to_a
          locked << true
          release.pop
        end
      end
    end
    locked.pop
    [ holder, release ]
  end

  def start_blocked(clock: nil, &operation)
    pid = Queue.new
    worker = Thread.new do
      Thread.current[:test_clock] = clock
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        pid << connection.select_value("SELECT pg_backend_pid()")
        operation.call
      end
    end
    wait_for_lock(pid.pop, worker)
    worker
  end

  def wait_for_lock(pid, worker)
    limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until ActiveRecord::Base.connection.select_value(
      "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
    ) == "Lock"
      raise "a operação terminou sem esperar a trava: #{worker.value.inspect}" unless worker.alive?
      raise "a operação não chegou à trava em 10 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

      Thread.pass
    end
  end

  # Roda as operações na ordem pedida, cada uma com o seu relógio do banco.
  def race(order, operations, clocks: {})
    ticket_id = operations.delete(:ticket_id)
    holder, release = hold_ticket_lock(ticket_id)
    threads = order.map { |name| [ name, start_blocked(clock: clocks[name], &operations.fetch(name)) ] }
    release << true
    holder.join
    threads.to_h { |name, thread| [ name, thread.value ] }
  end

  # Turno 1 aberto aos 1,5 s, ainda sem publicar.
  def open_turn_at_t0
    travel_to(t0, with_usec: true) { ingest("meu repasse não caiu", identity:) }
    travel_to(t0 + 1.5.seconds, with_usec: true) do
      Turns::Open.call(Deadlines::DispatchDue.call(now: Time.current, limit: 10).sole).turn
    end
  end

  def turn_timeout_item(turn)
    travel_to(turn.deadline_at, with_usec: true) { Deadlines::TurnTimeout.call(now: Time.current, limit: 10).sole }
  end

  describe "RN-56 / RN-46: timeout × resposta válida no mesmo instante" do
    # A resposta chegou 1 ms antes de T e esperou a trava; o worker do timeout lê o relógio já em T.
    def run(order)
      turn = open_turn_at_t0
      item = turn_timeout_item(turn)
      reply = agent_action_for(turn)
      results = travel_to(turn.deadline_at, with_usec: true) do
        race(order, { ticket_id: turn.ticket_id,
                      apply: -> { AgentActions::Apply.call(reply, traceparent: AgentActionHelpers::TRACEPARENT) },
                      expire: -> { Deadlines::Expire.call(item) } },
             clocks: { apply: turn.deadline_at - 0.001.seconds, expire: turn.deadline_at })
      end
      [ turn.reload, results ]
    end

    def never_both(turn)
      applied = AuditEvent.where(ticket_id: turn.ticket_id, event_type: "agent_action.applied").count
      expect(applied + handoff_items(turn.ticket).count).to eq(1)
    end

    it "a resposta pega a trava primeiro: aplicada; o timeout descarta (turno_applied) sem handoff" do
      turn, results = run(%i[apply expire])

      expect(results[:apply].status).to eq(:applied)
      expect(results[:expire]).to have_attributes(status: :discarded, reason: "turno_applied")
      expect(turn.status).to eq("applied")
      never_both(turn)
    end

    it "o timeout pega a trava primeiro: turno expired e handoff; a resposta é rejeitada, sem saída" do
      turn, results = run(%i[expire apply])

      expect(results[:expire].status).to eq(:expired)
      expect(results[:apply]).to have_attributes(status: :rejected, reason: "prazo_vencido")
      expect(turn.status).to eq("expired")
      expect(outbound_messages(turn.ticket)).to be_empty
      never_both(turn)
    end
  end

  describe "RN-46: dois gatilhos de handoff ao mesmo tempo (timeout e publicação recusada)" do
    it "um único handoff.requested e um único ticket.escalated, mesmo com o handoff processado duas vezes juntas" do
      stub_broker({ status: 401 })
      turn = open_turn_at_t0
      item = turn_timeout_item(turn)

      results = travel_to(turn.deadline_at - 0.5.seconds, with_usec: true) do
        run_concurrently(threads: 2) do |i|
          Thread.current[:test_clock] = turn.deadline_at
          i.zero? ? Deadlines::Expire.call(item) : Outbox::Publish.call(turn.event_id)
        end
      end

      expect(results[0].status).to eq(:expired)
      expect(results[1].status).to eq(:rejected)
      handoff = handoff_items(turn.ticket).sole
      expect(AuditEvent.where(ticket_id: turn.ticket_id, event_type: "handoff.requested").count).to eq(1)

      statuses = run_concurrently(threads: 2) { Handoff::Escalate.call(handoff.id).status }
      expect(statuses).to contain_exactly(:escalated, :already_done)
      expect(AuditEvent.where(ticket_id: turn.ticket_id, event_type: "ticket.escalated").count).to eq(1)
      expect(turn.ticket.reload.assignment_version).to eq(1)
    end
  end

  describe "07, seção 3.3: handoff × ingestão de mensagem nova" do
    def run(order)
      turn = open_turn_at_t0
      handoff = request_handoff(turn.ticket, turn: turn.turn)
      travel_to(t0 + 3.seconds, with_usec: true) do
        race(order, { ticket_id: turn.ticket_id,
                      escalate: -> { Handoff::Escalate.call(handoff) },
                      ingest: -> { ingest("é o de ontem, R$ 1.200", identity:) } })
      end
      [ turn.ticket.reload, turn.reload ]
    end

    def expect_human_without_cycle(ticket)
      expect(ticket).to have_attributes(state: "aguardando_humano", assignment_version: 1, latest_customer_seq: 2,
                                        first_pending_seq: nil, dispatch_due_at: nil, ai_deadline_at: nil)
      emitted = travel_to(t0 + 30.seconds) do
        Deadlines::Loop::REGISTRATIONS.sum { _1.constantize.call(now: Time.current, limit: 10).size }
      end
      expect(emitted).to eq(0)
    end

    it "a mensagem comita primeiro (supera o turno); o handoff encerra o ciclo que ela abriu" do
      ticket, turn = run(%i[ingest escalate])

      expect(turn.status).to eq("superseded")
      expect_human_without_cycle(ticket)
    end

    it "o handoff comita primeiro; a mensagem entra no histórico humano sem abrir ciclo da IA" do
      ticket, turn = run(%i[escalate ingest])

      expect(turn.status).to eq("expired")
      expect_human_without_cycle(ticket)
    end
  end
end
