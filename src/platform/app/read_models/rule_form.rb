# Linhas do formulário de regras (bloco 12; RF-14): o conjunto atual da marca no formato do formulário, mais uma regra
# em branco, e em cada regra um grupo e uma condição em branco a mais, para o supervisor acrescentar sem JavaScript.
class RuleForm
  BLANK_CONDITION = { "field" => "", "op" => "eq", "value" => "" }.freeze

  def self.rows(ruleset)
    rules = (ruleset&.rules&.dig("rules") || []).map do |rule|
      { "name" => rule["name"], "queue_id" => rule["queue_id"], "groups" => rule["any"].map { |g| { "conditions" => g["all"].map { condition(_1) } } } }
    end
    rules << { "name" => "", "queue_id" => nil, "groups" => [] }
    rules.map { |rule| rule.merge("groups" => padded(rule["groups"])) }
  end

  def self.condition(raw)
    value = raw["value"].is_a?(Array) ? raw["value"].join(", ") : raw["value"].to_s
    { "field" => raw["field"], "op" => raw["op"], "value" => value }
  end

  def self.padded(groups)
    groups = groups.map { |group| { "conditions" => [ *group["conditions"], BLANK_CONDITION ] } }
    [ *groups, { "conditions" => [ BLANK_CONDITION, BLANK_CONDITION ] } ]
  end
  private_class_method :condition, :padded
end
