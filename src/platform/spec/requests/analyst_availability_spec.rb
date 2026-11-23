require "rails_helper"

# Bloco 13, Frontend: painel da fila com responsável e SLA, capacidade dos analistas e disponibilidade (RF-25, RF-27,
# RF-45, RN-25, RN-26, RN-29, RN-30, RN-31). Isolamento por marca (invariante 6) e escape de HTML.
RSpec.describe "Bloco 13: fila com SLA, capacidade e disponibilidade" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:config_ip) { distribution_setup(infinitepay) }
  let!(:config_jim) { distribution_setup(jim) }
  let(:t0) { Time.utc(2026, 11, 24, 13, 0, 0) }
  let(:doc) { Nokogiri::HTML(response.body) }

  around { |example| travel_to(t0) { example.run } }

  def row(ticket) = doc.at_css("#queue-ticket-#{ticket.id}")

  describe "RF-45, RN-25, RN-26: linhas com responsável e SLA" do
    it "mostra na fila, o responsável, o tempo restante, o alerta de 80% e o estouro" do
      waiting = waiting_case(brand: infinitepay, queue: config_ip[:queue], identity: "acc_1", started_at: t0 - 1.minute, sla_due_at: t0 + 5.minutes)
      alerted = waiting_case(brand: infinitepay, queue: config_ip[:queue], identity: "acc_2", started_at: t0 - 9.minutes, sla_due_at: t0 + 1.minute)
      alerted.update_columns(sla_alerted_at: t0 - 1.minute)
      breached = waiting_case(brand: infinitepay, queue: config_ip[:queue], identity: "acc_3", started_at: t0 - 20.minutes, sla_due_at: t0 - 5.minutes)
      breached.update_columns(sla_breached: true)
      ana = analyst_in(config_ip[:team], name: "Ana Souza")
      mine = case_with(ana, brand: infinitepay, queue: config_ip[:queue], identity: "acc_4")

      get human_queue_path

      expect(response).to have_http_status(:ok)
      expect(row(waiting).css(".human-queue__assignee").text).to include("na fila")
      expect(row(waiting).css(".human-queue__sla--ok").text).to include("faltam 5 min 0 s")
      expect(row(alerted).css(".human-queue__sla--alert").text).to include("faltam 1 min 0 s")
      expect(row(breached).css(".human-queue__sla--breached").text).to include("estourado há 5 min 0 s")
      expect(row(mine).css(".human-queue__assignee").text).to include("Ana Souza")
    end

    it "escapa o nome do analista" do
      evil = analyst_in(config_ip[:team], name: %(<script>alert(1)</script>))
      case_with(evil, brand: infinitepay, queue: config_ip[:queue], identity: "acc_1")

      get human_queue_path

      expect(response.body).not_to include("<script>alert(1)")
      expect(response.body).to include("&lt;script&gt;")
    end
  end

  describe "RF-27, RN-30: capacidade dos analistas" do
    it "lista cada analista com status e vagas usadas, só da marca pedida" do
      analyst_in(config_ip[:team], name: "Ana IP", capacity: 3, active_count: 2)
      analyst_in(config_jim[:team], name: "Joe JIM", status: "pausa")

      get human_queue_path(marca: "infinitepay")

      cards = doc.css(".analyst-capacity__row")
      expect(cards.size).to eq(1)
      expect(cards.first.text).to include("Ana IP", "online", "2 / 3")
      expect(response.body).not_to include("Joe JIM")
    end

    it "sem marca, as duas marcas" do
      analyst_in(config_ip[:team], name: "Ana IP")
      analyst_in(config_jim[:team], name: "Joe JIM")

      get human_queue_path

      expect(doc.css(".analyst-capacity__row").map { _1.at_css(".analyst-capacity__name").text }).to contain_exactly("Ana IP", "Joe JIM")
    end

    it "avisa quando a marca tem casos esperando e nenhum analista online" do
      waiting_case(brand: infinitepay, queue: config_ip[:queue], identity: "acc_1", started_at: t0, sla_due_at: t0 + 1.hour)
      analyst_in(config_ip[:team], status: "offline")

      get human_queue_path(marca: "infinitepay")

      expect(doc.css(".analyst-capacity__alert").text).to include("nenhum analista online")
    end
  end

  describe "RF-27: PATCH /analistas/:id/disponibilidade" do
    let!(:ana) { analyst_in(config_ip[:team], name: "Ana IP") }

    it "muda o status, audita e volta para a fila da marca" do
      patch analyst_availability_path(ana, marca: "infinitepay"), params: { status: "pausa" }

      expect(response).to redirect_to(human_queue_path(marca: "infinitepay"))
      expect(ana.reload.status).to eq("pausa")
      expect(AuditEvent.where(event_type: "analyst.availability_changed").count).to eq(1)
    end

    it "status inválido: 422 e nada muda" do
      patch analyst_availability_path(ana), params: { status: "ausente" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(ana.reload.status).to eq("online")
    end

    it "marca errada: analista de outra marca é 404" do
      patch analyst_availability_path(ana, marca: "jim"), params: { status: "offline" }

      expect(response).to have_http_status(:not_found)
      expect(ana.reload.status).to eq("online")
    end

    it "usuário inexistente ou que não é analista humano: 404" do
      patch analyst_availability_path(0), params: { status: "offline" }
      expect(response).to have_http_status(:not_found)

      ana.update_columns(kind: "bot")
      patch analyst_availability_path(ana), params: { status: "offline" }
      expect(response).to have_http_status(:not_found)
    end
  end
end
