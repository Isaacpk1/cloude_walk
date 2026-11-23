require "rails_helper"

# 07, seção 6 (ACK posterior atualiza só a publicação) e invariante 4: a falha definitiva da publicação só é
# gravada para um turno que ainda é elegível com a linha do atendimento travada. Uma resposta aplicada antes
# da trava faz o item encerrar como descarte `turno_applied`, nunca como publish_failed terminal num turno
# applied. A ordem das travas é a do resto do sistema: atendimento, depois o item do outbox.
module PublishTerminalWindowHelpers
  # Turno 1 aberto aos 1,5 s, com quatro falhas 503 e a quinta tentativa marcada para `at`, a última antes
  # do prazo do turno: a próxima falha é terminal (prazo_vencido).
  def turn_at_last_attempt(t0)
    race_ingest_at(t0, "meu repasse não caiu")
    turn = travel_to(t0 + 1.5.seconds, with_usec: true) do
      Turns::Open.call(Deadlines::DispatchDue.call(now: Time.current, limit: 10).sole).turn
    end
    stub_request(:post, BrokerHelpers::BROKER_URL).to_return(broker_response(status: 503))
    at = t0 + 1.5.seconds
    4.times { at = travel_to(at, with_usec: true) { Outbox::Publish.call(turn.event_id, jitter: -> { 0 }) }.next_attempt_at }
    stub_request(:post, BrokerHelpers::BROKER_URL).to_timeout
    [ turn, at ]
  end

  def terminal_failures(turn)
    AuditEvent.where(ticket_id: turn.ticket_id, event_type: "agent_event.publish_failed").where("data->>'retry' = 'false'")
  end
end

RSpec.describe "07, seção 6: falha terminal da publicação revalida o turno com o atendimento travado" do
  include PublishTerminalWindowHelpers

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:t0) { Time.current.utc.change(usec: 0) }

  it "resposta aplicada logo antes do registro do desfecho: descarte turno_applied, sem publish_failed terminal" do
    turn, at = turn_at_last_attempt(t0)
    allow_any_instance_of(Outbox::Publish).to receive(:finish).and_wrap_original do |m, **attrs, &blk|
      # O consumer aplica a resposta depois da última tentativa e antes de o desfecho ser gravado.
      AgentActions::Apply.call(agent_action_for(turn.reload), traceparent: AgentActionHelpers::TRACEPARENT) if attrs[:completed_at]
      m.call(**attrs, &blk)
    end

    result = travel_to(at, with_usec: true) { Outbox::Publish.call(turn.event_id, jitter: -> { 0 }) }

    expect(result.status).to eq(:discarded)
    expect(turn.reload.status).to eq("applied")
    expect(terminal_failures(turn)).to be_empty
    discarded = AuditEvent.where(ticket_id: turn.ticket_id, event_type: "agent_event.discarded").sole
    expect(discarded.data).to include("reason" => "turno_applied", "event_id" => turn.event_id)
    expect(OutboxEvent.find(turn.event_id).completed_at).to be_present
    # RN-46 (bloco 08): caso já respondido não escala.
    expect(handoff_items).to be_empty
  end

  it "turno ainda elegível: a falha terminal continua registrada como prazo_vencido" do
    turn, at = turn_at_last_attempt(t0)

    result = travel_to(at, with_usec: true) { Outbox::Publish.call(turn.event_id, jitter: -> { 0 }) }

    expect(result.status).to eq(:expired)
    expect(terminal_failures(turn).sole.data).to include("outcome" => "prazo_vencido", "origin" => "broker_indisponivel")
    # RN-46 (bloco 08): a falha definitiva escala na hora.
    expect(result.handoff_event_id).to eq(handoff_items.sole.id)
  end
end

RSpec.describe "07, seção 6: falha terminal da publicação concorre com a aplicação da resposta", :concurrency do
  include PublishTerminalWindowHelpers

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:t0) { Time.current.utc.change(usec: 0) }

  def backend_pid_waiting?(pid)
    ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}") == "Lock"
  end

  it "a publicação espera a trava do atendimento; a resposta comita antes e o item encerra como descarte" do
    turn, at = turn_at_last_attempt(t0)
    locked = Queue.new
    release = Queue.new
    # Outra conexão trava o atendimento e aplica a resposta do turno 1 (como o consumer), só comitando depois.
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          Ticket.where(id: turn.ticket_id).lock.to_a
          locked << true
          release.pop
          AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)
        end
      end
    end
    locked.pop

    pid = Queue.new
    publisher = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        pid << connection.select_value("SELECT pg_backend_pid()")
        travel_to(at, with_usec: true) { Outbox::Publish.call(turn.event_id, jitter: -> { 0 }) }
      end
    end
    publisher_pid = pid.pop
    limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    # Sem a trava, a publicação termina antes de a resposta ser aplicada.
    Thread.pass until !publisher.alive? || backend_pid_waiting?(publisher_pid) ||
                      Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit
    release << true
    holder.join
    result = publisher.value

    expect(turn.reload.status).to eq("applied")
    expect(terminal_failures(turn)).to be_empty
    expect(result.status).to eq(:discarded)
    expect(AuditEvent.where(ticket_id: turn.ticket_id, event_type: "agent_event.discarded").sole.data)
      .to include("reason" => "turno_applied")
  end
end
