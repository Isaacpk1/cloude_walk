# Histograma de latência HTTP para o /metrics (RNF-22). Fica em lib/ para não ser recarregado em desenvolvimento.
require Rails.root.join("lib/metrics/request_histogram")

Rails.application.config.middleware.use Metrics::RequestHistogram
