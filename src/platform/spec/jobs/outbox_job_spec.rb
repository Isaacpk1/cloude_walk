require "rails_helper"

RSpec.describe OutboxJob, "RNF-14: o worker processa o outbox pelo ID" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  it "RN-55, ADR-016: ação turn.dispatch do scheduler abre o turno e enfileira a publicação do evento" do
    item = due_dispatch(ingest)
    clear_enqueued_jobs

    described_class.perform_now(item.id)

    turn = AiTurn.sole
    expect(item.reload.completed_at).to eq(start)
    expect(described_class).to have_been_enqueued.with(turn.event_id).on_queue("critical")
  end

  it "ação turn.dispatch descartada não enfileira publicação" do
    received = ingest
    item = due_dispatch(received)
    received.ticket.update_columns(assignment_version: 1)
    clear_enqueued_jobs

    described_class.perform_now(item.id)

    expect(AiTurn.count).to eq(0)
    expect(enqueued_jobs).to be_empty
  end

  it "RN-55: o aviso message.received é encerrado sem abrir turno (a triagem entra no bloco 11)" do
    received = ingest
    clear_enqueued_jobs

    described_class.perform_now(received_item(received).id)

    expect(AiTurn.count).to eq(0)
    expect(OutboxEvent.where(event_type: "agent.event")).to be_empty
    expect(received_item(received).completed_at).to eq(start)
    expect(enqueued_jobs).to be_empty
  end

  it "evento do agente: publica no broker" do
    stub_broker
    described_class.perform_now(due_dispatch(ingest).id)

    described_class.perform_now(AiTurn.sole.event_id)

    expect(OutboxEvent.find(AiTurn.sole.event_id).published_at).to eq(start)
  end

  it "falha transitória: agenda o despertador para o next_attempt_at gravado no Postgres" do
    stub_broker({ status: 503 })
    described_class.perform_now(due_dispatch(ingest).id)
    clear_enqueued_jobs

    described_class.perform_now(AiTurn.sole.event_id)

    item = OutboxEvent.find(AiTurn.sole.event_id)
    job = enqueued_jobs.sole
    expect(job).to include(job: described_class, args: [ item.id ])
    expect(Time.zone.at(job[:at])).to be_within(0.001).of(item.next_attempt_at)
  end

  describe "RF-06: delivery.requested" do
    let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }

    it "envia a saída ao provedor do chat" do
      delivery = requested_delivery(customer_message.ticket)
      stub_channels

      described_class.perform_now(delivery_item(delivery).id)

      expect(delivery.reload.status).to eq("delivered")
      expect(channel_requests.size).to eq(1)
    end

    it "RN-43: falha transitória agenda o despertador para o next_attempt_at do item" do
      delivery = requested_delivery(customer_message.ticket)
      stub_channels(status: 503)
      clear_enqueued_jobs

      described_class.perform_now(delivery_item(delivery).id)

      job = enqueued_jobs.sole
      expect(job).to include(job: described_class, args: [ delivery_item(delivery).id ])
      expect(Time.zone.at(job[:at])).to be_within(0.001).of(delivery_item(delivery).next_attempt_at)
    end
  end

  describe "RN-46, RF-36: timeouts e handoff (bloco 08)" do
    before { allow(DatabaseClock).to receive(:now) { Time.current } }

    it "os tipos novos estão em HANDLED, para a recuperação reoferecê-los" do
      expect(described_class::HANDLED).to include("turn.timeout", "cycle.timeout", "handoff.requested")
    end

    it "turn.timeout expira o turno e acorda o handoff pelo ID" do
      turn = opened_turn
      turn.update_columns(deadline_at: start - 1.second)
      item = Deadlines::TurnTimeout.call(now: start, limit: 10).sole
      clear_enqueued_jobs

      described_class.perform_now(item)

      handoff = handoff_items(turn.ticket).sole
      expect(turn.reload.status).to eq("expired")
      expect(described_class).to have_been_enqueued.with(handoff.id).on_queue("critical")
    end

    it "timeout ainda não vencido pelo relógio do banco: despertador no prazo gravado" do
      turn = opened_turn
      turn.update_columns(deadline_at: start - 1.second)
      item = Deadlines::TurnTimeout.call(now: start, limit: 10).sole
      allow(DatabaseClock).to receive(:now).and_return(start - 2.seconds)
      clear_enqueued_jobs

      described_class.perform_now(item)

      expect(Time.zone.at(enqueued_jobs.sole[:at])).to be_within(0.001).of(start - 1.second)
    end

    it "cycle.timeout pede o handoff e o handoff.requested escala o caso" do
      ticket = ingest.ticket
      ticket.update_columns(ai_deadline_at: start)
      item = Deadlines::CycleTimeout.call(now: start, limit: 10).sole

      perform_enqueued_jobs { described_class.perform_now(item) }

      expect(ticket.reload.state).to eq("aguardando_humano")
      expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.escalated").count).to eq(1)
    end

    it "RN-42, RN-39: handoff.requested acorda, depois do commit, o aviso de transferência e o pedido de resumo" do
      ticket = ingest.ticket
      id = request_handoff(ticket)
      clear_enqueued_jobs

      described_class.perform_now(id)

      notice = OutboxEvent.find_by!(ticket_id: ticket.id, event_type: "delivery.requested")
      summary = OutboxEvent.find_by!(ticket_id: ticket.id, event_type: "handoff.summary")
      expect(described_class).to have_been_enqueued.with(notice.id).on_queue("critical")
      expect(described_class).to have_been_enqueued.with(summary.id).on_queue("critical")
    end

    it "RN-42: Redis fora ao acordar o aviso: o handoff já está gravado e a recuperação reoferece o item" do
      ticket = ingest.ticket
      id = request_handoff(ticket)
      allow(described_class).to receive(:perform_later).and_raise(RedisClient::CannotConnectError)

      expect { described_class.perform_now(id) }.not_to raise_error

      expect(ticket.reload.state).to eq("aguardando_humano")
      expect(OutboxEvent.find_by!(ticket_id: ticket.id, event_type: "delivery.requested").completed_at).to be_nil
    end

    it "RN-46: publicação esgotada acorda o handoff pedido pelo outbox" do
      stub_broker({ status: 401 })
      described_class.perform_now(due_dispatch(ingest).id)
      clear_enqueued_jobs

      described_class.perform_now(AiTurn.sole.event_id)

      handoff = handoff_items.sole
      expect(handoff.payload).to include("reason" => "publicacao_falhou", "source" => "outbox")
      expect(described_class).to have_been_enqueued.with(handoff.id)
    end
  end

  describe "RN-57: progress.notice" do
    before { allow(DatabaseClock).to receive(:now) { Time.current } }

    it "grava o aviso e acorda o envio pelo item delivery.requested" do
      ticket = ingest.ticket
      travel 15.seconds
      item_id = Deadlines::ProgressDue.call(now: Time.current, limit: 10).sole
      clear_enqueued_jobs

      described_class.perform_now(item_id)

      requested = OutboxEvent.find_by!(event_type: "delivery.requested", ticket_id: ticket.id)
      expect(Delivery.find_by!(ticket_id: ticket.id).kind).to eq("progress")
      expect(described_class).to have_been_enqueued.with(requested.id).on_queue("critical")
    end

    it "relógio do banco antes do prazo: agenda o despertador para o progress_due_at" do
      ingest
      travel 15.seconds
      item_id = Deadlines::ProgressDue.call(now: Time.current, limit: 10).sole
      due = Ticket.sole.progress_due_at
      allow(DatabaseClock).to receive(:now).and_return(due - 0.1.seconds)
      clear_enqueued_jobs

      described_class.perform_now(item_id)

      job = enqueued_jobs.sole
      expect(job).to include(job: described_class, args: [ item_id ])
      expect(job[:at]).to be_within(0.01).of(due.to_f)
    end

    it "a recuperação do outbox reoferece o tipo (OutboxJob::HANDLED)" do
      expect(described_class::HANDLED).to include("progress.notice")
    end
  end

  describe "RN-39, RN-40: handoff.summary (bloco 10)" do
    it "monta o resumo da plataforma pelo ID e está em HANDLED, para a recuperação reoferecê-lo" do
      expect(described_class::HANDLED).to include("handoff.summary")
      turn = opened_turn
      request_handoff(turn.ticket, reason: "prazo_do_turno", source: "scheduler", turn: turn.turn)
      Handoff::Escalate.call(handoff_items(turn.ticket).sole.id)
      # O Escalate (bloco 10) já grava este item; o teste o regrava com o payload que controla.
      OutboxEvent.where(dedup_key: "summary:#{turn.ticket_id}:0").delete_all
      item = OutboxEvent.create!(brand_id: turn.brand_id, ticket_id: turn.ticket_id, event_type: "handoff.summary",
                                 dedup_key: "summary:#{turn.ticket_id}:0", trace_id: "d" * 32, next_attempt_at: Time.current,
                                 payload: { "ticket_id" => turn.ticket_id, "from_assignment_version" => 0,
                                            "reason" => "prazo_do_turno", "escalated_at" => Time.current.utc.iso8601(6) })

      described_class.perform_now(item.id)

      expect(HandoffSummary.find_by!(ticket_id: turn.ticket_id)).to have_attributes(source: "platform", status: "available")
      expect(item.reload.completed_at).to be_present
    end
  end

  it "repetição: ação encerrada não faz nada" do
    item = due_dispatch(ingest)
    item.update!(completed_at: start)

    described_class.perform_now(item.id)

    expect(AiTurn.count).to eq(0)
  end

  it "item inexistente é ignorado" do
    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end
end
