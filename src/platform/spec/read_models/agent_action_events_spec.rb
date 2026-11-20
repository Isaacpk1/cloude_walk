require "rails_helper"

# Gravado pelo AgentActions::Apply real, a partir de um turno aberto pelo caminho real (ingestão → Turns::Open).
RSpec.describe AgentActionEvents, "RF-31, RF-55: ação do turno como o consumer grava" do
  let!(:infinitepay) { create(:brand, :infinitepay) }

  def apply(action) = AgentActions::Apply.call(action, traceparent: AgentActionHelpers::TRACEPARENT)

  describe "RF-31, RN-56: primeira ação descartada, segunda aplicada no mesmo turno" do
    let(:turn) { opened_turn }
    let(:first) { agent_action_for(turn, context_until_seq: turn.context_until_seq + 5, reply: { "text" => "PRIMEIRA" }) }
    let(:second) { agent_action_for(turn, reply: { "text" => "SEGUNDA" }) }

    before do
      expect(apply(first)).to have_attributes(status: :rejected, reason: "contexto_divergente")
      expect(apply(second).status).to eq(:applied)
      turn.reload
    end

    it "o turno applied mostra a ação aplicada (applied_event_id), não a primeira recebida" do
      expect(turn.response["event_id"]).to eq(first["event_id"]) # ai_turns.response guarda a primeira (07, seção 4)

      view = described_class.new(turn.ticket).for_turn(turn)

      expect(view).to have_attributes(outcome: :applied, event_id: second["event_id"], reply_text: "SEGUNDA")
    end

    it "RF-55: a linha do tempo mostra a primeira descartada com o motivo e a segunda aplicada, cada uma com o seu texto" do
      outcomes = described_class.new(turn.ticket).events.reject { _1.kind == :agent_run }
                                .map { [ _1.kind, _1.agent_action.reply_text, _1.agent_action.rejection_reason ] }

      expect(outcomes).to eq([ [ :discarded, "PRIMEIRA", "contexto_divergente" ], [ :applied, "SEGUNDA", nil ] ])
    end
  end
end
