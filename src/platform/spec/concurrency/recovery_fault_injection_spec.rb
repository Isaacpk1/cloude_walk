require "rails_helper"

# Bloco 09, "pronto quando": mensagens confirmadas continuam no histórico após a falha, eventos antigos não
# reativam a IA e a confirmação perdida não gera uma segunda resposta visível (RF-34 + RF-35; RNF-14 a RNF-17;
# 07, seção 6). Cada falha é injetada no caminho real: a ingestão, o scheduler (Deadlines::DispatchDue), o
# worker (OutboxJob → Turns::Open, Outbox::Publish, Deliveries::Send), o consumer (AgentActions::Apply) e a
# recuperação (Outbox::Recover). Broker e provedor do chat são simulados por WebMock no formato combinado.
#
# Uma queda de processo é uma exceção fora de StandardError: nada no caminho a captura, como um kill no meio
# da chamada. Fora da transação de teste, porque a recuperação concorre com outros processos.
RSpec.describe "RNF-14, RNF-17, RF-34 + RF-35: injeção de falhas e recuperação (07, seção 6)", :concurrency do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  # O consumer julga pelo relógio do banco, que o travel_to não move: o cenário começa 10 s atrás.
  let(:t0) { Time.current.utc.change(usec: 0) - 10.seconds }
  let(:process_killed) { Class.new(Exception) } # rubocop:disable Lint/InheritException

  def at(time, &) = travel_to(time, with_usec: true, &)
  def audits(type, ticket) = AuditEvent.where(ticket_id: ticket.id, event_type: type).order(:id)
  def recovered_ids(ticket) = audits("outbox.recovered", ticket).map { _1.data["outbox_event_id"] }

  # RNF-14: o que já estava confirmado (mensagens com seq, auditoria só de inserção) antes da falha.
  def history(ticket)
    { messages: Message.where(ticket_id: ticket.id).order(:seq).pluck(:id, :seq, :direction, :body, :external_id),
      audits: AuditEvent.where(ticket_id: ticket.id).order(:id).pluck(:id, :event_type, :data),
      latest_customer_seq: ticket.reload.latest_customer_seq }
  end

  def expect_history_kept(ticket, before)
    after = history(ticket)
    expect(after[:messages].first(before[:messages].size)).to eq(before[:messages])
    expect(after[:audits].first(before[:audits].size)).to eq(before[:audits])
    expect(after[:latest_customer_seq]).to eq(before[:latest_customer_seq])
    expect(Message.where(ticket_id: ticket.id).pluck(:seq)).to eq((1..after[:messages].size).to_a)
  end

  def open_turn_at(time)
    at(time) { Turns::Open.call(Deadlines::DispatchDue.call(now: Time.current, limit: 10).sole).turn }
  end

  describe "ADR-016, RNF-14: queda depois do commit da ação do scheduler" do
    it "o scheduler morre antes de enfileirar: a recuperação reoferece após a carência e o turno abre uma vez, com o prazo original" do
      ticket = at(t0) { customer_message.ticket }
      clear_enqueued_jobs # o aviso da ingestão (message.received) não é o foco
      original = ticket.reload.slice(:dispatch_due_at, :ai_deadline_at, :first_pending_seq)
      before = history(ticket)

      at(original[:dispatch_due_at]) do
        allow(OutboxJob).to receive(:perform_later).and_raise(process_killed)
        expect { Deadlines::DispatchDue.call(now: Time.current, limit: 10) }.to raise_error(process_killed)
      end
      allow(OutboxJob).to receive(:perform_later).and_call_original
      item = OutboxEvent.find_by!(ticket_id: ticket.id, event_type: "turn.dispatch")
      expect(item).to have_attributes(completed_at: nil, next_attempt_at: original[:dispatch_due_at])
      expect(enqueued_jobs).to be_empty

      # O scheduler volta: a chave da ação já está no outbox, nada é emitido de novo.
      at(original[:dispatch_due_at] + 1.second) { expect(Deadlines::DispatchDue.call(now: Time.current, limit: 10)).to be_empty }
      at(item.next_attempt_at + Outbox::Recover::GRACE - 0.001.seconds) { expect(Outbox::Recover.call).not_to include(item.id) }

      recovered_at = item.next_attempt_at + Outbox::Recover::GRACE
      at(recovered_at) do
        # Duas réplicas da varredura e dois workers com o mesmo aviso.
        expect(run_concurrently(threads: 2) { Outbox::Recover.call }.flatten.count(item.id)).to eq(1)
        expect(run_concurrently(threads: 2) { OutboxJob.perform_now(item.id) }).to all(satisfy { !_1.is_a?(Exception) })
      end

      turn = AiTurn.where(ticket_id: ticket.id).sole
      expect(turn).to have_attributes(status: "eligible", context_until_seq: 1)
      expect(turn.deadline_at).to eq([ recovered_at + 20.seconds, original[:ai_deadline_at] ].min)
      expect(ticket.reload).to have_attributes(ai_deadline_at: original[:ai_deadline_at], first_pending_seq: original[:first_pending_seq],
                                               dispatch_due_at: nil)
      expect(item.reload.completed_at).to be_present
      expect(item.payload["dispatch_due_at"]).to eq(original[:dispatch_due_at].utc.iso8601(3))
      expect(recovered_ids(ticket).count(item.id)).to eq(1)
      expect(audits("ai_turn.opened", ticket).count).to eq(1)
      expect_history_kept(ticket, before)
    end

    it "o Redis perde o job da ação: a recuperação reoferece e o turno abre uma vez" do
      ticket = at(t0) { customer_message.ticket }
      due = ticket.reload.dispatch_due_at
      at(due) { Deadlines::DispatchDue.call(now: Time.current, limit: 10) }
      item = OutboxEvent.find_by!(ticket_id: ticket.id, event_type: "turn.dispatch")
      clear_enqueued_jobs # o Redis perdeu o job

      at(due + Outbox::Recover::GRACE) do
        expect(Outbox::Recover.call).to include(item.id)
        2.times { OutboxJob.perform_now(item.id) }
      end

      expect(AiTurn.where(ticket_id: ticket.id).count).to eq(1)
      expect(OutboxEvent.where(ticket_id: ticket.id, event_type: "agent.event").count).to eq(1)
    end
  end

  describe "RNF-15: o provedor aceita a resposta e a confirmação se perde" do
    # O channels-mock persiste o efeito e a confirmação juntos e deduplica pelo delivery_id (07, seção 3.2):
    # `inbox` é o que o cliente vê. `first` decide o que volta na primeira chamada de cada delivery_id.
    def stub_provider(first)
      @inbox = {}
      @provider_calls = []
      stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT).to_return do |request|
        @provider_calls << request
        key = request.headers["Idempotency-Key"]
        replayed = @inbox.key?(key)
        @inbox[key] ||= { message_id: "chat_out_#{@inbox.size + 1}", body: request.body }
        next channel_response(status: 200, message_id: @inbox[key][:message_id], replayed:) if replayed

        case first
        when :gateway then { status: 504, body: JSON.generate(error: "confirmacao_perdida"), headers: { "Content-Type" => "application/json" } }
        when :killed then raise process_killed, "worker morto depois de o provedor aceitar"
        end
      end
    end

    # Resposta da IA aplicada pelo consumer: a saída fica pendente no outbox (delivery.requested).
    def applied_reply
      ticket = at(t0) { customer_message.ticket }
      turn = open_turn_at(t0 + 1.5.seconds)
      result = at(t0 + 3.seconds) { AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT) }
      expect(result.status).to eq(:applied)
      clear_enqueued_jobs
      [ ticket, Delivery.where(ticket_id: ticket.id).sole ]
    end

    def expect_single_visible_reply(ticket, delivery)
      expect(@inbox.size).to eq(1)
      expect(@provider_calls.map { _1.headers["Idempotency-Key"] }.uniq).to eq([ delivery.delivery_id ])
      expect(@provider_calls.map(&:body).uniq.size).to eq(1)
      expect(outbound_messages(ticket).count).to eq(1)
      expect(delivery.reload).to have_attributes(status: "delivered", provider_message_id: "chat_out_1")
      expect(audits("delivery.delivered", ticket).sole.data).to include("replayed" => true)
    end

    it "504 depois de gravar o efeito e o Redis perde a retentativa: a recuperação repete com o mesmo delivery_id e não há segunda resposta" do
      stub_provider(:gateway)
      ticket, delivery = applied_reply
      before = history(ticket)
      item = delivery_item(delivery)

      at(t0 + 3.5.seconds) { OutboxJob.perform_now(item.id) }
      expect(delivery.reload).to have_attributes(status: "sending", attempts: 1)
      clear_enqueued_jobs # o despertador da retentativa se perdeu

      at(item.reload.next_attempt_at + Outbox::Recover::GRACE) do
        expect(Outbox::Recover.call).to include(item.id)
        OutboxJob.perform_now(item.id)
        OutboxJob.perform_now(item.id) # aviso repetido
      end

      expect(@provider_calls.size).to eq(2)
      expect_single_visible_reply(ticket, delivery)
      expect(delivery.attempts).to eq(2)
      expect_history_kept(ticket, before)
    end

    it "o worker cai depois de o provedor aceitar: a recuperação só retoma após a reserva e não há segunda resposta" do
      stub_provider(:killed)
      ticket, delivery = applied_reply
      before = history(ticket)
      item = delivery_item(delivery)

      at(t0 + 3.5.seconds) { expect { OutboxJob.perform_now(item.id) }.to raise_error(process_killed) }
      lease = delivery.reload.lease_until
      expect(delivery).to have_attributes(status: "sending", attempts: 1)
      expect(@inbox.size).to eq(1)

      at(lease + Outbox::Recover::GRACE - 0.001.seconds) { expect(Outbox::Recover.call).not_to include(item.id) }
      at(lease + Outbox::Recover::GRACE) do
        expect(Outbox::Recover.call).to include(item.id)
        OutboxJob.perform_now(item.id)
      end

      expect_single_visible_reply(ticket, delivery)
      expect_history_kept(ticket, before)
    end
  end

  describe "RNF-14, RNF-15: o worker cai no meio da publicação (depois da reserva, antes do resultado)" do
    def stub_broker_killing_first
      @broker_calls = []
      stub_request(:post, BrokerHelpers::BROKER_URL).to_return do |request|
        @broker_calls << request
        raise process_killed, "worker morto durante a chamada ao broker" if @broker_calls.size == 1

        broker_response(status: 200)
      end
    end

    it "a recuperação retoma depois da reserva, dentro do prazo do turno, com o mesmo event_id e corpo, e publica uma vez" do
      stub_broker_killing_first
      ticket = at(t0) { customer_message.ticket }
      turn = open_turn_at(t0 + 1.5.seconds)
      before = history(ticket)

      at(t0 + 1.5.seconds) { expect { OutboxJob.perform_now(turn.event_id) }.to raise_error(process_killed) }
      item = OutboxEvent.find(turn.event_id)
      expect(item).to have_attributes(completed_at: nil, attempts: 1)
      expect(item.lease_until).to be < turn.deadline_at

      at(item.lease_until - 0.001.seconds) { expect(Outbox::Recover.call).not_to include(item.id) }
      at(item.lease_until + 0.001.seconds) do
        expect(Outbox::Recover.call).to include(item.id)
        2.times { OutboxJob.perform_now(item.id) }
      end

      expect(@broker_calls.size).to eq(2)
      expect(@broker_calls.map { _1.headers["X-Helpdesk-Event-Id"] }.uniq).to eq([ turn.event_id ])
      expect(@broker_calls.map(&:body).uniq.size).to eq(1)
      expect(item.reload).to have_attributes(attempts: 2, published_at: be_present, completed_at: be_present)
      expect(audits("agent_event.published", ticket).count).to eq(1)
      expect(AiTurn.where(ticket_id: ticket.id).count).to eq(1)
      expect_history_kept(ticket, before)
    end

    it "se a recuperação só chega depois do prazo do turno, o item é encerrado como obsoleto, sem republicar" do
      stub_broker_killing_first
      ticket = at(t0) { customer_message.ticket }
      turn = open_turn_at(t0 + 1.5.seconds)
      at(t0 + 1.5.seconds) { expect { OutboxJob.perform_now(turn.event_id) }.to raise_error(process_killed) }

      at(turn.deadline_at) { expect(Outbox::Recover.call).not_to include(turn.event_id) }

      expect(@broker_calls.size).to eq(1)
      expect(audits("outbox.closed_obsolete", ticket).sole.data).to include("outbox_event_id" => turn.event_id,
                                                                           "reason" => "prazo_vencido")
      expect(AiTurn.where(ticket_id: ticket.id).count).to eq(1)
    end
  end

  describe "RN-38, RNF-17: o broker volta com backlog depois de o caso mudar" do
    # O broker cai na primeira publicação (503): a retentativa fica agendada e o caso muda antes de o broker voltar.
    def turn_waiting_broker
      stub_broker({ status: 503 }, { status: 200 })
      ticket = at(t0) { customer_message.ticket }
      turn = open_turn_at(t0 + 1.5.seconds)
      at(t0 + 1.5.seconds) { expect(Outbox::Publish.call(turn.event_id, jitter: -> { 0.0 }).status).to eq(:retry_scheduled) }
      [ ticket, turn ]
    end

    def expect_ai_not_reactivated(ticket, turns: 1)
      expect(broker_requests.size).to eq(1) # só a tentativa que falhou
      expect(AiTurn.where(ticket_id: ticket.id).count).to eq(turns)
      expect(audits("agent_action.applied", ticket)).to be_empty
      expect(outbound_messages(ticket)).to be_empty
    end

    it "mensagem nova: o despertador da retentativa encontra o turno superado e não publica" do
      ticket, turn = turn_waiting_broker
      at(t0 + 2.seconds) { customer_message("é o de ontem, R$ 1.200") }
      before = history(ticket)

      at(t0 + 2.5.seconds) { OutboxJob.perform_now(turn.event_id) }

      expect(audits("agent_event.discarded", ticket).sole.data["reason"]).to eq("turno_superseded")
      expect_ai_not_reactivated(ticket)
      expect(turn.reload.status).to eq("superseded")
      expect_history_kept(ticket, before)
    end

    it "turno expirado: o Redis perdeu a retentativa e a recuperação encerra o evento como obsoleto" do
      ticket, turn = turn_waiting_broker
      clear_enqueued_jobs
      before = history(ticket)

      at(turn.deadline_at + 1.second) do
        expect(Outbox::Recover.call).not_to include(turn.event_id)
        OutboxJob.perform_now(turn.event_id) # um despertador atrasado que reaparece
      end

      expect(audits("outbox.closed_obsolete", ticket).sole.data).to include("reason" => "prazo_vencido", "event_type" => "agent.event")
      expect_ai_not_reactivated(ticket)
      expect_history_kept(ticket, before)
    end

    # Sem o Handoff::Escalate do bloco 08 neste branch: a escalação é a mudança direta do handoff mínimo combinado
    # (estado, nova atribuição, turno elegível expirado, ciclo da IA encerrado).
    it "caso escalado: o evento antigo é encerrado, a resposta atrasada do agente é rejeitada e nenhum turno abre" do
      ticket, turn = turn_waiting_broker
      at(t0 + 4.seconds) do
        ticket.reload.update_columns(state: "aguardando_humano", assignment_version: ticket.assignment_version + 1,
                                     first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil)
        turn.update_columns(status: "expired")
      end
      clear_enqueued_jobs
      before = history(ticket)

      at(t0 + 8.seconds) do
        expect(Outbox::Recover.call).not_to include(turn.event_id)
        expect(Deadlines::DispatchDue.call(now: Time.current, limit: 10)).to be_empty
        late = AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)
        expect(late.status).to eq(:rejected)
      end

      expect(audits("outbox.closed_obsolete", ticket).sole.data["reason"]).to eq("turno_expired")
      expect_ai_not_reactivated(ticket)
      expect(ticket.reload.state).to eq("aguardando_humano")
      expect_history_kept(ticket, before)
    end
  end

  describe "concorrência da recuperação" do
    it "atendimento travado por outro processo: a varredura não espera e decide o item na volta seguinte" do
      ticket = at(t0) { customer_message.ticket }
      locked = Queue.new
      release = Queue.new
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            Ticket.lock.find(ticket.id)
            locked << true
            release.pop
          end
        end
      end
      locked.pop

      at(t0 + 10.seconds) { expect(Outbox::Recover.call).to eq([]) }
      release << true
      holder.join

      at(t0 + 10.seconds) { expect(Outbox::Recover.call).not_to be_empty }
    end
  end
end
