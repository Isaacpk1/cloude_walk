# Histograma de latência HTTP por controller#action e classe de status, em memória do processo (RNF-22).
# Rack middleware: mede o tempo de cada requisição e guarda nos baldes do Prometheus. Sem gem externa.
module Metrics
  class RequestHistogram
    BUCKETS = [ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 ].freeze
    IGNORED_PATHS = %w[/metrics /up].freeze
    LOCK = Mutex.new
    DATA = Hash.new { |hash, key| hash[key] = { buckets: Array.new(BUCKETS.size, 0), count: 0, sum: 0.0 } }

    class << self
      def record(action:, status:, seconds:)
        LOCK.synchronize do
          entry = DATA[[ action, status.to_i ]]
          BUCKETS.each_with_index { |upper, index| entry[:buckets][index] += 1 if seconds <= upper }
          entry[:count] += 1
          entry[:sum] += seconds
        end
      end

      def snapshot = LOCK.synchronize { DATA.transform_values(&:deep_dup) }

      def reset! = LOCK.synchronize { DATA.clear }
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) if IGNORED_PATHS.include?(env["PATH_INFO"])

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, headers, body = @app.call(env)
      self.class.record(action: action_for(env), status:, seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      [ status, headers, body ]
    end

    private

    def action_for(env)
      controller = env["action_controller.instance"]
      controller ? "#{controller.controller_path}##{controller.action_name}" : "other"
    end
  end
end
