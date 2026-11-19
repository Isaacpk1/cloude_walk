# Laço do scheduler (bin/scheduler; ADR-016; 07, seção 2). Consulta os prazos vencidos a cada 250 ms.
# Lote cheio: volta sem dormir, para escoar o atraso. Erro numa volta (Postgres ou Redis fora) é
# registrado e o laço segue. stop! só levanta uma flag, então pode ser chamado de um trap de sinal: o
# laço termina a volta em curso e sai (desligamento gracioso).
module Deadlines
  class Loop
    DEFAULT_INTERVAL = 0.25
    DEFAULT_BATCH = 100

    attr_reader :interval, :batch

    def self.from_env(env = ENV)
      new(interval: Float(env.fetch("SCHEDULER_INTERVAL", DEFAULT_INTERVAL.to_s)),
          batch: Integer(env.fetch("SCHEDULER_BATCH", DEFAULT_BATCH.to_s)))
    end

    def initialize(interval: DEFAULT_INTERVAL, batch: DEFAULT_BATCH, sleeper: ->(seconds) { sleep(seconds) })
      @interval = interval
      @batch = batch
      @sleeper = sleeper
      @stop = false
    end

    def run
      JsonLog.info("scheduler.started", interval:, batch:)
      until @stop
        emitted = tick
        @sleeper.call(interval) if emitted < batch && !@stop
      end
      JsonLog.info("scheduler.stopped")
    end

    def stop! = @stop = true

    def stopped? = @stop

    # Devolve quantos itens a volta emitiu (0 em caso de erro, para dormir antes de tentar de novo).
    def tick
      Rails.application.executor.wrap { DispatchDue.call(now: Time.current, limit: batch).size }
    rescue StandardError => e
      JsonLog.warn("scheduler.tick_failed", error: e.class.name)
      0
    end
  end
end
