# Stub mínimo do Routing::Evaluate do agente G2 (bloco 11), só para os testes enquanto o real não chega a este
# worktree. Segue a interface do common11.md: sem conjunto de regras, a fila `is_default` ativa da marca, com a versão
# corrente, `ruleset_version: nil` e `default: true`; sem fila, `queue: nil`. Com o real na base (Zeitwerk o carrega
# no `defined?`), este arquivo não define nada.
unless defined?(Routing::Evaluate)
  module Routing
    Decision = Data.define(:queue, :queue_version, :queue_name, :ruleset_version, :rule_index, :rule_name, :group_index, :conditions,
                           :default, :skipped_rules) do
      def initialize(rule_index: nil, rule_name: nil, group_index: nil, conditions: [], skipped_rules: [], **) = super
    end

    class Evaluate
      def self.call(brand:, attributes:) # rubocop:disable Lint/UnusedMethodArgument
        queue = HelpdeskQueue.where(brand_id: brand.id, active: true, is_default: true).order(:id).first
        version = queue&.current_version
        Decision.new(queue:, queue_version: version&.version, queue_name: version&.name, ruleset_version: nil, default: true)
      end
    end
  end
end
