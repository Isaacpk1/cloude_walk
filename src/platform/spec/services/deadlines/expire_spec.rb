require "rails_helper"

# Worker dos timeouts (RN-46, ADR-016, ADR-020; 07, seção 3.4 e seção 6; interface combinada, item 2): revalida
# sob o lock, expira o turno e grava handoff.requested na mesma transação, ou descarta com o motivo.
RSpec.describe Deadlines::Expire, "RN-46: worker dos timeouts do turno e do ciclo" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:now) { Time.zone.parse("2026-11-18T21:00:30Z") }

  around { |example| travel_to(now) { example.run } }

  # O relógio do banco não anda com o travel_to: aqui ele segue o relógio de teste.
  before { allow(DatabaseClock).to receive(:now) { Time.current } }

  def turn_timeout_for(turn, deadline_at: now - 0.1.seconds)
    turn.update_columns(deadline_at:)
    Deadlines::TurnTimeout.call(now: Time.current, limit: 10).sole
  end

  def cycle_timeout_for(ticket, ai_deadline_at: now - 0.1.seconds)
    ticket.update_columns(ai_deadline_at:)
    Deadlines::CycleTimeout.call(now: Time.current, limit: 10).sole
  end

  describe "turn.timeout" do
    it "turno eligible vencido: expira, audita ai_turn.expired e pede o handoff (prazo_do_turno) na mesma transação" do
      turn = opened_turn
      id = turn_timeout_for(turn)

      result = described_class.call(id)

      expect(result.status).to eq(:expired)
      expect(turn.reload.status).to eq("expired")
      expect(audits(turn.ticket, "ai_turn.expired").sole.data)
        .to include("turn" => turn.turn, "deadline_at" => (now - 0.1.seconds).utc.iso8601(3), "reason" => "prazo_do_turno")
      handoff = handoff_items(turn.ticket).sole
      expect(result.handoff_event_id).to eq(handoff.id)
      expect(handoff.payload).to eq("ticket_id" => turn.ticket_id, "reason" => "prazo_do_turno", "source" => "scheduler",
                                    "turn" => turn.turn, "first_pending_seq" => 1, "assignment_version" => 0)
      expect(audits(turn.ticket, "handoff.requested").sole.data).to include("reason" => "prazo_do_turno")
      expect(OutboxEvent.find(id).completed_at).to eq(now)
    end

    it "RN-46: o turno vence com o teto do ciclo ainda longe e o caso escala do mesmo jeito" do
      turn = opened_turn
      expect(turn.ticket.reload.ai_deadline_at).to be > now + 30.seconds

      described_class.call(turn_timeout_for(turn))

      expect(handoff_items(turn.ticket).sole.payload["reason"]).to eq("prazo_do_turno")
    end

    it "repetição: o mesmo item duas vezes tem um efeito só" do
      turn = opened_turn
      id = turn_timeout_for(turn)

      described_class.call(id)
      expect(described_class.call(id).status).to eq(:already_done)
      expect(audits(turn.ticket, "ai_turn.expired").count).to eq(1)
    end

    it "resposta aplicada antes do worker: descarte turno_applied, sem handoff" do
      turn = opened_turn
      id = turn_timeout_for(turn)
      registered = OutboxEvent.find(id).payload.fetch("deadline_at")
      # A resposta chegou antes do prazo e foi aplicada; o item do timeout ficou na fila.
      turn.update_columns(deadline_at: now + 5.seconds)
      AgentActions::Apply.call(agent_action_for(turn.reload), traceparent: AgentActionHelpers::TRACEPARENT)

      result = described_class.call(id)

      expect(result).to have_attributes(status: :discarded, reason: "turno_applied")
      expect(handoff_items).to be_empty
      expect(audits(turn.ticket, "turn.timeout_discarded").sole.data)
        .to include("reason" => "turno_applied", "turn" => turn.turn, "first_pending_seq" => 1,
                    "assignment_version" => turn.assignment_version, "deadline_at" => registered)
      expect(OutboxEvent.find(id).completed_at).to be_present
    end

    it "atribuição mudou: descarte, sem tocar o turno" do
      turn = opened_turn
      id = turn_timeout_for(turn)
      turn.ticket.update_columns(assignment_version: 2)

      expect(described_class.call(id)).to have_attributes(status: :discarded, reason: "atribuicao_mudou")
      expect(turn.reload.status).to eq("eligible")
    end

    it "relógio do banco ainda antes do prazo: não descarta; reagenda o despertador para o deadline_at" do
      turn = opened_turn
      id = turn_timeout_for(turn)
      allow(DatabaseClock).to receive(:now).and_return(now - 0.2.seconds)

      result = described_class.call(id)

      expect(result).to have_attributes(status: :not_due, next_attempt_at: be_within(0.001).of(now - 0.1.seconds))
      expect(OutboxEvent.find(id)).to have_attributes(completed_at: nil, next_attempt_at: be_within(0.001).of(now - 0.1.seconds))
      expect(turn.reload.status).to eq("eligible")
    end

    it "outro gatilho já pediu o handoff nesta atribuição: expira o turno e não grava um segundo pedido" do
      turn = opened_turn
      id = turn_timeout_for(turn)
      request_handoff(turn.ticket, reason: "publicacao_falhou", source: "outbox")

      result = described_class.call(id)

      expect(result).to have_attributes(status: :expired, handoff_event_id: nil)
      expect(handoff_items(turn.ticket).sole.payload["reason"]).to eq("publicacao_falhou")
    end
  end

  describe "cycle.timeout" do
    it "RN-46: teto do ciclo sem turno publicado pede o handoff (teto_do_ciclo, turn null)" do
      ticket = ingest.ticket
      id = cycle_timeout_for(ticket)

      result = described_class.call(id)

      expect(result.status).to eq(:expired)
      expect(handoff_items(ticket).sole.payload).to include("reason" => "teto_do_ciclo", "source" => "scheduler",
                                                            "turn" => nil, "first_pending_seq" => 1)
    end

    it "com turno eligible: expira o turno e leva o número dele no pedido" do
      turn = opened_turn
      id = cycle_timeout_for(turn.ticket.reload)

      described_class.call(id)

      expect(turn.reload.status).to eq("expired")
      expect(handoff_items(turn.ticket).sole.payload).to include("reason" => "teto_do_ciclo", "turn" => turn.turn)
    end

    it "07, seção 6: timeout de ciclo anterior é descartado e o ciclo atual continua valendo" do
      ticket = ingest.ticket
      id = cycle_timeout_for(ticket)
      ticket.update_columns(first_pending_seq: 5, latest_customer_seq: 5)

      expect(described_class.call(id)).to have_attributes(status: :discarded, reason: "ciclo_mudou")
      expect(handoff_items).to be_empty
      expect(audits(ticket, "cycle.timeout_discarded").sole.data)
        .to include("reason" => "ciclo_mudou", "first_pending_seq" => 1, "turn" => nil)
    end

    it "caso fora da IA: descarte fora_da_ia" do
      ticket = ingest.ticket
      id = cycle_timeout_for(ticket)
      ticket.update_columns(state: "com_analista")

      expect(described_class.call(id)).to have_attributes(status: :discarded, reason: "fora_da_ia")
    end

    it "relógio do banco antes do teto: reagenda" do
      ticket = ingest.ticket
      id = cycle_timeout_for(ticket)
      allow(DatabaseClock).to receive(:now).and_return(now - 1.second)

      expect(described_class.call(id)).to have_attributes(status: :not_due, next_attempt_at: be_within(0.001).of(now - 0.1.seconds))
    end
  end
end
