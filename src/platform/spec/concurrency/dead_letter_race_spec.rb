require "rails_helper"

# DLQ da plataforma com o Postgres de verdade, fora da transação de teste (AGENTS.md, item 3; RN-45, RN-47;
# invariantes 4 e 8).
RSpec.describe "DLQ da plataforma com processos concorrentes", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }

  def raise_errors(results)
    error = results.find { _1.is_a?(Exception) }
    raise error if error

    results
  end

  describe "RN-47, RF-34: a mesma mensagem entregue a quatro processos ao mesmo tempo" do
    it "grava uma linha e um pedido de handoff" do
      turn = opened_turn

      results = raise_errors(run_concurrently(threads: 4) { broker_dead_letter(turn, offset: 9) })

      expect(results.map(&:status).tally).to eq(recorded: 1, duplicate: 3)
      expect(DeadLetter.count).to eq(1)
      expect(handoff_items.count).to eq(1)
      expect(AuditEvent.where(event_type: "dead_letter.recorded").count).to eq(1)
    end
  end

  describe "RN-45: dois DLQ diferentes do mesmo turno ao mesmo tempo" do
    it "geram um só handoff.requested (colisão da chave da atribuição)" do
      turn = opened_turn

      results = raise_errors(run_concurrently(threads: 2) do |i|
        i.zero? ? broker_dead_letter(turn, offset: 100) : action_dead_letter(turn, action: "refund")
      end)

      expect(results.map { [ _1.status, _1.outcome ] }).to all(eq([ :recorded, "escalated" ]))
      expect(DeadLetter.count).to eq(2)
      expect(handoff_items.count).to eq(1)
      expect(AuditEvent.where(event_type: "handoff.requested").count).to eq(1)
    end
  end

  describe "RN-45, RN-56, invariante 4: DLQ concorrente com a aplicação de uma resposta válida do mesmo turno" do
    it "o lock do atendimento ordena: ou a resposta entrou antes e a DLQ só audita, ou a DLQ pede o handoff antes" do
      outcomes = Array.new(6) do |round|
        turn = opened_turn("meu repasse não caiu", identity: "acc_infinitepay_dlq_#{round}")
        action = agent_action_for(turn)

        results = raise_errors(run_concurrently(threads: 2) do |i|
          if i.zero?
            AgentActions::Apply.call(action, traceparent: AgentActionHelpers::TRACEPARENT)
          else
            broker_dead_letter(turn, offset: round)
          end
        end)
        applied, dead_letter = results

        expect(applied.status).to eq(:applied) # o handoff é do worker; o turno segue eligible até lá
        handoff = handoff_items.find_by(ticket_id: turn.ticket_id)
        applied_audit = AuditEvent.where(ticket_id: turn.ticket_id, event_type: "agent_action.applied").pick(:id)
        if dead_letter.outcome == "audited"
          expect(handoff).to be_nil
          reason = AuditEvent.where(ticket_id: turn.ticket_id, event_type: "dead_letter.audited").sole.data["reason"]
          expect(reason).to eq("turno_applied")
        else
          expect(dead_letter.outcome).to eq("escalated")
          requested = AuditEvent.where(ticket_id: turn.ticket_id, event_type: "handoff.requested").sole
          expect(requested.id).to be < applied_audit
          expect(handoff).to be_present
        end
        dead_letter.outcome
      end

      expect(outcomes - %w[audited escalated]).to be_empty
    end
  end
end
