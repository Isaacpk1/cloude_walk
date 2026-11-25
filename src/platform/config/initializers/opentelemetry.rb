# Traces OpenTelemetry (ADR-009). Só liga com OTEL_EXPORTER_OTLP_ENDPOINT definido e com as gems instaladas
# (infra/observability/README.md). Sem isso não faz nada, e o traceparent W3C do projeto segue como está.
if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].present?
  begin
    require "opentelemetry/sdk"
    require "opentelemetry/exporter/otlp"
    require "opentelemetry/instrumentation/all"

    OpenTelemetry::SDK.configure do |config|
      config.service_name = ENV.fetch("OTEL_SERVICE_NAME", "helpdesk-platform")
      config.use_all
    end
  rescue LoadError => error
    Rails.logger&.warn("opentelemetry indisponível: #{error.message}")
  end
end
