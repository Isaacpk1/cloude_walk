require "json"
require "time"

module Broker
  # Logs em JSON, uma linha por evento, sempre com trace_id (invariante 13, ADR-009).
  # Nunca recebe o corpo do webhook: o texto do cliente não vai para o log (RN-51).
  class Log
    def initialize(io = $stdout)
      @io = io
      @lock = Mutex.new
    end

    def info(event, **fields) = write("info", event, fields)
    def warn(event, **fields) = write("warn", event, fields)
    def error(event, **fields) = write("error", event, fields)

    private

    def write(level, event, fields)
      line = JSON.generate({ at: Time.now.utc.iso8601(3), level:, service: "broker", event: }.merge(fields))
      @lock.synchronize { @io.puts(line) }
    end
  end
end
