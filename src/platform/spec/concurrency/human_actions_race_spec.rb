require "rails_helper"

# Bloco 14: duas ações do analista no mesmo atendimento ao mesmo tempo (invariantes 1 e 4: linha travada).
RSpec.describe "Human::Resolve e Human::Reply em corrida", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:setup) { distribution_setup(infinitepay) }
  let!(:ana) { analyst_in(setup[:team]) }
  let!(:ticket) { case_with(ana, brand: infinitepay, queue: setup[:queue], identity: "acc_1") }

  it "dois resolver juntos: um vence e a vaga é liberada uma vez só" do
    results = run_concurrently(threads: 2) { Human::Resolve.call(ticket_id: ticket.id, brand_id: infinitepay.id, user: ana, reason: "outro") }

    expect(results.map(&:status)).to match_array(%i[resolved rejected])
    expect(ana.reload.active_count).to eq(0)
    expect(AuditEvent.where(event_type: "ticket.resolved").count).to eq(1)
  end

  it "responder e resolver juntos: ou responde antes de resolver, ou é recusado; nunca fica mensagem depois do resolvido" do
    results = run_concurrently(threads: 2) do |index|
      if index.zero?
        Human::Reply.call(ticket_id: ticket.id, brand_id: infinitepay.id, user: ana, text: "oi")
      else
        Human::Resolve.call(ticket_id: ticket.id, brand_id: infinitepay.id, user: ana, reason: "outro")
      end
    end

    expect(ticket.reload.state).to eq("resolvido")
    expect(results.count { _1.status == :resolved }).to eq(1)
    replied = Message.where(ticket_id: ticket.id, direction: "outbound").count
    expect(replied).to eq(results.count { _1.status == :sent })
  end

  it "dois respostas juntas: seq distintos e sem colisão" do
    run_concurrently(threads: 2) { Human::Reply.call(ticket_id: ticket.id, brand_id: infinitepay.id, user: ana, text: "oi") }

    expect(Message.where(ticket_id: ticket.id, direction: "outbound").pluck(:seq).sort).to eq([ 2, 3 ])
  end
end
