# Bloco 13 (07, seção 3.5): uma equipe com fila humana, analistas e casos esperando na fila.
module DistributionHelpers
  def distribution_setup(brand, queue_name: "Escalas N1")
    team = create(:team, brand:)
    queue = create(:queue_record, team:, brand:, escalation: true)
    queue.publish_version!(name: queue_name, ai_first: false, created_by: nil)
    { team:, queue: queue.reload }
  end

  def analyst_in(team, status: "online", capacity: 5, active_count: 0, last_assigned_at: nil, **attrs)
    create(:user, status:, capacity:, active_count:, last_assigned_at:, **attrs).tap do
      TeamMembership.create!(user: _1, team:)
    end
  end

  # Um caso em `aguardando_humano` na fila, com o SLA da fila humana já iniciado (RN-23).
  def waiting_case(brand:, queue:, identity:, priority: "media", started_at: Time.current, sla_due_at: nil)
    ingest("meu repasse não caiu", brand: brand.slug, identity:).ticket.tap do |ticket|
      ticket.update_columns(state: "aguardando_humano", queue_id: queue.id, queue_version: queue.current_version.version,
                            priority:, assignee_id: nil, sla_started_at: started_at, sla_due_at:)
    end
  end

  # Um caso com o analista (com_analista ou aguardando_cliente), com a vaga dele ocupada (RN-30).
  def case_with(analyst, brand:, queue:, identity:, state: "com_analista", assignment_version: 1, **sla)
    waiting_case(brand:, queue:, identity:, **sla).tap do |ticket|
      ticket.update_columns(state:, assignee_id: analyst.id, assignment_version:)
      analyst.update_columns(active_count: analyst.active_count + 1)
    end
  end
end

RSpec.configure { |c| c.include DistributionHelpers }
