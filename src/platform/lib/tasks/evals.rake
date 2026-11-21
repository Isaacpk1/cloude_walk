# Disparo de um eval fora do rspec, com o relógio real (ADR-023):
#
#   bin/rails evals:run[corrida-3s]
#   BRAND=jim bin/rails evals:run[corrida-3s]
#
# Imprime o resultado em JSON: status, checagens e os links do painel (/evals/:id e o turno 1 da conversa).
# A saída padrão fica só com o JSON: com RAILS_LOG_TO_STDOUT (o Compose define), o log da aplicação, o do SQL,
# o do ActiveJob e o do cliente do Sidekiq vão para o stderr durante a execução. Sem ela, o log já vai para o
# arquivo do ambiente; só o aviso de conexão do cliente do Sidekiq iria para o stdout.
module EvalsTaskLogs
  module_function

  def to_stderr(&)
    Sidekiq.configure_client { |config| config.logger = Sidekiq::Logger.new($stderr) }
    return yield if ENV["RAILS_LOG_TO_STDOUT"].blank?

    loggers = [ Rails.logger, ActiveRecord::Base.logger, ActiveJob::Base.logger ]
    stderr = ActiveSupport::TaggedLogging.logger($stderr).tap { _1.level = Rails.logger.level }
    Rails.logger = ActiveRecord::Base.logger = ActiveJob::Base.logger = stderr
    yield
  ensure
    Rails.logger, ActiveRecord::Base.logger, ActiveJob::Base.logger = loggers if loggers
  end
end

namespace :evals do
  desc "Roda um cenário de eval e grava o resultado em eval_runs (ex.: evals:run[corrida-3s]; BRAND=infinitepay)"
  task :run, [ :scenario ] => :environment do |_task, args|
    scenario = args[:scenario].presence || abort("informe o cenário: bin/rails evals:run[corrida-3s]")
    slug = ENV.fetch("BRAND", "infinitepay")
    run, brand = EvalsTaskLogs.to_stderr do
      brand = Brand.find_by(slug:) || abort("marca #{slug} não existe")
      [ Evals::Runner.call(scenario, brand:), brand ]
    end
    output = {
      id: run.id, scenario: run.scenario, status: run.status, brand: brand.slug, ticket_id: run.ticket_id,
      trace_id: run.trace_id, error: run.error, checks: run.checks.map { _1.slice("name", "ok", "expected", "observed") },
      eval_url: "/evals/#{run.id}", turn_url: (run.ticket_id && "/conversas/#{run.ticket_id}#turn-1")
    }
    puts JSON.pretty_generate(output)
  end
end
