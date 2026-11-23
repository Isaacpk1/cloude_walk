module RoutingRulesHelpers
  # Monta o JSON do conjunto (ADR-003). Cada regra: [nome, fila, [[condição, ...], ...]] com condição [campo, op, valor].
  def ruleset_json(*rules)
    {
      "schema_version" => 1,
      "rules" => rules.map do |name, queue, groups|
        { "name" => name, "queue_id" => queue.id,
          "any" => groups.map { |conds| { "all" => conds.map { |f, op, v| { "field" => f, "op" => op, "value" => v } } } } }
      end
    }
  end
end

RSpec.configure { |c| c.include RoutingRulesHelpers }
