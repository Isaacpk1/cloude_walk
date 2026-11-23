require "rails_helper"

RSpec.describe Distribution::Assign, "RF-25, RN-30: atribuição automática ao analista" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:setup) { distribution_setup(infinitepay) }
  let(:team) { setup[:team] }
  let(:queue) { setup[:queue] }
  let(:now) { Time.zone.parse("2026-11-24 10:00:00") }
  let!(:ticket) { waiting_case(brand: infinitepay, queue:, identity: "acc_a") }

  def assign(target = ticket, brand_id: target.brand_id, **) = described_class.call(ticket_id: target.id, brand_id:, now:, **)

  it "RN-30: atribui ao analista online da equipe da fila e leva o caso a com_analista" do
    ana = analyst_in(team)

    result = assign(trace_id: "a" * 32)

    expect(result).to have_attributes(status: :assigned, assignee_id: ana.id)
    expect(ticket.reload).to have_attributes(state: "com_analista", assignee_id: ana.id, assignment_version: 1)
    expect(ana.reload).to have_attributes(active_count: 1, last_assigned_at: now)
  end

  it "RN-30, RF-54: audita ticket.assigned com o analista, o motivo e o trace_id" do
    ana = analyst_in(team)

    assign(trace_id: "b" * 32)

    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.assigned").sole).to have_attributes(
      brand_id: infinitepay.id, trace_id: "b" * 32, actor_type: "system",
      data: a_hash_including("to" => "analista", "reason" => "distribuicao_automatica", "assignee_id" => ana.id,
                             "queue_id" => queue.id, "state_from" => "aguardando_humano", "state_to" => "com_analista",
                             "assignment_version" => 1)
    )
  end

  describe "RN-30: quem é candidato" do
    it "escolhe o de menor carga" do
      analyst_in(team, active_count: 3)
      light = analyst_in(team, active_count: 1)

      expect(assign.assignee_id).to eq(light.id)
    end

    it "empata pelo que está há mais tempo sem receber caso, e quem nunca recebeu vem primeiro" do
      analyst_in(team, last_assigned_at: now - 1.minute)
      oldest = analyst_in(team, last_assigned_at: now - 1.hour)
      never = analyst_in(team, last_assigned_at: nil)

      expect(assign.assignee_id).to eq(never.id)
      expect(assign(waiting_case(brand: infinitepay, queue:, identity: "acc_b")).assignee_id).to eq(oldest.id)
    end

    it "RN-31: pausa e offline não recebem" do
      analyst_in(team, status: "pausa")
      analyst_in(team, status: "offline")

      expect(assign).to have_attributes(status: :waiting, assignee_id: nil)
      expect(ticket.reload).to have_attributes(state: "aguardando_humano", assignee_id: nil, assignment_version: 0)
    end

    it "respeita a capacidade: analista cheio não recebe" do
      analyst_in(team, capacity: 2, active_count: 2)

      expect(assign.status).to eq(:waiting)
    end

    it "só a equipe da fila: analista de outra equipe da mesma marca não é candidato" do
      analyst_in(create(:team, brand: infinitepay))

      expect(assign.status).to eq(:waiting)
    end

    it "RF-25 (marca errada): analista de outra marca nunca é candidato" do
      other_team = create(:team, brand: jim)
      analyst_in(other_team)

      expect(assign.status).to eq(:waiting)
    end

    it "RF-23: o bot e o supervisor não recebem" do
      bot = create(:user, :bot, status: "online").tap { TeamMembership.create!(user: _1, team:) }
      supervisor = create(:user, role: "supervisor", status: "online").tap { TeamMembership.create!(user: _1, team:) }

      expect(assign.status).to eq(:waiting)
      expect([ bot.reload.active_count, supervisor.reload.active_count ]).to eq([ 0, 0 ])
    end
  end

  describe "o caso" do
    it "sem analista, espera sem auditoria" do
      assign

      expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.assigned")).to be_empty
    end

    it "repetição: atribuir duas vezes ocupa uma vaga só e audita uma vez" do
      ana = analyst_in(team)

      first = assign
      second = assign

      expect([ first.status, second.status ]).to eq(%i[assigned not_waiting])
      expect(ana.reload.active_count).to eq(1)
      expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.assigned").count).to eq(1)
    end

    it "ignora caso que não está em aguardando_humano" do
      analyst_in(team)
      ticket.update_columns(state: "com_ia")

      expect(assign.status).to eq(:not_waiting)
    end

    it "ignora caso sem fila" do
      analyst_in(team)
      ticket.update_columns(queue_id: nil, queue_version: nil)

      expect(assign.status).to eq(:not_waiting)
    end

    it "RF-25 (marca errada): não atribui um caso passando o brand_id de outra marca" do
      analyst_in(team)

      expect(assign(brand_id: jim.id).status).to eq(:not_waiting)
      expect(ticket.reload.state).to eq("aguardando_humano")
    end

    it "RN-23, RN-31: não mexe no SLA do caso" do
      analyst_in(team)
      ticket.update_columns(sla_started_at: now - 5.minutes, sla_due_at: now + 10.minutes)

      assign

      expect(ticket.reload).to have_attributes(sla_started_at: now - 5.minutes, sla_due_at: now + 10.minutes)
    end
  end

  describe "falha: perde a corrida da vaga" do
    it "tenta o próximo candidato quando a reserva do primeiro falha" do
      first = analyst_in(team, active_count: 0, last_assigned_at: now - 2.hours)
      second = analyst_in(team, active_count: 1)
      allow(Distribution::Slot).to receive(:claim!).and_wrap_original do |original, **args|
        args[:user_id] == first.id ? false : original.call(**args)
      end

      expect(assign.assignee_id).to eq(second.id)
      expect(first.reload.active_count).to eq(0)
    end

    it "sem nenhuma vaga na corrida, o caso continua esperando" do
      analyst_in(team)
      allow(Distribution::Slot).to receive(:claim!).and_return(false)

      expect(assign.status).to eq(:waiting)
      expect(ticket.reload.state).to eq("aguardando_humano")
    end
  end
end
