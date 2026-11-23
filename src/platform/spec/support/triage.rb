# Triagem do bloco 11 (common11.md): a configuração mínima de uma marca (fila padrão, fila de escalas e o bot na
# equipe) e decisões de roteamento no formato do Routing::Decision, para injetar no Triage::Run.
module TriageHelpers
  def triage_setup(brand, ai_first: true, escalation: true, bot: true)
    team = create(:team, brand:)
    default = create(:queue_record, team:, brand:, is_default: true)
    default.publish_version!(name: "Geral", ai_first:, created_by: nil)
    escalation_queue = if escalation
      create(:queue_record, team:, brand:, escalation: true).tap do
        _1.publish_version!(name: "Escalas N1", ai_first: false, created_by: nil)
      end
    end
    bot_user = create(:user, :bot).tap { TeamMembership.create!(user: _1, team:) } if bot
    { team:, default: default.reload, escalation: escalation_queue&.reload, bot: bot_user }
  end

  # Decisão de uma regra que casou (ou da padrão, com `default: true`), com todos os campos da interface.
  def routing_decision(queue, default: false, ruleset_version: 3, rule_index: 0, rule_name: "Regra de teste")
    conditions = default ? [] : [ { "field" => "category", "op" => "eq", "value" => "repasses" } ]
    Routing::Decision.new(queue:, queue_version: queue&.current_version&.version,
                          queue_name: queue&.current_version&.name, ruleset_version:,
                          rule_index: (rule_index unless default), rule_name: (rule_name unless default),
                          group_index: (0 unless default), conditions:, default:, skipped_rules: [])
  end

  # Avaliador injetável: devolve sempre a mesma decisão e guarda o que recebeu.
  def fixed_evaluator(decision)
    calls = []
    evaluator = Object.new
    evaluator.define_singleton_method(:call) do |**args|
      calls << args
      decision
    end
    evaluator.define_singleton_method(:calls) { calls }
    evaluator
  end

  def run_triage(ticket, evaluator: Routing::Evaluate, seq: nil, trace_id: "d" * 32)
    ActiveRecord::Base.transaction do
      locked = Ticket.lock.find_by!(id: ticket.id, brand_id: ticket.brand_id)
      Triage::Run.call(ticket: locked, trace_id:, seq:, evaluator:)
    end
  end
end

RSpec.configure { |c| c.include TriageHelpers }
