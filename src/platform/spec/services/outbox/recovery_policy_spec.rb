require "rails_helper"

RSpec.describe Outbox::Recover, "RNF-17, RF-34 + RF-35: política de recuperação dos itens abertos (07, seção 6)" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-21T10:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  def audits(type) = AuditEvent.where(event_type: type).order(:id)

  # Turno aberto e publicado sem confirmação: o item do evento fica aberto e o job se perdeu.
  def lost_agent_event(text = "meu repasse não caiu", **)
    turn = opened_turn(text, **)
    OutboxEvent.find(turn.event_id).tap { _1.update_columns(attempts: 1, next_attempt_at: Time.current) }
  end

  # O aviso da ingestão (message.received) também fica aberto e seria reoferecido; aqui o foco é o item do teste.
  def after_grace
    OutboxEvent.where(event_type: "message.received").update_all(completed_at: Time.current)
    travel(described_class::GRACE)
  end

  describe "reoferece o que ainda vale" do
    it "RNF-14: reoferece o evento do turno ainda elegível, audita outbox.recovered e acorda o worker" do
      item = lost_agent_event
      after_grace
      clear_enqueued_jobs

      expect(described_class.call).to eq([ item.id ])
      expect(OutboxJob).to have_been_enqueued.with(item.id)
      expect(item.reload).to have_attributes(completed_at: nil, next_attempt_at: Time.current)
      expect(audits("outbox.recovered").sole).to have_attributes(brand_id: infinitepay.id, ticket_id: item.ticket_id,
                                                                  trace_id: item.trace_id)
      expect(audits("outbox.recovered").sole.data).to include("outbox_event_id" => item.id, "event_type" => "agent.event",
                                                              "attempts" => 1)
    end

    OutboxJob::HANDLED.each do |type|
      it "reoferece qualquer tipo que o worker trata: #{type}" do
        ticket = ingest.ticket
        OutboxEvent.where(event_type: "message.received").update_all(completed_at: start)
        payload = { "ticket_id" => ticket.id, "assignment_version" => 0, "cover_until_seq" => ticket.latest_customer_seq }
        item = OutboxEvent.create!(brand: infinitepay, ticket:, event_type: type, payload:,
                                   trace_id: "t", next_attempt_at: start - 10.seconds)

        expect(described_class.call).to eq([ item.id ])
        expect(audits("outbox.recovered").map { _1.data["outbox_event_id"] }).to include(item.id)
      end
    end

    it "repetição: a volta seguinte não reoferece de novo antes da carência; depois dela, sim (job perdido outra vez)" do
      item = lost_agent_event
      after_grace
      described_class.call
      clear_enqueued_jobs

      recovered_at = item.reload.next_attempt_at
      travel_to(recovered_at + described_class::GRACE - 0.001.seconds, with_usec: true)
      expect(described_class.call).to eq([])
      travel_to(recovered_at + described_class::GRACE, with_usec: true)
      expect(described_class.call).to eq([ item.id ])
      expect(audits("outbox.recovered").count).to eq(2)
    end

    it "tipos dos blocos 08 e 09 com o ciclo atual são reoferecidos; de ciclo anterior, encerrados" do
      stub_const("OutboxJob::HANDLED", OutboxJob::HANDLED + [ "progress.notice" ])
      ticket = start_cycle(ingest.ticket)
      OutboxEvent.where(event_type: "message.received").update_all(completed_at: start)
      current = OutboxEvent.create!(brand: infinitepay, ticket:, event_type: "progress.notice", trace_id: "t",
                                    next_attempt_at: start - 10.seconds,
                                    payload: { "ticket_id" => ticket.id, "first_pending_seq" => ticket.first_pending_seq })
      old = OutboxEvent.create!(brand: infinitepay, ticket:, event_type: "progress.notice", trace_id: "t",
                                next_attempt_at: start - 10.seconds,
                                payload: { "ticket_id" => ticket.id, "first_pending_seq" => ticket.first_pending_seq - 1 })

      expect(described_class.call).to eq([ current.id ])
      expect(old.reload.completed_at).to eq(start)
      expect(audits("outbox.closed_obsolete").sole.data).to include("outbox_event_id" => old.id, "reason" => "ciclo_anterior",
                                                                    "event_type" => "progress.notice")
    end

    it "a entrega ao canal nunca é encerrada pela recuperação (a ordem e a conciliação são do Deliveries::Send)" do
      create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock")
      delivery = requested_delivery(customer_message.ticket)
      item = delivery_item(delivery)
      delivery.ticket.update_columns(state: "aguardando_humano")
      item.update_columns(next_attempt_at: start - 10.seconds)

      expect(described_class.call).to eq([ item.id ])
    end
  end

  describe "encerra os obsoletos sem nova ação (outbox.closed_obsolete)" do
    def expect_closed(item, reason)
      expect(described_class.call).to eq([])
      expect(enqueued_jobs).to be_empty
      expect(item.reload).to have_attributes(completed_at: Time.current, lease_until: nil, last_error: "obsoleto: #{reason}")
      expect(audits("outbox.closed_obsolete").sole).to have_attributes(ticket_id: item.ticket_id, trace_id: item.trace_id)
      expect(audits("outbox.closed_obsolete").sole.data).to include("outbox_event_id" => item.id, "event_type" => item.event_type,
                                                                    "reason" => reason, "attempts" => item.attempts)
      expect(audits("outbox.recovered")).to be_empty
    end

    before { stub_broker }

    after { expect(broker_requests).to be_empty }

    it "RN-56: evento de turno superado por mensagem nova" do
      item = lost_agent_event
      ingest("é o de ontem")
      after_grace
      clear_enqueued_jobs

      expect_closed(item, "turno_superseded")
    end

    it "RN-46, tempo no limite: evento cujo turno venceu o prazo de 20 s (a 1 ms do prazo ainda é reoferecido)" do
      item = lost_agent_event
      deadline = AiTurn.find_by!(event_id: item.id).deadline_at
      clear_enqueued_jobs

      after_grace
      travel_to(deadline - 0.001.seconds, with_usec: true)
      expect(described_class.call).to eq([ item.id ])
      item.update_columns(next_attempt_at: start)
      clear_enqueued_jobs
      travel_to(deadline, with_usec: true)

      expect(described_class.call).to eq([])
      expect(item.reload.last_error).to eq("obsoleto: prazo_vencido")
      expect(audits("outbox.closed_obsolete").sole.data["reason"]).to eq("prazo_vencido")
    end

    it "RN-56: evento de turno já aplicado (a resposta chegou antes da confirmação do broker)" do
      item = lost_agent_event
      turn = AiTurn.find_by!(event_id: item.id)
      # O consumer compara o prazo com o relógio do Postgres, que o travel_to não move.
      turn.update_columns(deadline_at: db_now + 1.hour)
      item.ticket.update_columns(ai_deadline_at: db_now + 1.hour)
      expect(AgentActions::Apply.call(agent_action_for(turn)).status).to eq(:applied)
      OutboxEvent.where(event_type: "delivery.requested").update_all(completed_at: Time.current) # a saída não é o foco
      after_grace
      clear_enqueued_jobs

      expect_closed(item, "turno_applied")
    end

    it "evento de atribuição antiga" do
      item = lost_agent_event
      item.ticket.update_columns(assignment_version: 1)
      after_grace
      clear_enqueued_jobs

      expect_closed(item, "atribuicao_mudou")
    end

    it "RN-38: evento de atendimento que saiu da IA (escalado: mudança de estado direta, sem o handoff do bloco 08)" do
      item = lost_agent_event
      item.ticket.update_columns(state: "aguardando_humano")
      after_grace
      clear_enqueued_jobs

      expect_closed(item, "fora_da_ia")
    end

    it "ação de abertura de turno de caso que saiu da IA: não abre turno e zera a janela" do
      item = due_dispatch(ingest)
      item.ticket.update_columns(state: "aguardando_humano")
      after_grace
      clear_enqueued_jobs

      expect_closed(item, "fora_da_ia")
      expect(item.ticket.reload.dispatch_due_at).to be_nil
      expect(AiTurn.count).to eq(0)
    end

    it "ação de abertura de turno de atribuição antiga" do
      item = due_dispatch(ingest)
      item.ticket.update_columns(assignment_version: 1)
      after_grace
      clear_enqueued_jobs

      expect_closed(item, "atribuicao_mudou")
      expect(item.ticket.reload.dispatch_due_at).to be_present
    end

    it "ação de abertura de turno superada por mensagem nova no mesmo ciclo" do
      item = due_dispatch(ingest("um"))
      ingest("dois")
      after_grace
      clear_enqueued_jobs

      expect_closed(item, "mensagem_nova")
    end

    it "ação de abertura de turno de um ciclo já respondido" do
      item = due_dispatch(ingest("um"))
      ticket = item.ticket
      ingest("dois")
      ticket.reload.update_columns(first_pending_seq: ticket.latest_customer_seq)
      after_grace
      clear_enqueued_jobs

      expect_closed(item, "ciclo_anterior")
    end
  end

  describe "marca errada (invariante 6)" do
    it "cada item é decidido pelo atendimento da própria marca e auditado nela" do
      jim = create(:brand, :jim)
      ip_item = lost_agent_event("meu repasse não caiu")
      jim_item = lost_agent_event("my payout is late", brand: "jim")
      ip_item.ticket.update_columns(state: "aguardando_humano")
      after_grace
      clear_enqueued_jobs

      expect(described_class.call).to eq([ jim_item.id ])
      expect(audits("outbox.closed_obsolete").sole).to have_attributes(brand_id: infinitepay.id, ticket_id: ip_item.ticket_id)
      expect(audits("outbox.recovered").sole).to have_attributes(brand_id: jim.id, ticket_id: jim_item.ticket_id)
    end
  end

  describe "falha de dependência" do
    it "Redis fora: para na primeira falha, sem exceção, e o item segue aberto para a próxima volta" do
      first = lost_agent_event("um", identity: "acc_a")
      lost_agent_event("dois", identity: "acc_b")
      after_grace
      allow(OutboxJob).to receive(:perform_later).and_raise(RedisClient::CannotConnectError, "redis fora do ar")

      expect(described_class.call).to eq([])
      expect(first.reload.completed_at).to be_nil
      expect(audits("outbox.recovered").count).to eq(1)
    end
  end
end
