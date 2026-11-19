# Uma linha de log em JSON, com trace_id (invariante 13, ADR-009). Nunca recebe o texto do cliente
# nem o payload do evento (RN-51): só identificadores, estados e motivos.
module JsonLog
  module_function

  def info(event, **fields) = Rails.logger.info(line("info", event, fields))
  def warn(event, **fields) = Rails.logger.warn(line("warn", event, fields))

  def line(level, event, fields)
    JSON.generate({ at: Time.current.utc.iso8601(3), level:, service: "platform", event: }.merge(fields))
  end
end
