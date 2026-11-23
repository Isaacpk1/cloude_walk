# Cenários de eval conhecidos (ADR-023). O painel de evals lista estes cenários, inclusive os que nunca rodaram.
#
#   Evals::Catalog.scenarios           # => [{ name: "corrida-3s", title:, description: }]
#   Evals::Catalog.fetch("corrida-3s") # => Evals::Scenarios::CorridaTresSegundos
module Evals
  module Catalog
    UnknownScenario = Class.new(ArgumentError)

    module_function

    def registry = { Scenarios::CorridaTresSegundos::NAME => Scenarios::CorridaTresSegundos }.freeze

    def scenarios
      registry.values.map { { name: _1::NAME, title: _1::TITLE, description: _1::DESCRIPTION } }
    end

    def fetch(name)
      registry.fetch(name.to_s) do
        raise UnknownScenario, "cenário de eval desconhecido: #{name.inspect} (conhecidos: #{registry.keys.join(', ')})"
      end
    end
  end
end
