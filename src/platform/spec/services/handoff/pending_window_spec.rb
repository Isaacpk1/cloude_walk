require "rails_helper"

# Do pedido de handoff até o Handoff::Escalate, a atribuição atual não aceita mais trabalho da IA (RN-46: "a
# partir do vencimento... rejeita ações da IA e escala"; RN-56: uma ação final por turno; 07, seção 6: "caso já
# respondido não escala"). A janela cresce com o Sidekiq atrasado ou o job perdido no Redis.
RSpec.describe "RN-46, RN-56: janela entre o pedido de handoff e o Escalate" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  before { allow(DatabaseClock).to receive(:now) { Time.current } }

  def apply(action) = AgentActions::Apply.call(action, traceparent: AgentActionHelpers::TRACEPARENT)

  it "o pedido expira os turnos eligible da atribuição na mesma transação, com o motivo do pedido" do
    turn = opened_turn
    request_handoff(turn.ticket, reason: "publicacao_falhou", source: "outbox", turn: turn.turn)

    expect(turn.reload.status).to eq("expired")
    expect(audits(turn.ticket, "ai_turn.expired").sole.data).to include("turn" => 1, "reason" => "publicacao_falhou")
  end

  it "cenário A: falha definitiva da publicação e a ação válida chega antes do Escalate: rejeitada, nada sai" do
    turn = opened_turn
    stub_broker({ status: 401 })
    Outbox::Publish.call(turn.event_id, jitter: -> { 0.0 })
    expect(handoff_items(turn.ticket).count).to eq(1)

    result = apply(agent_action_for(turn))

    expect(result.status).to eq(:rejected)
    expect(Delivery.where(ticket_id: turn.ticket_id)).to be_empty
    expect(Handoff::Escalate.call(handoff_items(turn.ticket).sole.id).status).to eq(:escalated)
  end

  it "cenário B: timeout pedido e mensagem nova do cliente antes do Escalate: nenhum turno novo abre" do
    turn = opened_turn
    request_handoff(turn.ticket, reason: "prazo_do_turno", source: "scheduler", turn: turn.turn)

    travel 2.seconds
    received = ingest("ainda não caiu")
    ticket = received.ticket.reload
    expect(ticket.id).to eq(turn.ticket_id)

    result = Turns::Open.call(due_dispatch(received).id)

    expect(result.turn).to be_nil
    expect(audits(ticket, "ai_turn.not_opened").last.data).to include("reason" => "handoff_pedido")
    expect(ticket.reload.dispatch_due_at).to be_nil
    expect(ticket.ai_turns.count).to eq(1)
  end

  it "pending? vale só para a atribuição atual, na marca do atendimento" do
    ticket = opened_turn.ticket
    expect(Handoff::Request.pending?(ticket)).to be(false)

    request_handoff(ticket)
    expect(Handoff::Request.pending?(ticket.reload)).to be(true)

    ticket.update_columns(assignment_version: ticket.assignment_version + 1)
    expect(Handoff::Request.pending?(ticket)).to be(false)
  end

  it "07, seção 6: o Escalate descarta o pedido cujo turno já foi aplicado (turno_applied)" do
    default_queue(infinitepay)
    turn = opened_turn
    id = request_handoff(turn.ticket, reason: "falha_de_integracao", source: "dlq", turn: turn.turn)
    turn.update_columns(status: "applied", applied_event_id: SecureRandom.uuid) # defesa: aplicado por um caminho anterior ao pedido

    expect(Handoff::Escalate.call(id)).to have_attributes(status: :discarded, reason: "turno_applied")
    expect(turn.ticket.reload).to be_with_ai
  end
end
