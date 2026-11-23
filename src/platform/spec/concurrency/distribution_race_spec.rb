require "rails_helper"

RSpec.describe Distribution::Assign, "RN-30: dois workers disputam a última vaga", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:setup) { distribution_setup(infinitepay) }

  it "RN-30: dois casos, uma vaga: só um é atribuído e o outro continua na fila" do
    ana = analyst_in(setup[:team], capacity: 1)
    cases = %w[a b].map { waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_#{_1}") }

    results = run_concurrently(threads: 2) do |i|
      described_class.call(ticket_id: cases[i].id, brand_id: infinitepay.id, now: Time.current)
    end

    expect(results).to all(be_a(Data))
    expect(results.map(&:status).sort).to eq(%i[assigned waiting])
    expect(ana.reload.active_count).to eq(1)
    expect(Ticket.where(id: cases.map(&:id), state: "com_analista").count).to eq(1)
    expect(Ticket.where(id: cases.map(&:id), state: "aguardando_humano").count).to eq(1)
  end

  it "RN-30: oito workers, três vagas no total: nunca passa da capacidade" do
    analysts = [ analyst_in(setup[:team], capacity: 2), analyst_in(setup[:team], capacity: 1) ]
    cases = Array.new(8) { |i| waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_#{i}") }

    results = run_concurrently(threads: 8) do |i|
      described_class.call(ticket_id: cases[i].id, brand_id: infinitepay.id, now: Time.current)
    end

    expect(results).to all(be_a(Data))
    expect(results.count { _1.status == :assigned }).to eq(3)
    expect(analysts.map { _1.reload.active_count }).to eq([ 2, 1 ])
    expect(Ticket.where(id: cases.map(&:id), state: "com_analista").count).to eq(3)
  end

  it "repetição: dois workers no mesmo caso atribuem uma vez só" do
    ana = analyst_in(setup[:team], capacity: 5)
    ticket = waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_x")

    results = run_concurrently(threads: 2) do
      described_class.call(ticket_id: ticket.id, brand_id: infinitepay.id, now: Time.current)
    end

    expect(results.map(&:status).sort).to eq(%i[assigned not_waiting])
    expect(ana.reload.active_count).to eq(1)
    expect(ticket.reload.assignment_version).to eq(1)
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.assigned").count).to eq(1)
  end
end

RSpec.describe Distribution::Run, "RN-30: duas voltas do scheduler ao mesmo tempo", :concurrency do
  it "não atribuem o mesmo caso duas vezes nem passam da capacidade" do
    brand = create(:brand, :infinitepay)
    setup = distribution_setup(brand)
    ana = analyst_in(setup[:team], capacity: 3)
    cases = Array.new(3) { |i| waiting_case(brand:, queue: setup[:queue], identity: "acc_#{i}") }

    results = run_concurrently(threads: 2) { described_class.call(now: Time.current, limit: 10) }

    expect(results.flatten.sort).to eq(cases.map(&:id).sort)
    expect(ana.reload.active_count).to eq(3)
    expect(cases.map { _1.reload.assignment_version }).to all(eq(1))
  end
end
