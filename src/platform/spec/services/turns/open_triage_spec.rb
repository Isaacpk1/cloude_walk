require "rails_helper"

# 07, seção 3.1, passos 2 e 3: nenhum turno abre antes da triagem. Se o worker do message.received ainda não rodou,
# o Turns::Open faz a triagem sob o mesmo lock, antes de abrir o turno (common11.md).
RSpec.describe Turns::Open, "RF-12, RF-24, RN-28: triagem antes do primeiro turno" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:config) { triage_setup(infinitepay) }
  let(:start) { Time.zone.parse("2026-11-22T12:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  def audits(ticket, type) = AuditEvent.where(ticket_id: ticket.id, event_type: type).order(:id)

  it "RF-24: caso ainda novo é triado no Open e o turno abre com o caso em com_ia, com o bot" do
    received = ingest("meu repasse não caiu")
    item = due_dispatch(received)

    result = described_class.call(item.id)

    ticket = received.ticket.reload
    expect(result.status).to eq(:opened)
    expect(ticket).to have_attributes(state: "com_ia", assignee_id: config[:bot].id, category: "repasses",
                                      queue_id: config[:default].id, assignment_version: 0, dispatch_due_at: nil)
    expect(OutboxEvent.find(result.turn.event_id).payload["ticket"]).to include("state" => "com_ia")
    expect(audits(ticket, "routing.decided").sole.trace_id).to eq(item.trace_id)
    expect(audits(ticket, "routing.decided").sole.id).to be < audits(ticket, "ai_turn.opened").sole.id
  end

  it "repetição: Open depois do worker do message.received não faz a triagem de novo" do
    received = ingest("meu repasse não caiu")
    Triage::OnMessage.call(received_item(received).id)

    result = described_class.call(due_dispatch(received).id)

    expect(result.status).to eq(:opened)
    expect(audits(received.ticket, "triage.classified").size).to eq(1)
    expect(audits(received.ticket, "routing.decided").size).to eq(1)
    expect(audits(received.ticket, "triage.skipped")).to be_empty
  end

  it "RN-28: categoria somente humana não abre turno; vai à fila de escalas com o prazo da janela zerado" do
    received = ingest("preciso trocar o e-mail do cadastro")
    item = due_dispatch(received)

    result = described_class.call(item.id)

    ticket = received.ticket.reload
    expect(result).to have_attributes(status: :triaged_to_human, turn: nil)
    expect(ticket).to have_attributes(state: "aguardando_humano", queue_id: config[:escalation].id, dispatch_due_at: nil,
                                      first_pending_seq: nil, ai_deadline_at: nil)
    expect(ticket.ai_turns).to be_empty
    expect(OutboxEvent.where(event_type: "agent.event")).to be_empty
    expect(item.reload.completed_at).to eq(start)
    expect(audits(ticket, "ai_turn.not_opened").sole.data).to include("reason" => "triado_para_humano",
                                                                      "state" => "aguardando_humano")
  end

  it "RN-34 (ordem): pedido de humano na primeira mensagem pula a triagem e não abre turno" do
    received = ingest("quero falar com um atendente")
    item = due_dispatch(received)

    result = described_class.call(item.id)

    expect(result.status).to eq(:handoff_requested)
    expect(audits(received.ticket, "triage.skipped").sole.data).to include("reason" => "handoff_pedido")
    expect(received.ticket.reload).to have_attributes(state: "novo", category: "outros", queue_id: nil) # RN-11: classifica, não roteia
    expect(AiTurn.count).to eq(0)
  end

  describe "falha do avaliador" do
    before { allow(Routing::Evaluate).to receive(:call).and_raise(ActiveRecord::ConnectionFailed) }

    it "não abre turno sem triagem: o erro desfaz a transação e a ação fica aberta para a nova tentativa" do
      received = ingest("meu repasse não caiu")
      item = due_dispatch(received)

      expect { described_class.call(item.id) }.to raise_error(ActiveRecord::ConnectionFailed)

      expect(AiTurn.count).to eq(0)
      expect(item.reload.completed_at).to be_nil
      expect(received.ticket.reload).to have_attributes(state: "novo", dispatch_due_at: be_present)
    end

    it "RN-46: o caso não fica preso: o teto do ciclo pede o handoff e o Escalate leva o caso à fila de escalas" do
      received = ingest("meu repasse não caiu")
      expect { described_class.call(due_dispatch(received).id) }.to raise_error(ActiveRecord::ConnectionFailed)
      travel 60.seconds

      timeout = Deadlines::CycleTimeout.call(now: Time.current, limit: 10).sole
      handoff = Deadlines::Expire.call(timeout).handoff_event_id
      Handoff::Escalate.call(handoff)

      expect(received.ticket.reload).to have_attributes(state: "aguardando_humano", queue_id: config[:escalation].id)
    end
  end
end
