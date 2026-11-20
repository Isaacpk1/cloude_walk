require "json"
require "time"

module AgentMock
  TRACEPARENT = /\A00-(?<trace_id>\h{32})-\h{16}-\h{2}\z/

  # Logs em JSON, uma linha por evento, sempre com trace_id (invariante 13, ADR-009).
  # Nunca recebe o texto do cliente nem o display_name (RN-51): só IDs, decisão e duração.
  class Log
    def initialize(io = $stdout)
      @io = io
      @lock = Mutex.new
    end

    def info(event, **fields) = write("info", event, fields)
    def warn(event, **fields) = write("warn", event, fields)
    def error(event, **fields) = write("error", event, fields)

    def self.trace_id(traceparent) = TRACEPARENT.match(traceparent.to_s)&.[](:trace_id)

    private

    def write(level, event, fields)
      line = JSON.generate({ at: Time.now.utc.iso8601(3), level:, service: "agent-mock", event: }.merge(fields.compact))
      @lock.synchronize { @io.puts(line) }
    end
  end
end
