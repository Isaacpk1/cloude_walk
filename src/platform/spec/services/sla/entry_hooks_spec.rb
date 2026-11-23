require "rails_helper"

RSpec.describe "RN-23, RN-32: o SLA começa quando o caso entra na fila humana" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:config) { triage_setup(infinitepay, ai_first: false) }

  it "RN-28 (triagem): caso triado direto para humanos recebe o início do SLA" do
    stub_channels(status: 200, message_id: "chat_out_1")
    ticket = ingest("minha maquininha não liga", brand: "infinitepay", identity: "acc_t").ticket

    run_triage(ticket, evaluator: fixed_evaluator(routing_decision(config[:default], default: true)))

    expect(ticket.reload).to have_attributes(state: "aguardando_humano")
    expect(ticket.sla_started_at).to be_present
    expect(ticket.sla_due_at).to be > ticket.sla_started_at
  end

  it "RF-36 (handoff): a escalação grava o SLA com a prioridade já subida (RN-41)" do
    stub_channels(status: 200, message_id: "chat_out_2")
    queue = config[:escalation]
    ticket = ingest("preciso de ajuda", brand: "infinitepay", identity: "acc_h").ticket
    ticket.update_columns(state: "com_ia", priority: "media")
    id = request_handoff(ticket, reason: "prazo_do_turno")

    Handoff::Escalate.call(id)

    ticket.reload
    expect(ticket).to have_attributes(state: "aguardando_humano", priority: "alta", queue_id: queue.id)
    expect(ticket.sla_due_at - ticket.sla_started_at).to eq(900)
  end

  it "RN-32: uma escalação nova do mesmo caso não reinicia o relógio" do
    stub_channels(status: 200, message_id: "chat_out_3")
    ticket = ingest("preciso de ajuda", brand: "infinitepay", identity: "acc_h2").ticket
    started = Time.zone.parse("2026-11-24 09:00:00")
    ticket.update_columns(state: "com_ia", priority: "media", sla_started_at: started, sla_due_at: started + 900.seconds)
    id = request_handoff(ticket, reason: "pedido_do_cliente", source: "ingestion")

    Handoff::Escalate.call(id)

    expect(ticket.reload).to have_attributes(sla_started_at: started, sla_due_at: started + 900.seconds)
  end
end
