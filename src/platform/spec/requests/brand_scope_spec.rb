require "rails_helper"

# Bloco 14 (RF-59, RN-52, RN-53, RNF-24): matriz perfil × marca. Quem é da JIM não lê nem altera nada da InfinitePay,
# por nenhuma tela, e a resposta é a mesma de um registro que não existe.
RSpec.describe "RNF-24: matriz perfil × marca", :anonymous do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:ip) { distribution_setup(infinitepay) }
  let!(:jm) { distribution_setup(jim) }
  let!(:ip_case) { waiting_case(brand: infinitepay, queue: ip[:queue], identity: "acc_ip", sla_due_at: Time.current + 1.hour) }
  let!(:jim_case) { waiting_case(brand: jim, queue: jm[:queue], identity: "acc_jim", sla_due_at: Time.current + 1.hour) }
  let!(:ip_analyst) { analyst_in(ip[:team], name: "Ana IP", email: "ana@ip.test") }
  let!(:jim_analyst) { analyst_in(jm[:team], name: "Joe JIM", email: "joe@jim.test") }
  let!(:ip_dead) { DeadLetter.create!(brand: infinitepay, topic: "helpdesk.agent.outbound.v1", partition: 0, kafka_offset: 1, reason: "x", payload: "{}", source: "t") rescue nil }

  def login(user) = sign_in(user)

  describe "analista da JIM" do
    before { login(jim_analyst) }

    it "lista só os casos da JIM, na fila e nas conversas" do
      get human_queue_path
      expect(response.body).to include("queue-ticket-#{jim_case.id}")
      expect(response.body).not_to include("queue-ticket-#{ip_case.id}")
      expect(response.body).not_to include("Ana IP")

      get conversations_path
      expect(response.body).not_to include("acc_ip")
    end

    it "abre o detalhe e a linha do tempo da própria marca, e recebe 404 nos da InfinitePay" do
      get conversation_path(jim_case.id)
      expect(response).to have_http_status(:ok)

      [ conversation_path(ip_case.id), timeline_path(ip_case.id) ].each do |path|
        get path
        expect(response).to have_http_status(:not_found)
      end
      get conversation_path(999_999)
      expect(response).to have_http_status(:not_found)
    end

    it "?marca= de outra marca é 404 na fila" do
      get human_queue_path(marca: "infinitepay")
      expect(response).to have_http_status(:not_found)
    end

    it "não muda a disponibilidade de analista de outra marca, nem sem ?marca=" do
      patch analyst_availability_path(ip_analyst), params: { status: "offline" }

      expect(response).to have_http_status(:not_found)
      expect(ip_analyst.reload.status).to eq("online")
    end

    it "RN-53: DLQ e evals são só do supervisor (404 para o analista)" do
      [ dead_letters_path, evals_path ].each do |path|
        get path
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "supervisor da InfinitePay" do
    let!(:boss) { analyst_in(ip[:team], name: "Chefe IP", email: "boss@ip.test", role: "supervisor") }

    before { login(boss) }

    it "vê DLQ e evals e só da própria marca" do
      get dead_letters_path
      expect(response).to have_http_status(:ok)
      get evals_path
      expect(response).to have_http_status(:ok)
      get human_queue_path(marca: "jim")
      expect(response).to have_http_status(:not_found)
      get conversation_path(jim_case.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "analista com equipes das duas marcas" do
    it "vê as duas" do
      both = analyst_in(ip[:team], email: "both@x.test")
      TeamMembership.create!(user: both, team: jm[:team])
      login(both)

      get human_queue_path

      expect(response.body).to include("queue-ticket-#{ip_case.id}", "queue-ticket-#{jim_case.id}")
    end
  end
end
