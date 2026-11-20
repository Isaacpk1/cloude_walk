# Laço da recuperação do outbox dentro do processo do worker (Outbox::Recover a cada segundo).
# Provisório: o scheduler do bloco 08 (bin/scheduler, ADR-016) assume a varredura. Várias réplicas
# do worker podem rodar o laço juntas: a reserva do item impede trabalho em dobro.
module Outbox
  class Sweeper
    INTERVAL = Float(ENV.fetch("OUTBOX_SWEEP_INTERVAL", "1"))

    class << self
      def start(interval: INTERVAL)
        @stop = false
        @thread ||= Thread.new do
          until @stop
            run_once
            sleep interval
          end
        end
      end

      def stop
        @stop = true
        @thread&.join(INTERVAL * 2)
        @thread = nil
      end

      def run_once
        Rails.application.executor.wrap { Recover.call }
      rescue StandardError => e
        JsonLog.warn("outbox.sweep_failed", error: e.class.name)
      end
    end
  end
end
