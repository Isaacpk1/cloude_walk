require "time"

module ChannelsMock
  # Rótulos da tela dos cenários de rajada: deslocamento planejado, horário e atraso real de cada passo.
  module ScenarioView
    STATUS = { "queued" => "Na fila", "running" => "Enviando", "finished" => "Terminado" }.freeze

    module_function

    def offset(at) = "+#{format('%.1f', at).tr('.', ',')} s"
    def clock(iso) = iso && Time.iso8601(iso).utc.strftime("%H:%M:%S.%L")
    def status(value) = STATUS.fetch(value, value)

    # Atraso do envio real em relação ao planejado (fila, rede, agendamento da thread).
    def delay(step)
      return nil unless step["sent_at"]

      "+#{((Time.iso8601(step['sent_at']) - Time.iso8601(step['planned_at'])) * 1000).round} ms"
    end
  end
end
