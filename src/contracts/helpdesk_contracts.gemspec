require_relative "lib/helpdesk_contracts/version"

Gem::Specification.new do |spec|
  spec.name = "helpdesk_contracts"
  spec.version = HelpdeskContracts::VERSION
  spec.summary = "Contratos versionados (JSON Schema) do help desk CloudWalk"
  spec.description = "Esquemas JSON e validador único dos contratos entre canais, plataforma, broker e agente (07, seção 5; RNF-28)."
  spec.authors = [ "Help desk CloudWalk" ]
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "v*/schemas/**/*.json", "README.md"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "json_schemer", "~> 2.4"
end
