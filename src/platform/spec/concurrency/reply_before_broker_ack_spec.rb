require "rails_helper"

# Bloco 07, "pronto quando": a resposta válida antes do ACK do broker (07, seção 3.4: "O turno fica `eligible`
# no commit que grava seu evento no outbox. A confirmação do broker atualiza o estado da publicação
# separadamente"; 07, seção 6: "Resposta válida chega antes de a plataforma receber o ACK do broker").
#
# O agente responde enquanto o Outbox::Publish ainda espera a resposta HTTP do broker (o evento já está no
# Kafka, mas published_at ainda não foi gravado). A resposta é aplicada pelo AgentActions::Apply numa conexão
# própria, como o consumer, durante a chamada ao broker simulado. Fora da transação de teste, porque são dois
# processos com transações próprias.
RSpec.describe "RN-56, RNF-14: resposta válida antes do ACK do broker", :concurrency do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:t0) { Time.current.utc.change(usec: 0) }
  # O processo morre no meio da chamada: fora de StandardError, nada no caminho a captura.
  let(:worker_killed) { Class.new(Exception) } # rubocop:disable Lint/InheritException

  # O broker simulado publica no Kafka e, antes de devolver a resposta HTTP, o agente já respondeu e o consumer
  # aplicou a ação. Depois, `ack` decide o que volta ao worker: a resposta do broker ou uma exceção.
  def stub_broker_with_early_reply(ack)
    @agent_results = []
    @broker_calls = []
    stub_request(:post, BrokerHelpers::BROKER_URL).to_return do |request|
      @broker_calls << request
      verify_broker_request!(request)
      turn = AiTurn.find_by!(event_id: request.headers["X-Helpdesk-Event-Id"])
      @agent_reply = race_reply(turn, "Seu repasse de ontem cai hoje.")
      @agent_results << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          AgentActions::Apply.call(@agent_reply, traceparent: AgentActionHelpers::TRACEPARENT)
        end
      end.value
      ack.call
    end
  end

  # Mensagem aos 0 s; aos 1,5 s o scheduler registra a abertura, o worker abre o turno e publica.
  def open_and_publish
    race_ingest_at(t0, "meu repasse não caiu")
    travel_to(t0 + 1.5.seconds, with_usec: true) do
      turn = Turns::Open.call(Deadlines::DispatchDue.call(now: Time.current, limit: 10).sole).turn
      [ turn, Outbox::Publish.call(turn.event_id) ]
    end
  end

  def turn_item(turn) = OutboxEvent.find(turn.event_id)
  def audits(ticket_id, *types) = AuditEvent.where(ticket_id:, event_type: types).order(:id).pluck(:event_type)

  # O que não pode mudar depois da resposta aplicada, venha a confirmação quando vier.
  def expect_single_applied_reply(turn)
    expect(turn.reload).to have_attributes(status: "applied", applied_event_id: @agent_reply["event_id"])
    expect(AiTurn.where(ticket_id: turn.ticket_id).count).to eq(1)
    expect(outbound_messages(turn.ticket).pluck(:seq)).to eq([ 2 ])
    expect(Delivery.where(ticket_id: turn.ticket_id).count).to eq(1)
    expect(turn.ticket.reload).to have_attributes(first_pending_seq: nil, dispatch_due_at: nil, ai_deadline_at: nil)
  end

  it "a resposta é aplicada; o ACK atrasado só grava a publicação, sem reverter, republicar nem reabrir o turno" do
    stub_broker_with_early_reply(-> { broker_response(status: 200) })

    turn, publish = open_and_publish

    expect(@agent_results.map(&:status)).to eq([ :applied ])
    expect(publish.status).to eq(:published)
    expect(turn_item(turn)).to have_attributes(published_at: be_present, completed_at: be_present, attempts: 1)
    expect_single_applied_reply(turn)
    # A ordem real: a ação foi aplicada antes de a plataforma registrar o ACK.
    expect(audits(turn.ticket_id, "agent_action.applied", "agent_event.published"))
      .to eq(%w[agent_action.applied agent_event.published])

    # Nada volta a sair: a recuperação não reoferece o evento, o job repetido não chama o broker e o
    # scheduler não tem abertura a registrar.
    travel_to(t0 + 30.seconds, with_usec: true) do
      expect(Outbox::Recover.call).not_to include(turn.event_id)
      OutboxJob.perform_now(turn.event_id)
      expect(Deadlines::DispatchDue.call(now: Time.current, limit: 10)).to be_empty
    end
    expect(@broker_calls.size).to eq(1)
    # A reentrega da mesma ação pelo Kafka também não muda nada.
    expect(AgentActions::Apply.call(@agent_reply).status).to eq(:duplicate)
    expect_single_applied_reply(turn)
  end

  it "ACK perdido por timeout: a retentativa da recuperação descarta o evento do turno applied e audita, sem reenviar" do
    stub_broker_with_early_reply(-> { raise Net::ReadTimeout })

    turn, publish = open_and_publish

    expect(@agent_results.map(&:status)).to eq([ :applied ])
    expect(publish.status).to eq(:retry_scheduled)
    expect(turn_item(turn)).to have_attributes(published_at: nil, completed_at: nil)
    expect_single_applied_reply(turn) # a falha da confirmação não reverte a resposta

    # O despertador da retentativa se perdeu: a recuperação reoferece o item depois da carência.
    travel_to(turn_item(turn).next_attempt_at + Outbox::Recover::GRACE, with_usec: true) do
      clear_enqueued_jobs
      expect(Outbox::Recover.call).to include(turn.event_id)
      OutboxJob.perform_now(turn.event_id)
    end

    expect(@broker_calls.size).to eq(1) # 07, seção 6: o worker revalida o turno e encerra o item obsoleto
    expect(turn_item(turn)).to have_attributes(published_at: nil, completed_at: be_present, attempts: 2)
    expect(AuditEvent.where(ticket_id: turn.ticket_id, event_type: "agent_event.discarded").sole.data)
      .to include("event_id" => turn.event_id, "reason" => "turno_applied", "turn" => 1)
    expect_single_applied_reply(turn)
    travel_to(t0 + 60.seconds, with_usec: true) { expect(Outbox::Recover.call).not_to include(turn.event_id) }
  end

  it "ACK perdido de vez (o worker cai com a reserva): a recuperação só reoferece depois da reserva e o item é descartado" do
    stub_broker_with_early_reply(-> { raise worker_killed, "worker morto antes da resposta do broker" })

    expect { open_and_publish }.to raise_error(worker_killed)
    turn = AiTurn.find_by!(ticket_id: Ticket.sole.id)

    expect(@agent_results.map(&:status)).to eq([ :applied ])
    item = turn_item(turn)
    expect(item).to have_attributes(published_at: nil, completed_at: nil, attempts: 1, lease_until: be_present)

    travel_to(item.lease_until - 1.second, with_usec: true) { expect(Outbox::Recover.call).not_to include(turn.event_id) }
    travel_to(item.lease_until + 1.second, with_usec: true) do
      expect(Outbox::Recover.call).to include(turn.event_id)
      OutboxJob.perform_now(turn.event_id)
    end

    expect(@broker_calls.size).to eq(1)
    expect(turn_item(turn)).to have_attributes(published_at: nil, completed_at: be_present)
    expect(AuditEvent.where(ticket_id: turn.ticket_id, event_type: "agent_event.discarded").sole.data["reason"])
      .to eq("turno_applied")
    expect_single_applied_reply(turn)
  end

  describe "RN-46, RN-56: ACK perdido na última tentativa que o prazo do turno permite" do
    # 1, 2, 4 e 8 s sem jitter: a 5ª tentativa sai aos 16,5 s; a próxima seria aos 32,5 s, depois do prazo do
    # turno (21,5 s). O evento chega ao Kafka, o agente responde, mas a resposta HTTP do broker se perde.
    it "não registra falha definitiva da publicação de um turno já applied: encerra o item como descarte auditado" do
      race_ingest_at(t0, "meu repasse não caiu")
      turn = travel_to(t0 + 1.5.seconds, with_usec: true) do
        Turns::Open.call(Deadlines::DispatchDue.call(now: Time.current, limit: 10).sole).turn
      end
      # As 4 primeiras tentativas falham no broker antes do Kafka (503), sem resposta do agente.
      stub_request(:post, BrokerHelpers::BROKER_URL).to_return(broker_response(status: 503))
      at = t0 + 1.5.seconds
      4.times do
        result = travel_to(at, with_usec: true) { Outbox::Publish.call(turn.event_id, jitter: -> { 0 }) }
        expect(result.status).to eq(:retry_scheduled)
        at = result.next_attempt_at
      end
      expect(at).to eq(t0 + 16.5.seconds)

      WebMock.reset!
      stub_broker_with_early_reply(-> { raise Net::ReadTimeout })
      result = travel_to(at, with_usec: true) { Outbox::Publish.call(turn.event_id, jitter: -> { 0 }) }

      expect(@agent_results.map(&:status)).to eq([ :applied ])
      expect(result.status).to eq(:discarded)
      expect(AuditEvent.where(ticket_id: turn.ticket_id, event_type: "agent_event.publish_failed")
                       .where("data->>'retry' = 'false'")).to be_empty
      expect(AuditEvent.where(ticket_id: turn.ticket_id, event_type: "agent_event.discarded").sole.data)
        .to include("reason" => "turno_applied", "attempt" => 5)
      expect(turn_item(turn)).to have_attributes(published_at: nil, completed_at: be_present)
      expect_single_applied_reply(turn)
    end
  end
end
