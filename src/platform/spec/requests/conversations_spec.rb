require "rails_helper"

RSpec.describe "RF-58 / ROADMAP 01: tela de conversas" do
  describe "GET /conversas" do
    it "lista as conversas sintéticas com o selo de origem" do
      get conversations_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Exemplo sintético")
      expect(response.body).to include(conversation_path("exemplo-repasse"))
      expect(response.body).to include(conversation_path("exemplo-corrida-3s"))
      expect(response.body).to include(conversation_path("exemplo-escalacao"))
    end
  end

  describe "GET /conversas/:id" do
    it "mostra as mensagens na ordem do seq, com autor e status da entrega" do
      get conversation_path("exemplo-repasse")

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body.index("seq 1")).to be < body.index("seq 2")
      expect(body).to include("Cliente", "Bot", "Entregue")
      expect(body).to include("Exemplo sintético")
    end

    it "RN-56: mostra o turno superado e quais mensagens entraram em cada turno" do
      get conversation_path("exemplo-corrida-3s")

      expect(response.body).to include("Turno 1", "Superado", "Turno 2", "Aplicado")
      expect(response.body).to include("cobre seq 1 e 2")
    end

    it "mostra o responsável atual e o histórico de escalação" do
      get conversation_path("exemplo-escalacao")

      expect(response.body).to include("Responsável atual")
      expect(response.body).to include("Histórico de escalação")
      expect(response.body).to include("Agente de IA")
    end

    it "responde 404 para uma conversa que não existe" do
      get conversation_path("nao-existe")

      expect(response).to have_http_status(:not_found)
    end

    it "não depende do provedor sintético: mostra o selo da fonte que alimenta a tela" do
      synthetic = SyntheticConversations.new.find("exemplo-repasse")
      real = synthetic.with(source: DataSource::SYSTEM)
      ConversationReader.source = instance_double(SyntheticConversations, find: real)

      get conversation_path("exemplo-repasse")

      expect(response.body).to include("Registro do sistema")
      expect(response.body).not_to include("Exemplo sintético")
    end
  end
end
