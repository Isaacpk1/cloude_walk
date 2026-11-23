# Decisão de roteamento do atendimento (RF-15, RF-18, RN-15, RN-16, RN-20), lida do routing.decided no formato combinado
# do bloco 11. `queue_name` e `queue_version` são os gravados na decisão (a fila como estava naquela hora).
# `rule_index` e `group_index` são 0-based; na tela a regra e o grupo contam a partir de 1. `conditions`: as condições do
# grupo que casou (ADR-003). `skipped_rules`: SkippedRule, as regras puladas porque a fila estava inativa (RN-15).
# Tudo texto comum: a tela escapa com o ERB.
class ConversationView::Routing < Data.define(:queue_id, :queue_name, :queue_version, :ruleset_version, :rule_index,
                                              :rule_name, :group_index, :conditions, :default, :skipped_rules,
                                              :decided_at, :trace_id)
  SkippedRule = Data.define(:rule_index, :rule_name, :queue_name, :reason) do
    REASONS = { "fila_inativa" => "inativa (RN-15)", "fila_fora_da_marca" => "fora da marca ou inexistente (RN-15)" }.freeze

    def label
      "regra #{rule_index.to_i + 1} «#{rule_name}» pulada: fila #{queue_name} #{REASONS.fetch(reason.to_s, "#{reason} (RN-15)")}"
    end
  end

  FIELDS = { "brand" => "marca", "channel" => "canal", "category" => "categoria", "priority" => "prioridade",
             "tags" => "tags" }.freeze
  OPS = { "eq" => "=", "neq" => "≠", "in" => "em", "not_in" => "fora de", "contains" => "contém" }.freeze

  def self.condition_text(condition)
    field = condition["field"].to_s
    values = Array(condition["value"]).map { value_label(field, _1.to_s) }
    "#{FIELDS.fetch(field, field)} #{OPS.fetch(condition['op'].to_s, condition['op'])} #{values.join(', ')}"
  end

  def self.value_label(field, value)
    case field
    when "category" then ConversationView::Category.label(value)
    when "priority" then ConversationView::Priority.short_label(value)
    else value
    end
  end

  def initialize(conditions: [], skipped_rules: [], **rest)
    super(conditions: Array(conditions).freeze, skipped_rules: skipped_rules.freeze, **rest)
  end

  def rule? = !rule_index.nil?
  def queue_label = "#{queue_name}#{", versão #{queue_version}" if queue_version}"
  def conditions_text = conditions.map { self.class.condition_text(_1) }.join(" E ")
  def skipped_rule_labels = skipped_rules.map(&:label)

  # "regra 2 «Crédito alto», conjunto de regras versão 3: categoria = crédito E … → fila Crédito, versão 1".
  def explanation
    return rule_explanation if rule?
    return "sem conjunto de regras e sem fila padrão na marca: caso sem fila" if queue_id.nil? && ruleset_version.nil?
    return "nenhuma regra casou e a marca não tem fila padrão: caso sem fila" if queue_id.nil?
    return "sem conjunto de regras na marca: fila padrão #{queue_label}" if ruleset_version.nil?

    "nenhuma regra casou: fila padrão #{queue_label} (RN-16), conjunto de regras versão #{ruleset_version}"
  end

  private

  def rule_explanation
    group = group_index.to_i.positive? ? ", grupo #{group_index + 1} do OU" : ""
    "regra #{rule_index + 1} «#{rule_name}», conjunto de regras versão #{ruleset_version}#{group}: #{conditions_text} " \
      "→ fila #{queue_label}"
  end
end
