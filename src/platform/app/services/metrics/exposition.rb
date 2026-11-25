# Texto no formato do Prometheus com os sinais do experimento (RNF-22): fila do outbox, turnos, entregas e falhas,
# mais o histograma de latência HTTP. Só agregados: nada de dado de cliente nem de marca (invariante 6, RNF-25).
module Metrics
  module Exposition
    module_function

    def call
      lines = []
      gauge(lines, "helpdesk_outbox_pending", "Eventos do outbox ainda não concluídos", OutboxEvent.where(completed_at: nil).count)
      gauge(lines, "helpdesk_outbox_unpublished", "Eventos do outbox ainda não publicados", OutboxEvent.where(published_at: nil).count)
      gauge(lines, "helpdesk_outbox_oldest_pending_seconds", "Idade do evento pendente mais antigo", oldest_pending_seconds)
      grouped(lines, "helpdesk_ai_turns", "Turnos da IA por estado", AiTurn.group(:status).count)
      grouped(lines, "helpdesk_deliveries", "Entregas ao canal por estado", Delivery.group(:status).count)
      gauge(lines, "helpdesk_dead_letters_total", "Falhas na DLQ", DeadLetter.count)
      gauge(lines, "helpdesk_messages_inbound_total", "Mensagens de entrada gravadas", Message.where(direction: "inbound").count)
      histogram(lines)
      lines.join("\n") << "\n"
    end

    def oldest_pending_seconds
      oldest = OutboxEvent.where(completed_at: nil).minimum(:created_at)
      oldest ? [ Time.current - oldest, 0 ].max.round(3) : 0
    end

    def gauge(lines, name, help, value)
      lines << "# HELP #{name} #{help}" << "# TYPE #{name} gauge" << "#{name} #{value}"
    end

    def grouped(lines, name, help, counts)
      lines << "# HELP #{name} #{help}" << "# TYPE #{name} gauge"
      counts.each { |status, total| lines << %(#{name}{status="#{status}"} #{total}) }
    end

    def histogram(lines)
      name = "helpdesk_http_request_duration_seconds"
      lines << "# HELP #{name} Latência das requisições HTTP da plataforma" << "# TYPE #{name} histogram"
      Metrics::RequestHistogram.snapshot.each do |(action, status), entry|
        labels = %(action="#{action}",status="#{status}")
        Metrics::RequestHistogram::BUCKETS.each_with_index do |upper, index|
          lines << %(#{name}_bucket{#{labels},le="#{upper}"} #{entry[:buckets][index]})
        end
        lines << %(#{name}_bucket{#{labels},le="+Inf"} #{entry[:count]})
        lines << %(#{name}_sum{#{labels}} #{entry[:sum].round(6)})
        lines << %(#{name}_count{#{labels}} #{entry[:count]})
      end
    end
  end
end
