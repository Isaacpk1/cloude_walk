# Disparo de um eval fora do rspec, com o relógio real (ADR-023):
#
#   bin/rails evals:run[corrida-3s]
#   BRAND=jim bin/rails evals:run[corrida-3s]
#
# Imprime o resultado em JSON: status, checagens e os links do painel (/evals/:id e o turno 1 da conversa).
namespace :evals do
  desc "Roda um cenário de eval e grava o resultado em eval_runs (ex.: evals:run[corrida-3s]; BRAND=infinitepay)"
  task :run, [ :scenario ] => :environment do |_task, args|
    scenario = args[:scenario].presence || abort("informe o cenário: bin/rails evals:run[corrida-3s]")
    brand = Brand.find_by(slug: ENV.fetch("BRAND", "infinitepay")) || abort("marca #{ENV.fetch('BRAND', 'infinitepay')} não existe")

    # A saída padrão fica só com o JSON: o aviso de conexão do cliente do Sidekiq (despertador do outbox) vai para o stderr.
    Sidekiq.configure_client { |config| config.logger = Sidekiq::Logger.new($stderr) }
    run = Evals::Runner.call(scenario, brand:)
    output = {
      id: run.id, scenario: run.scenario, status: run.status, brand: brand.slug, ticket_id: run.ticket_id,
      trace_id: run.trace_id, error: run.error, checks: run.checks.map { _1.slice("name", "ok", "expected", "observed") },
      eval_url: "/evals/#{run.id}", turn_url: (run.ticket_id && "/conversas/#{run.ticket_id}#turn-1")
    }
    puts JSON.pretty_generate(output)
  end
end
