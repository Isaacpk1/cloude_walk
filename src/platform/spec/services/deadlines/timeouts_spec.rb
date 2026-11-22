require "rails_helper"

# Timeouts do turno e do ciclo registrados pelo scheduler (RN-46, ADR-016, ADR-020; 07, seção 3.4, "Regras de
# tempo" e "Registro dos prazos"; interface combinada, item 2).
RSpec.describe "RN-46: timeouts registrados pelo scheduler" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:now) { Time.zone.parse("2026-11-18T21:00:30Z") }

  around { |example| travel_to(now) { example.run } }

  def turn_due_at(deadline_at, **)
    turn = opened_turn(**)
    turn.update_columns(deadline_at:)
    turn
  end

  def turn_timeouts = OutboxEvent.where(event_type: Deadlines::TurnTimeout::EVENT_TYPE)
  def cycle_timeouts = OutboxEvent.where(event_type: Deadlines::CycleTimeout::EVENT_TYPE)

  describe Deadlines::TurnTimeout, "ADR-020: prazo do turno" do
    def emit(**) = described_class.call(now: Time.current, limit: 100, **)

    it "turno eligible vencido: grava turn.timeout com chave, payload e auditoria do prazo, e acorda o worker" do
      turn = turn_due_at(now - 0.4.seconds)

      ids = emit

      item = turn_timeouts.sole
      expect(ids).to eq([ item.id ])
      expect(item).to have_attributes(brand_id: infinitepay.id, ticket_id: turn.ticket_id, next_attempt_at: now,
                                      dedup_key: "timeout:turn:#{turn.ticket_id}:#{turn.turn}",
                                      trace_id: OutboxEvent.find(turn.event_id).trace_id)
      expect(item.payload).to eq("ticket_id" => turn.ticket_id, "turn" => turn.turn, "event_id" => turn.event_id,
                                 "assignment_version" => 0, "first_pending_seq" => 1,
                                 "deadline_at" => (now - 0.4.seconds).utc.iso8601(3))
      audit = AuditEvent.where(event_type: "turn.timeout_scheduled").sole
      expect(audit.data).to include("outbox_event_id" => item.id, "turn" => turn.turn, "first_pending_seq" => 1, "delay_ms" => 400,
                                    "deadline_at" => (now - 0.4.seconds).utc.iso8601(3))
      expect(OutboxJob).to have_been_enqueued.with(item.id)
    end

    it "tempo no limite: deadline_at igual a agora emite; 1 ms no futuro não" do
      turn_due_at(now)
      turn_due_at(now + 0.001.seconds, identity: "acc_infinitepay_000099")

      expect(emit.size).to eq(1)
    end

    it "repetição: duas voltas emitem uma vez só (a chave no outbox é o marcador)" do
      turn_due_at(now - 1.second)

      emit
      expect(emit).to eq([])
      expect(turn_timeouts.count).to eq(1)
    end

    it "turno que já não é eligible não emite" do
      turn = turn_due_at(now - 1.second)
      turn.update_columns(status: "superseded")

      expect(emit).to eq([])
    end

    it "invariante 6: escopo por marca (eval) só toca a marca pedida" do
      turn_due_at(now - 1.second)

      expect(emit(brand_id: jim.id)).to eq([])
      expect(emit(brand_id: infinitepay.id).size).to eq(1)
    end
  end

  describe Deadlines::CycleTimeout, "ADR-020: teto do ciclo" do
    def emit(**) = described_class.call(now: Time.current, limit: 100, **)

    it "RN-46: vale mesmo sem nenhum turno publicado" do
      ticket = ingest.ticket
      ticket.update_columns(ai_deadline_at: now - 0.2.seconds)

      ids = emit

      item = cycle_timeouts.sole
      expect(ids).to eq([ item.id ])
      expect(item).to have_attributes(dedup_key: "timeout:cycle:#{ticket.id}:1", ticket_id: ticket.id,
                                      trace_id: ticket.messages.first.trace_id)
      expect(item.payload).to eq("ticket_id" => ticket.id, "first_pending_seq" => 1, "assignment_version" => 0,
                                 "ai_deadline_at" => (now - 0.2.seconds).utc.iso8601(3))
      expect(AuditEvent.where(event_type: "cycle.timeout_scheduled").sole.data)
        .to include("outbox_event_id" => item.id, "turn" => nil, "first_pending_seq" => 1, "delay_ms" => 200,
                    "deadline_at" => (now - 0.2.seconds).utc.iso8601(3))
    end

    it "tempo no limite: ai_deadline_at igual a agora emite; 1 ms no futuro não" do
      ingest.ticket.update_columns(ai_deadline_at: now + 0.001.seconds)
      expect(emit).to eq([])

      ingest(identity: "acc_infinitepay_000077").ticket.update_columns(ai_deadline_at: now)
      expect(emit.size).to eq(1)
    end

    it "caso fora da IA ou sem ciclo pendente não emite" do
      ingest.ticket.update_columns(ai_deadline_at: now - 1.second, state: "aguardando_humano")

      expect(emit).to eq([])
    end

    it "com turno eligible no ciclo: a auditoria do prazo leva o número do turno" do
      turn = opened_turn
      turn.ticket.update_columns(ai_deadline_at: now - 1.second)

      emit

      expect(AuditEvent.where(event_type: "cycle.timeout_scheduled").sole.data).to include("turn" => turn.turn)
    end

    it "repetição: uma emissão por ciclo" do
      ingest.ticket.update_columns(ai_deadline_at: now - 1.second)

      emit
      expect(emit).to eq([])
    end
  end

  describe Deadlines::Loop, "ADR-016: o scheduler consulta os timeouts a cada volta" do
    it "uma volta chama a abertura, o timeout do turno e o teto do ciclo" do
      allow(Deadlines::DispatchDue).to receive(:call).and_return([ "a" ])
      allow(Deadlines::TurnTimeout).to receive(:call).and_return([ "b" ])
      allow(Deadlines::CycleTimeout).to receive(:call).and_return([])

      expect(described_class.new.tick).to eq(2)
      expect(Deadlines::TurnTimeout).to have_received(:call).with(now: Time.current, limit: 100)
      expect(Deadlines::CycleTimeout).to have_received(:call).with(now: Time.current, limit: 100)
    end
  end
end
