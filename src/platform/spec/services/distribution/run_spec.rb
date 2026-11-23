require "rails_helper"

RSpec.describe Distribution::Run, "RF-19, RF-25, RN-29, RN-30: volta de distribuição do scheduler" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:setup) { distribution_setup(infinitepay) }
  let(:team) { setup[:team] }
  let(:queue) { setup[:queue] }
  let(:now) { Time.zone.parse("2026-11-24 10:00:00") }

  def waiting(identity, **) = waiting_case(brand: infinitepay, queue:, identity:, **)
  def run(**) = described_class.call(now:, limit: 50, **)

  it "RN-29: atribui na ordem prioridade, menor tempo restante de SLA, entrada mais antiga e id" do
    analyst_in(team, capacity: 10)
    media = waiting("m", priority: "media", sla_due_at: now + 1.minute, started_at: now - 9.minutes)
    alta_tarde = waiting("at", priority: "alta", sla_due_at: now + 20.minutes, started_at: now - 3.minutes)
    alta_cedo = waiting("ac", priority: "alta", sla_due_at: now + 5.minutes, started_at: now - 2.minutes)
    critica = waiting("c", priority: "critica", sla_due_at: now + 30.minutes, started_at: now - 1.minute)
    alta_sem_sla = waiting("as", priority: "alta", sla_due_at: nil, started_at: now - 8.minutes)

    ids = run

    expect(ids).to eq([ critica, alta_cedo, alta_tarde, alta_sem_sla, media ].map(&:id))
  end

  it "RN-29: com prioridade e prazo iguais, vale a entrada mais antiga e depois o id" do
    analyst_in(team, capacity: 10)
    novo = waiting("n", sla_due_at: now + 5.minutes, started_at: now - 1.minute)
    velho = waiting("v", sla_due_at: now + 5.minutes, started_at: now - 4.minutes)

    expect(run).to eq([ velho.id, novo.id ])
  end

  it "RN-30: sem vaga para todos, os primeiros da ordem ficam com ela e o resto espera" do
    ana = analyst_in(team, capacity: 2)
    baixa = waiting("b", priority: "baixa")
    critica = waiting("c", priority: "critica")
    alta = waiting("a", priority: "alta")

    expect(run).to eq([ critica.id, alta.id ])
    expect(baixa.reload.state).to eq("aguardando_humano")
    expect(ana.reload.active_count).to eq(2)
  end

  it "reparte pela menor carga entre os analistas" do
    ana = analyst_in(team, active_count: 1)
    bruno = analyst_in(team, active_count: 0)
    first = waiting("1")
    second = waiting("2")

    run

    expect(first.reload.assignee_id).to eq(bruno.id)
    # Depois do primeiro, os dois têm carga 1: quem nunca recebeu caso (Ana) fica com o segundo.
    expect(second.reload.assignee_id).to eq(ana.id)
    expect([ ana.reload.active_count, bruno.reload.active_count ]).to eq([ 2, 1 ])
  end

  it "respeita o limit da volta" do
    analyst_in(team, capacity: 10)
    3.times { |i| waiting("l#{i}") }

    expect(described_class.call(now:, limit: 2).size).to eq(2)
  end

  it "repetição: uma segunda volta não atribui de novo o que já foi atribuído" do
    analyst_in(team, capacity: 10)
    waiting("r")

    expect(run.size).to eq(1)
    expect(run).to eq([])
  end

  it "uma fila sem analista disponível não segura as outras filas" do
    empty_queue = create(:queue_record, team: create(:team, brand: infinitepay)).tap do
      _1.publish_version!(name: "Vazia", ai_first: false, created_by: nil)
    end
    ana = analyst_in(team)
    stuck = waiting_case(brand: infinitepay, queue: empty_queue.reload, identity: "stuck", priority: "critica")
    free = waiting("free", priority: "baixa")

    expect(described_class.call(now:, limit: 1)).to eq([ free.id ])
    expect(stuck.reload.state).to eq("aguardando_humano")
    expect(free.reload.assignee_id).to eq(ana.id)
  end

  it "RF-25 (marca errada): cada marca usa só os analistas da sua equipe" do
    jim_setup = distribution_setup(jim)
    jim_analyst = analyst_in(jim_setup[:team])
    ip_case = waiting("ip")
    jim_case = waiting_case(brand: jim, queue: jim_setup[:queue], identity: "jim")

    expect(run).to eq([ jim_case.id ])
    expect(jim_case.reload.assignee_id).to eq(jim_analyst.id)
    expect(ip_case.reload.state).to eq("aguardando_humano")
  end

  it "com brand_id, só aquela marca" do
    jim_setup = distribution_setup(jim)
    analyst_in(jim_setup[:team])
    analyst_in(team)
    waiting_case(brand: jim, queue: jim_setup[:queue], identity: "jim")
    ip_case = waiting("ip")

    expect(run(brand_id: infinitepay.id)).to eq([ ip_case.id ])
  end

  it "ignora casos que não estão em aguardando_humano ou já têm responsável" do
    ana = analyst_in(team)
    com_ia = waiting("ia").tap { _1.update_columns(state: "com_ia") }
    taken = waiting("taken").tap { _1.update_columns(state: "com_analista", assignee_id: ana.id) }

    expect(run).to eq([])
    expect([ com_ia.reload.state, taken.reload.state ]).to eq(%w[com_ia com_analista])
  end
end
