require "rails_helper"

RSpec.describe "RNF-22: /metrics no formato do Prometheus", :anonymous do
  after { ENV.delete("METRICS_TOKEN") }

  it "expõe fila do outbox, turnos, entregas e falhas" do
    get "/metrics"

    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to include("text/plain", "version=0.0.4")
    expect(response.body).to include("# TYPE helpdesk_outbox_pending gauge", "helpdesk_outbox_pending ", "helpdesk_dead_letters_total ")
  end

  it "expõe o histograma de latência com as requisições já feitas" do
    Metrics::RequestHistogram.reset!
    get "/"
    get "/metrics"

    expect(response.body).to include("# TYPE helpdesk_http_request_duration_seconds histogram")
    expect(response.body).to match(/helpdesk_http_request_duration_seconds_count\{action="[^"]+",status="\d+"\} 1/)
  end

  it "não conta a própria leitura de /metrics" do
    Metrics::RequestHistogram.reset!
    get "/metrics"

    expect(Metrics::RequestHistogram.snapshot).to be_empty
  end

  it "exige o token quando METRICS_TOKEN está definido" do
    ENV["METRICS_TOKEN"] = "segredo-sintetico"

    get "/metrics"
    expect(response).to have_http_status(:unauthorized)

    get "/metrics", headers: { "Authorization" => "Bearer segredo-sintetico" }
    expect(response).to have_http_status(:ok)
  end
end
