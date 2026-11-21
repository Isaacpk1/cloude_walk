require "simplecov"

# Resumo da cobertura no fim da suíte (RNF-27): total e por grupo, no critério de linha.
class CoverageSummary
  def format(result)
    lines = result.groups.map { |name, files| "  #{name}: #{files.covered_percent.floor(2)}% (#{files.size} arquivos)" }
    puts "\nCobertura (linhas): #{result.covered_percent.floor(2)}% no total", *lines
  end
end

# RNF-27: cobertura do domínio >= 70%. `cover` conta também os arquivos que nenhum teste carrega (0%).
# TEST_ENV_NUMBER aqui só separa o banco de cada agente ou job; não é execução paralela. Sem `parallel_tests false`,
# o SimpleCov 1.3 trata o processo como um worker que não é o primeiro e não gera relatório nem .last_run.json.
SimpleCov.start do
  load_profile "test_frameworks"
  parallel_tests false
  enable_coverage :branch
  cover "app/**/*.rb"
  group "Domínio", %w[app/services app/models app/read_models]
  group "Controllers", "app/controllers"
  group "Jobs", "app/jobs"
  formats :html, CoverageSummary.new
  # O mínimo vale na suíte inteira (sem caminhos na linha de comando) e sempre no CI; rodar um arquivo só no
  # ciclo vermelho-verde não falha por cobertura.
  if ENV["CI"] || ARGV.none? { |arg| arg.start_with?("spec") || arg.end_with?(".rb") }
    coverage :line do
      minimum 70
      minimum 70, per: group("Domínio")
    end
  end
end

require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

Rails.root.glob("spec/support/**/*.rb").sort_by(&:to_s).each { |f| require f }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.fixture_paths = [ Rails.root.join("spec/fixtures") ]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers
end
