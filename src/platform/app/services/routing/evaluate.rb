# Avaliador das regras de roteamento (interface do bloco 11; RF-15, RN-15, RN-16, ADR-003, ADR-013).
#
#   Routing::Evaluate.call(brand:, attributes: { "channel" =>, "category" =>, "priority" =>, "tags" => [] })
#   # => Routing::Decision
#
# As regras são avaliadas na ordem do conjunto e a primeira que casa decide (RN-16). Uma regra casa se algum grupo
# (OU) tiver todas as condições (E) verdadeiras. Regra que casa mas aponta para fila inativa ou fora da marca é
# pulada e registrada (RN-15). Nenhuma regra: fila padrão do conjunto; se ela estiver inativa, ou sem conjunto na
# marca, a fila is_default ativa da marca. Só leitura, sem efeito. Toda consulta filtra pela marca (invariante 6), e
# o atributo "brand" é sempre o slug da própria marca, não o informado.
module Routing
  class Evaluate
    SCALAR_OPS = {
      "eq" => ->(actual, value) { actual == value },
      "neq" => ->(actual, value) { actual != value },
      "in" => ->(actual, value) { value.include?(actual) },
      "not_in" => ->(actual, value) { !value.include?(actual) }
    }.freeze

    class << self
      def cache = @cache ||= RulesetCache.new

      def call(brand:, attributes:) = new(brand:, attributes:).call
    end

    def initialize(brand:, attributes:)
      @brand = brand
      @attributes = attributes.to_h.stringify_keys.merge("brand" => brand.slug)
    end

    def call
      ruleset = self.class.cache.fetch(@brand)
      rules = ruleset&.rules || []
      queues = queues_for(rules, ruleset)
      skipped = []

      rules.each_with_index do |rule, index|
        group_index = rule["any"].index { |group| group["all"].all? { matches?(_1) } }
        next if group_index.nil?

        queue = queues[rule["queue_id"]]
        reason = skip_reason(queue)
        if reason
          skipped << { "rule_index" => index, "rule_name" => rule["name"], "queue_id" => rule["queue_id"], "reason" => reason }
          next
        end

        return decision(queue, ruleset, rule_index: index, rule_name: rule["name"], group_index:,
                                        conditions: rule["any"][group_index]["all"], default: false, skipped:)
      end

      decision(default_queue(queues, ruleset), ruleset, rule_index: nil, rule_name: nil, group_index: nil, conditions: [],
                                                        default: true, skipped:)
    end

    private

    # Uma consulta: as filas das regras, a padrão do conjunto e a is_default, todas da marca, com a versão corrente.
    def queues_for(rules, ruleset)
      ids = [ *rules.map { _1["queue_id"] }, ruleset&.default_queue_id ].compact.uniq
      HelpdeskQueue.where(brand_id: @brand.id).where("queues.id IN (?) OR queues.is_default", ids.presence || [ 0 ])
                   .includes(:current_version).index_by(&:id)
    end

    def skip_reason(queue)
      return "fila_fora_da_marca" if queue.nil? || queue.brand_id != @brand.id

      "fila_inativa" unless queue.active?
    end

    def default_queue(queues, ruleset)
      chosen = ruleset && queues[ruleset.default_queue_id]
      return chosen if chosen && skip_reason(chosen).nil?

      queues.each_value.find { _1.is_default && _1.active? && _1.brand_id == @brand.id }
    end

    def matches?(condition)
      field, op, value = condition.values_at("field", "op", "value")
      actual = @attributes[field]
      return Array(actual).include?(value) if op == "contains"

      SCALAR_OPS.fetch(op).call(actual, value)
    end

    def decision(queue, ruleset, skipped:, **explanation)
      Decision.new(queue:, queue_version: queue&.current_version&.version, ruleset_version: ruleset&.version,
                   skipped_rules: skipped, **explanation)
    end
  end
end
