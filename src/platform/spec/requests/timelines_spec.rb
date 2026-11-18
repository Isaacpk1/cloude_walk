require "rails_helper"

RSpec.describe "RF-56 / ROADMAP 01: linha do tempo" do
  describe "GET /linha-do-tempo" do
    it "lista as conversas com link para a linha do tempo de cada uma" do
      get timelines_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(timeline_path("exemplo-repasse"))
      expect(response.body).to include("Exemplo sintético")
    end
  end

  describe "GET /linha-do-tempo/:id" do
    it "mostra as etapas do fluxo com duração calculada" do
      get timeline_path("exemplo-repasse")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        "Recebimento", "Gravação", "Espera intencional", "Publicação",
        "Execução do agente", "Aplicação da resposta", "Entrega ao canal"
      )
      expect(response.body).to include("2000 ms")
    end

    it "liga cada evento ao ticket, seq, turno e trace_id e marca a origem em cada um" do
      get timeline_path("exemplo-repasse")
      timeline = SyntheticConversations.new.timeline("exemplo-repasse")

      expect(response.body).to include(timeline.ticket_id, timeline.events.first.trace_id)
      expect(response.body.scan("Exemplo sintético").size).to be > timeline.events.size
    end

    it "RN-56: mostra o descarte da resposta superada" do
      get timeline_path("exemplo-corrida-3s")

      expect(response.body).to include("Descarte da resposta")
    end

    it "responde 404 para uma conversa que não existe" do
      get timeline_path("nao-existe")

      expect(response).to have_http_status(:not_found)
    end
  end
end
