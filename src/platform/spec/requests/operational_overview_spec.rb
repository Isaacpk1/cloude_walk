require "rails_helper"

RSpec.describe "RF-60, RNF-24: indicadores do supervisor na fila", :anonymous do
  let!(:brand) { create(:brand, :infinitepay) }
  let!(:other) { create(:brand, :jim) }
  let!(:setup) { distribution_setup(brand, queue_name: "Repasses") }
  let!(:boss) { analyst_in(setup[:team], role: "supervisor") }
  let!(:analyst) { analyst_in(setup[:team]) }

  it "mostra população, janela, numerador, denominador e espera; não expõe outra marca" do
    freeze_time do
      waiting_case(brand:, queue: setup[:queue], identity: "acc_ops", started_at: 60.seconds.ago, sla_due_at: Time.current)
      foreign = distribution_setup(other, queue_name: "Segredo JIM")
      waiting_case(brand: other, queue: foreign[:queue], identity: "acc_foreign")
      sign_in(boss)

      get human_queue_path

      html = Nokogiri::HTML(response.body)
      panel = html.at_css(".operational-overview")
      expect(panel).to be_present
      expect(panel.text.squish).to include("Repasses", "Últimas 24 horas", "0 / 1", "60 s", "Abertos")
      expect(panel.text).not_to include("Segredo JIM")
      expect(panel.css("time").size).to eq(3)
    end
  end

  it "RN-53: o analista continua com a fila, sem o painel do supervisor" do
    sign_in(analyst)
    get human_queue_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('class="operational-overview"')
  end

  it "RF-60: a ausência de coorte é explícita e não quebra a fila vazia" do
    sign_in(boss)
    get human_queue_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Sem dados", "Nenhum caso aguardando humano")
    get human_queue_path(marca: other.slug)
    expect(response).to have_http_status(:not_found)
  end
end
