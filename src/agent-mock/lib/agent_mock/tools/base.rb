require "date"

module AgentMock
  module Tools
    # Uma consulta feita pela IA, como vai em tool_calls (07, seção 5.3; RF-54).
    Call = Data.define(:tool, :args, :result, :duration_ms) do
      def to_h = { "tool" => tool, "args" => args, "result" => result, "duration_ms" => duration_ms }
    end

    # Consulta sintética e local: sem banco e sem rede (invariante 12). O resultado sai de um hash
    # da semente e dos argumentos, então a mesma consulta dá sempre o mesmo resultado (RNF-30).
    # Só consultas: nenhuma tool movimenta dinheiro ou altera cadastro (RN-35).
    class Base
      def self.tool_name = name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

      def initialize(seed:) = @seed = seed

      def call(args)
        Call.new(tool: self.class.tool_name, args:, result: result_for(args), duration_ms: number(args, "duration", 80..400))
      end

      private

      def number(args, salt, range) = Seeded.random(@seed, self.class.tool_name, args, salt).rand(range)
      def pick(args, salt, list) = list.fetch(number(args, salt, 0...list.size))
      def cents(args, salt, range) = number(args, salt, range) / 100.0
    end
  end
end
