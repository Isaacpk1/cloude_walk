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

  describe "ROADMAP 03: origem do erro ao escolher o evento" do
    let!(:brand) { create(:brand, :infinitepay) }

    def failed_ticket
      received = ingest("meu repasse não caiu")
      event_id = open_turn_for(received).event_id
      stub_request(:post, BrokerHelpers::BROKER_URL).to_raise(Errno::ECONNREFUSED)
      Outbox::Publish.call(event_id)
      received.ticket
    end

    it "mostra a etapa de publicação e um link para escolher cada evento" do
      ticket = failed_ticket

      get timeline_path(ticket.id)

      expect(response.body).to include("Publicação no broker", "Falha na publicação")
      expect(response.body).to include(timeline_path(ticket.id, evento: 3))
    end

    it "ao escolher a falha, mostra a origem do erro, a tentativa e o trace_id" do
      ticket = failed_ticket
      index = ConversationReader.timeline(ticket.id.to_s).events.index { _1.kind == :publish_failed } + 1

      get timeline_path(ticket.id, evento: index)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Evento escolhido", "Origem do erro", "Broker fora do ar", "Tentativa",
                                       ticket.messages.first.trace_id)
    end

    it "evento sem erro escolhido diz que não houve erro" do
      ticket = failed_ticket

      get timeline_path(ticket.id, evento: 1)

      expect(response.body).to include("Evento escolhido", "Sem erro registrado")
    end

    it "evento inexistente não quebra a página" do
      get timeline_path(failed_ticket.id, evento: 99)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Evento escolhido")
    end
  end

  it "ROADMAP 03: nos exemplos sintéticos, o link do evento abre a mesma conversa" do
    get timeline_path("exemplo-repasse")

    expect(response.body).to include(timeline_path("exemplo-repasse", evento: 1))
    get timeline_path("exemplo-repasse", evento: 1)
    expect(response.body).to include("Evento escolhido")
  end
end
