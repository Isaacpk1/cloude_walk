require "rails_helper"

# Bloco 07, "pronto quando": a ordem de commit inversa (07, seção 3.4: "O marco é o commit da mensagem na
# plataforma: se ela foi persistida antes de a resposta ser aplicada, a resposta precisa cobri-la; se foi
# persistida depois, ela abre a continuação da conversa"). A ingestão da mensagem 2 e a aplicação da resposta
# do turno 1 concorrem pela trava do atendimento, com o Postgres de verdade, fora da transação de teste.
#
# A ordem é decidida sem sleep: uma terceira conexão segura `SELECT ... FOR UPDATE` no atendimento; a primeira
# operação começa e fica parada na trava (pg_stat_activity, wait_event_type = 'Lock'); depois a segunda; então
# a trava é solta. O Postgres entrega a linha na ordem de espera (a primeira guarda a trava da tupla e a
# segunda espera por ela), então quem chegou primeiro comita primeiro.
RSpec.describe "RN-56: ordem de commit inversa entre a mensagem 2 e a resposta do turno 1", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:t0) { Time.current.utc.change(usec: 0) }
  let(:identity) { "acc_infinitepay_ordem" }

  before { stub_broker({ status: 200 }) }

  # Segura a trava do atendimento noutra conexão até `release` receber um valor.
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

  # Começa a operação numa conexão própria e só volta quando ela estiver esperando uma trava no Postgres.
  def start_blocked(&operation)
    pid = Queue.new
    worker = Thread.new do
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

  # Turno 1 aberto e publicado aos 1,5 s (peças reais). Devolve o turno e a resposta dele.
  def turn1_with_reply
    race_ingest_at(t0, "meu repasse não caiu", identity:)
    turn = race_tick_at(t0 + 1.5.seconds).sole
    [ turn, race_reply(turn, "Seu repasse de ontem cai hoje.") ]
  end

  # As duas operações aos 3 s, na ordem pedida: `first` pega a trava antes de `second`.
  def race(first:, second:, turn:, reply:)
    operations = {
      apply: -> { AgentActions::Apply.call(reply, traceparent: AgentActionHelpers::TRACEPARENT) },
      ingest: -> { ingest("é o de ontem, R$ 1.200", identity:) }
    }
    travel_to(t0 + 3.seconds, with_usec: true) do
      holder, release = hold_ticket_lock(turn.ticket_id)
      a = start_blocked(&operations.fetch(first))
      b = start_blocked(&operations.fetch(second))
      release << true
      holder.join
      { first => a.value, second => b.value }
    end
  end

  def seqs(ticket) = Message.where(ticket_id: ticket.id).order(:seq).pluck(:seq, :direction)
  def audit_id(ticket, type) = AuditEvent.where(ticket_id: ticket.id, event_type: type).maximum(:id)

  it "aplicação comita primeiro: resposta applied com a saída; a mensagem 2 abre um ciclo novo e o turno 1 não é superado" do
    turn, reply = turn1_with_reply

    results = race(first: :apply, second: :ingest, turn:, reply:)

    ticket = turn.ticket.reload
    expect(results[:apply]).to have_attributes(status: :applied, reason: nil)
    expect(results[:ingest]).to be_created
    expect(turn.reload).to have_attributes(status: "applied", applied_event_id: reply["event_id"])
    # A saída é anterior à mensagem 2 no commit e no seq.
    expect(seqs(ticket)).to eq([ [ 1, "inbound" ], [ 2, "outbound" ], [ 3, "inbound" ] ])
    expect(audit_id(ticket, "agent_action.applied")).to be < audit_id(ticket, "message.received")
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ai_turn.superseded")).to be_empty
    expect(Delivery.where(ticket_id: ticket.id).pluck(:seq)).to eq([ 2 ])
    # Ciclo novo só com a mensagem 2 (seq 3), janela de 1,5 s a partir dela.
    expect(ticket).to have_attributes(latest_customer_seq: 3, first_pending_seq: 3, first_pending_at: t0 + 3.seconds,
                                      dispatch_due_at: t0 + 4.5.seconds)

    turn2 = race_tick_at(t0 + 4.5.seconds).sole
    expect(turn2).to have_attributes(turn: 2, context_until_seq: 3)
    expect(pending_seqs_of(turn2)).to eq([ 3 ])
    expect(turn2.context.fetch("history").map { _1["seq"] }).to eq([ 1, 2 ])
    expect(outbound_messages(ticket).count).to eq(1)
  end

  it "ingestão comita primeiro: o turno 1 é superado no commit e a resposta, rejeitada como turno_superado, sem saída" do
    turn, reply = turn1_with_reply

    results = race(first: :ingest, second: :apply, turn:, reply:)

    ticket = turn.ticket.reload
    expect(results[:ingest]).to be_created
    expect(results[:apply]).to have_attributes(status: :rejected, reason: "turno_superado")
    expect(turn.reload).to have_attributes(status: "superseded", applied_event_id: nil)
    expect(seqs(ticket)).to eq([ [ 1, "inbound" ], [ 2, "inbound" ] ])
    expect(audit_id(ticket, "ai_turn.superseded")).to be < audit_id(ticket, "agent_action.rejected")
    expect(AuditEvent.find_by!(ticket_id: ticket.id, event_type: "agent_action.rejected").data)
      .to include("reason" => "turno_superado", "turn_status" => "superseded")
    expect(outbound_messages(ticket)).to be_empty
    expect(Delivery.where(ticket_id: ticket.id)).to be_empty
    # O ciclo da mensagem 1 continua pendente; a mensagem 2 empurrou a janela até o teto de 4 s.
    expect(ticket).to have_attributes(latest_customer_seq: 2, first_pending_seq: 1, dispatch_due_at: t0 + 4.seconds)

    turn2 = race_tick_at(t0 + 4.seconds).sole
    expect(pending_seqs_of(turn2)).to eq([ 1, 2 ])
    expect(AgentActions::Apply.call(race_reply(turn2, "O de ontem cai hoje.")).status).to eq(:applied)
    expect(outbound_messages(ticket).pluck(:seq)).to eq([ 3 ])
  end
end
