# Regras de roteamento a partir do formulário do supervisor (bloco 12; RF-14, RF-15, RF-17, RF-18, ADR-003, ADR-013).
# O formulário manda a lista ordenada de regras (grupos OU, condições E) e a fila padrão; aqui vira o JSON do contrato e
# `RoutingRuleset.publish!` valida (esquema, categorias, filas ativas da marca) e grava a versão nova. Cada problema
# volta em texto, para a tela mostrar. A propagação para o próximo atendimento é do cache que confere a versão (RNF-07).
#
#   Configuration::Rules.publish(brand:, rules: [ { "name" =>, "queue_id" =>, "groups" => [ { "conditions" => [ {field, op, value} ] } ] } ],
#                                default_queue_id:, created_by:) # => Result(ok:, record: RoutingRuleset, errors:)
module Configuration
  class Rules
    LIST_OPS = %w[in not_in].freeze

    def self.publish(brand:, rules:, default_queue_id:, created_by:)
      document = { "schema_version" => 1, "rules" => Array(rules).filter_map { convert(_1) } }
      problems = form_problems(document["rules"])
      return Queues::Result.failure(problems) if problems.any?

      default_queue = HelpdeskQueue.find_by(id: default_queue_id, brand_id: brand.id, archived_at: nil)
      ruleset = RoutingRuleset.publish!(brand:, rules: document, default_queue:, created_by:)
      Queues::Result.success(ruleset)
    rescue RoutingRuleset::InvalidRules => e
      Queues::Result.failure(e.violations)
    end

    # Mensagens em português para o que o formulário deixou incompleto (o esquema só diria o ponteiro do JSON).
    def self.form_problems(rules)
      rules.each_with_index.flat_map do |rule, index|
        label = "regra #{index + 1}#{" «#{rule['name']}»" if rule['name'].present?}"
        [ ("#{label}: o nome é obrigatório" if rule["name"].empty?),
          ("#{label}: escolha a fila de destino" if rule["queue_id"].zero?),
          ("#{label}: informe pelo menos uma condição" if rule["any"].empty?) ].compact
      end
    end

    # Linha totalmente vazia do formulário some; as outras viram regra do contrato, mesmo incompletas, para o esquema
    # apontar o que falta.
    def self.convert(row)
      row = row.to_h.stringify_keys
      groups = Array(row["groups"]).filter_map { group(_1) }
      return if row["name"].to_s.strip.empty? && row["queue_id"].to_s.strip.empty? && groups.empty?

      { "name" => row["name"].to_s.strip, "queue_id" => row["queue_id"].to_s.match?(/\A\d+\z/) ? row["queue_id"].to_i : 0, "any" => groups }
    end

    def self.group(row)
      conditions = Array(row.to_h.stringify_keys["conditions"]).filter_map { condition(_1) }
      { "all" => conditions } if conditions.any?
    end

    def self.condition(row)
      row = row.to_h.stringify_keys
      field = row["field"].to_s.strip
      value = row["value"].to_s.strip
      # O select de operador vem preenchido com "eq" mesmo nas linhas extras vazias do formulário.
      return if field.empty? && value.empty?

      op = field == "tags" ? "contains" : row["op"].to_s.strip
      { "field" => field, "op" => op, "value" => LIST_OPS.include?(op) ? value.split(",").map(&:strip).reject(&:empty?) : value }
    end
    private_class_method :convert, :group, :condition, :form_problems
  end
end
