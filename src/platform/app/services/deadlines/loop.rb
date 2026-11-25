# Laço do scheduler (bin/scheduler; ADR-016; 07, seção 2). Consulta os prazos vencidos a cada 250 ms: abertura
# de turno (DispatchDue), aviso de progresso (ProgressDue, RN-57), alertas de SLA (RN-25, RN-26), analista offline
# (RN-31) e a distribuição da fila humana (Distribution::Run, RN-30).
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
    # Prazos consultados a cada volta, cada um no seu serviço (ADR-016). Uma linha por prazo, no fim da lista.
    REGISTRATIONS = [
      "Deadlines::DispatchDue",
      "Deadlines::TurnTimeout",
      "Deadlines::CycleTimeout",
      "Deadlines::ProgressDue", # RN-57
      "Deadlines::SlaAlert", # RN-25
      "Deadlines::SlaBreach", # RN-26
      "Deadlines::AnalystOffline", # RN-31
      "Deadlines::CustomerInactivity", # RN-07: antes do lembrete atrasado
      "Deadlines::CustomerReminder", # RN-07
      "Deadlines::TicketClose", # RN-09
      "Distribution::Run" # RN-30: depois dos prazos, para a ordem da fila já refletir os alertas (só Postgres, sem outbox)
    ].freeze

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
        REGISTRATIONS.sum { _1.constantize.call(now:, limit: batch).size }
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
