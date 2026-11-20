module AgentMock
  module Scenarios
    # Uma regra de config/scenarios.yml: palavras-chave → tipo de resposta (ADR-008).
    class Rule
      TYPES = %w[escalate resolve tool_reply reply].freeze

      attr_reader :id, :type, :spec

      def initialize(spec)
        @spec = spec
        @id = spec.fetch("id")
        @type = spec.fetch("type")
        raise Config::Invalid, "regra #{id}: tipo desconhecido #{type}" unless TYPES.include?(type)

        @any = spec.fetch("any")
        @unless_any = spec.fetch("unless_any", [])
      end

      def match?(text) = @any.any? { Text.include_term?(text, _1) } && @unless_any.none? { Text.include_term?(text, _1) }
      def category = spec["category"]
    end
  end
end
