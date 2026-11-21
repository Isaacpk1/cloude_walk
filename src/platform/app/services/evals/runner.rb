# Executor de um eval (ADR-023; RNF-30; 09, seção 4, "checagens determinísticas").
#
#   Evals::Runner.call("corrida-3s", brand: Brand.find_by!(slug: "infinitepay")) # => EvalRun gravado
#
# Roda o cenário pelo caminho real da plataforma e grava UMA linha em eval_runs no fim (só inserção).
# `status`: passed (todas as checagens ok), failed (alguma não) ou error (o cenário levantou; o que foi
# observado até ali vai em `observed` e a mensagem em `error`).
#
# Relógio e espera são injetáveis. Em produção: Time.current e sleep até o próximo passo. Nos testes: um
# relógio controlado por travel_to e um sleeper que só avança o relógio.
module Evals
  class Runner
    REAL_CLOCK = -> { Time.current }
    REAL_SLEEPER = ->(seconds) { sleep(seconds) if seconds.positive? }

    def self.call(...) = new(...).call

    def initialize(name, brand:, clock: REAL_CLOCK, sleeper: REAL_SLEEPER)
      @scenario_class = Catalog.fetch(name)
      @brand = brand
      @clock = clock
      @sleeper = sleeper
    end

    def call
      started_at = @clock.call
      scenario = @scenario_class.new(brand: @brand, clock: @clock, sleeper: @sleeper)
      error = run(scenario)
      record(scenario, started_at, error)
    end

    private

    def run(scenario)
      scenario.run
      nil
    rescue StandardError => e
      JsonLog.warn("eval.error", trace_id: scenario.trace_id, scenario: @scenario_class::NAME, error: e.class.name)
      "#{e.class.name}: #{e.message}"
    end

    def record(scenario, started_at, error)
      observed = scenario.observed
      checks = scenario.checks
      status = if error then "error"
      elsif checks.all? { _1[:ok] } then "passed"
      else "failed"
      end
      run = EvalRun.create!(
        scenario: @scenario_class::NAME, status:, agent_model: @scenario_class::AGENT_MODEL,
        agent_version: @scenario_class::FIXTURE_VERSION, config_hash: @scenario_class.config_hash,
        expected: @scenario_class.expected, observed:, checks:, brand: @brand, ticket_id: scenario.ticket&.id,
        trace_id: scenario.trace_id, error:, started_at:, finished_at: @clock.call
      )
      JsonLog.info("eval.finished", trace_id: scenario.trace_id, scenario: run.scenario, eval_run_id: run.id, status:,
                                    brand: @brand.slug, ticket_id: run.ticket_id,
                                    failed_checks: checks.reject { _1[:ok] }.map { _1[:name] })
      run
    end
  end
end
