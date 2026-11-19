require "rails_helper"

RSpec.describe Deadlines::DispatchDue, "ADR-016: abertura do turno registrada pelo scheduler (07, seção 3.4)" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:now) { Time.zone.parse("2026-11-18T21:00:10Z") }

  around { |example| travel_to(now) { example.run } }

  def emit = described_class.call(now: Time.current, limit: 100)

  describe "ADR-016 / RN-55: prazo de envio vencido" do
    it "registra um turn.dispatch com chave, payload, trace_id e marca do atendimento" do
      ticket = pending_dispatch(due_at: now - 1.second, trace_id: "a" * 32)

      ids = emit

      item = dispatch_items.sole
      expect(ids).to eq([ item.id ])
      expect(item).to have_attributes(
        brand_id: infinitepay.id, ticket_id: ticket.id, trace_id: "a" * 32, next_attempt_at: now,
        dedup_key: "turn.dispatch:#{ticket.id}:#{ticket.assignment_version}:#{ticket.latest_customer_seq}",
        completed_at: nil, attempts: 0
      )
      expect(item.payload).to eq(
        "ticket_id" => ticket.id, "assignment_version" => ticket.assignment_version,
        "cover_until_seq" => ticket.latest_customer_seq, "dispatch_due_at" => (now - 1.second).iso8601(3)
      )
    end

    it "acorda o worker pelo ID do item, depois do commit" do
      pending_dispatch(due_at: now - 1.second)

      ids = emit

      expect(OutboxJob).to have_been_enqueued.with(ids.sole).on_queue("critical")
    end

    it "RF-54: audita a emissão com trace_id, sem limpar dispatch_due_at" do
      ticket = pending_dispatch(due_at: now - 0.3.seconds, trace_id: "b" * 32)

      ids = emit

      audit = AuditEvent.where(event_type: "turn.dispatch_scheduled").sole
      expect(audit).to have_attributes(brand_id: infinitepay.id, ticket_id: ticket.id, actor_type: "system",
                                       trace_id: "b" * 32)
      expect(audit.data).to include("outbox_event_id" => ids.sole, "dedup_key" => dispatch_items.sole.dedup_key,
                                    "cover_until_seq" => 1, "delay_ms" => 300)
      expect(ticket.reload.dispatch_due_at.iso8601(3)).to eq((now - 0.3.seconds).iso8601(3))
    end
  end

  describe "tempo no limite" do
    it "dispatch_due_at igual a agora já emite" do
      pending_dispatch(due_at: now)

      expect(emit.size).to eq(1)
    end

    it "dispatch_due_at 1 ms no futuro não emite" do
      pending_dispatch(due_at: now + 0.001.seconds)
      clear_enqueued_jobs

      expect(emit).to eq([])
      expect(dispatch_items).to be_empty
      expect(OutboxJob).not_to have_been_enqueued
    end

    it "atendimento sem prazo de envio não emite" do
      ingest

      expect(emit).to eq([])
    end
  end

  describe "repetição: a chave no outbox é o marcador da emissão" do
    it "duas varreduras seguidas emitem uma vez só" do
      pending_dispatch(due_at: now - 1.second)

      first = emit
      second = emit

      expect(first.size).to eq(1)
      expect(second).to eq([])
      expect(dispatch_items.count).to eq(1)
      expect(AuditEvent.where(event_type: "turn.dispatch_scheduled").count).to eq(1)
    end

    it "item já concluído pelo worker com o prazo ainda gravado não é emitido de novo" do
      pending_dispatch(due_at: now - 1.second)
      emit
      dispatch_items.sole.update_columns(completed_at: now)

      expect(emit).to eq([])
    end
  end

  describe "RN-55 / RN-56: mensagem nova do cliente depois da emissão" do
    it "gera chave nova e um item novo, que cobre a mensagem nova, com o trace_id dela" do
      ticket = pending_dispatch(due_at: now - 2.seconds, trace_id: "c" * 32)
      emit
      pending_dispatch(due_at: now - 1.second, trace_id: "d" * 32, external_id: "segunda")

      ids = emit

      expect(dispatch_items.count).to eq(2)
      newer = OutboxEvent.find(ids.sole)
      expect(newer.dedup_key).to eq("turn.dispatch:#{ticket.id}:#{ticket.assignment_version}:2")
      expect(newer.payload).to include("cover_until_seq" => 2, "dispatch_due_at" => (now - 1.second).iso8601(3))
      expect(newer.trace_id).to eq("d" * 32)
    end

    it "nova atribuição (assignment_version) também gera chave nova" do
      ticket = pending_dispatch(due_at: now - 1.second)
      emit
      ticket.update_columns(assignment_version: 1)

      ids = emit

      expect(OutboxEvent.find(ids.sole)).to have_attributes(dedup_key: "turn.dispatch:#{ticket.id}:1:1")
    end
  end

  describe "invariante 6: marca certa" do
    it "cada item leva a marca do próprio atendimento" do
      ip = pending_dispatch(due_at: now - 1.second, brand: "infinitepay")
      jm = pending_dispatch(due_at: now - 1.second, brand: "jim")

      emit

      expect(dispatch_items.pluck(:ticket_id, :brand_id)).to contain_exactly([ ip.id, infinitepay.id ], [ jm.id, jim.id ])
    end
  end

  describe "lote" do
    it "respeita o limite e começa pelo prazo mais antigo; o resto sai na volta seguinte" do
      late = pending_dispatch(due_at: now - 1.second, identity: "acc_1")
      oldest = pending_dispatch(due_at: now - 3.seconds, identity: "acc_2")
      middle = pending_dispatch(due_at: now - 2.seconds, identity: "acc_3")

      first = described_class.call(now:, limit: 2)

      expect(OutboxEvent.where(id: first).pluck(:ticket_id)).to contain_exactly(oldest.id, middle.id)
      expect(OutboxEvent.where(id: described_class.call(now:, limit: 2)).pluck(:ticket_id)).to eq([ late.id ])
    end
  end

  describe "falha de dependência: Redis fora depois do commit" do
    it "o item continua gravado e aberto, sem exceção; a recuperação reoferece" do
      pending_dispatch(due_at: now - 1.second)
      allow(OutboxJob).to receive(:perform_later).and_raise(RedisClient::CannotConnectError)

      ids = nil
      expect { ids = emit }.not_to raise_error

      expect(ids.size).to eq(1)
      expect(OutboxEvent.find(ids.sole).completed_at).to be_nil
    end
  end
end
