# GET /metrics para o Prometheus (RNF-22). Sem login: é lido pela rede interna do Compose.
# Com METRICS_TOKEN definido, exige "Authorization: Bearer <token>".
class MetricsController < ActionController::Base
  def show
    token = ENV["METRICS_TOKEN"].presence
    return head :unauthorized if token && !ActiveSupport::SecurityUtils.secure_compare(request.authorization.to_s, "Bearer #{token}")

    render plain: Metrics::Exposition.call, content_type: "text/plain; version=0.0.4"
  end
end
