require "rails_helper"

# Bloco 10: a escalate do agente concorrente com uma mensagem nova do cliente, com o Postgres de verdade,
# fora da transação de teste (AGENTS.md, item 3; 07, seção 3.4; RN-33 item 1, RN-56).
RSpec.describe "RN-33 (item 1), RN-56: escalate do agente × mensagem nova do cliente", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }

  def escalate_action(turn)
    agent_action_for(turn, action: "escalate", escalation: {
      "reason" => "retencao_suspeita",
      "summary" => { "problema" => "Repasse retido", "dados_cliente" => "Lojista", "acoes_tomadas" => "Consultou o repasse",
                     "motivo" => "Retenção", "pendente" => "Verificar a retenção" }
    }).except("reply")
  end

  it "ou a escalate entra antes e o pedido sai uma vez, ou a mensagem supera o turno e não há pedido" do
    outcomes = Array.new(6) do |round|
      identity = "acc_infinitepay_escala_#{round}"
      turn = opened_turn("meu repasse não caiu", identity:)
      action = escalate_action(turn)

      results = run_concurrently(threads: 2) do |i|
        i.zero? ? AgentActions::Apply.call(action, traceparent: AgentActionHelpers::TRACEPARENT) : ingest("é o de ontem", identity:)
      end
      raise results.find { _1.is_a?(Exception) } if results.any?(Exception)

      ticket = turn.ticket.reload
      requests = OutboxEvent.where(ticket_id: ticket.id, event_type: Handoff::Request::EVENT_TYPE)
      expect(Message.where(ticket_id: ticket.id).order(:seq).pluck(:seq)).to eq([ 1, 2 ]) # nenhuma saída da escalate

      if turn.reload.status == "applied"
        expect(requests.sole.payload).to include("reason" => "decisao_do_agente", "turn" => turn.turn)
        expect(AuditEvent.where(ticket_id: ticket.id, event_type: "handoff.requested").count).to eq(1)
      else
        expect(turn.status).to eq("superseded")
        expect(results.first).to have_attributes(status: :rejected, reason: "turno_superado")
        expect(requests).to be_empty
      end
      turn.status
    end

    expect(outcomes.uniq - %w[applied superseded]).to be_empty
  end

  it "RN-47: a mesma escalate entregue quatro vezes ao mesmo tempo grava um pedido só" do
    turn = opened_turn
    action = escalate_action(turn)

    results = run_concurrently(threads: 4) { AgentActions::Apply.call(action, traceparent: AgentActionHelpers::TRACEPARENT) }

    expect(results.map(&:status).tally).to eq(applied: 1, duplicate: 3)
    expect(OutboxEvent.where(event_type: Handoff::Request::EVENT_TYPE).count).to eq(1)
  end
end
