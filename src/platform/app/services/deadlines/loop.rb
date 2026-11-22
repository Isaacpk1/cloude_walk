# Laço do scheduler (bin/scheduler; ADR-016; 07, seção 2). Consulta os prazos vencidos a cada 250 ms: abertura
# de turno (DispatchDue) e aviso de progresso (ProgressDue, RN-57).
# Lote cheio: volta sem dormir, para escoar o atraso. Erro numa volta (Postgres ou Redis fora) é
# registrado e o laço segue. stop! só levanta uma flag, então pode ser chamado de um trap de sinal: o
# laço termina a volta em curso e sai (desligamento gracioso).
#
# Sinal de vida (RNF-29): com SCHEDULER_HEARTBEAT_FILE, cada volta que consulta o banco com sucesso
# renova o arquivo. O healthcheck do Compose confere a idade dele: o `up --wait` só termina com o
# scheduler pronto, e um scheduler travado ou sem banco aparece como unhealthy.
module Deadlines
  class Loop
    DEFAULT_INTERVAL = 0.25
    DEFAULT_BATCH = 100

    attr_reader :interval, :batch, :heartbeat

    def self.from_env(env = ENV)
      new(interval: Float(env.fetch("SCHEDULER_INTERVAL", DEFAULT_INTERVAL.to_s)),
          batch: Integer(env.fetch("SCHEDULER_BATCH", DEFAULT_BATCH.to_s)),
          heartbeat: env["SCHEDULER_HEARTBEAT_FILE"].presence)
    end

    def initialize(interval: DEFAULT_INTERVAL, batch: DEFAULT_BATCH, sleeper: ->(seconds) { sleep(seconds) }, heartbeat: nil)
      @interval = interval
      @batch = batch
      @sleeper = sleeper
      @heartbeat = heartbeat
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
      emitted = Rails.application.executor.wrap do
        now = Time.current
        # Uma consulta por tipo de prazo, cada uma no seu serviço (ADR-016). A soma decide se o lote encheu.
        [
          DispatchDue.call(now:, limit: batch),
          ProgressDue.call(now:, limit: batch) # RN-57
        ].sum(&:size)
      end
      beat
      emitted
    rescue StandardError => e
      JsonLog.warn("scheduler.tick_failed", error: e.class.name)
      0
    end

    private

    def beat
      return unless heartbeat

      FileUtils.touch(heartbeat, mtime: Time.current.to_time)
    end
  end
end
