require "rails_helper"

# Bloco 14, Frontend (RF-46 a RF-49, RN-50, RN-52, RNF-24): o analista responde, anota e resolve no navegador.
RSpec.describe "Bloco 14: atendimento pelo analista no navegador", :anonymous do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:ip) { distribution_setup(infinitepay) }
  let!(:jm) { distribution_setup(jim) }
  let!(:ana) { analyst_in(ip[:team], name: "Ana Souza", email: "ana@ip.test") }
  let!(:ticket) { case_with(ana, brand: infinitepay, queue: ip[:queue], identity: "acc_1") }
  let(:doc) { Nokogiri::HTML(response.body) }

  before { sign_in(ana) }

  it "RF-46, RF-48: o responsável vê os formulários de resposta, nota e resolução" do
    get conversation_path(ticket.id)

    expect(doc.css("form.analyst-reply textarea").size).to eq(1)
    expect(doc.css("form.analyst-note textarea").size).to eq(1)
    expect(doc.css("form.analyst-resolve select option").map { _1["value"] }).to include("problema_resolvido", "duvida_respondida")
  end

  it "quem não é o responsável não vê os formulários" do
    bia = analyst_in(ip[:team], email: "bia@ip.test")
    delete logout_path
    sign_in(bia)

    get conversation_path(ticket.id)

    expect(response).to have_http_status(:ok)
    expect(doc.css(".analyst-actions")).to be_empty
  end

  it "RF-46: responder grava a mensagem, mostra na conversa e acorda o envio" do
    expect do
      post conversation_reply_path(ticket.id), params: { text: "Oi, já estou vendo." }
    end.to have_enqueued_job(OutboxJob)

    expect(response).to redirect_to(conversation_path(ticket.id))
    follow_redirect!
    expect(response.body).to include("Oi, já estou vendo.", "Ana Souza")
  end

  it "RN-50: a nota aparece só no painel, marcada como interna, e não gera entrega" do
    post conversation_note_path(ticket.id), params: { text: "Cliente ligou três vezes" }
    follow_redirect!

    expect(response.body).to include("Cliente ligou três vezes", "nota interna")
    expect(Delivery.count).to eq(0)
  end

  it "RF-48: resolver fecha o caso e some os formulários" do
    post conversation_resolution_path(ticket.id), params: { reason: "problema_resolvido", text: "Tudo certo." }
    follow_redirect!

    expect(ticket.reload.state).to eq("resolvido")
    expect(doc.css(".analyst-actions")).to be_empty
    expect(response.body).to include("resolvido")
  end

  it "erro de validação volta com a mensagem visível" do
    post conversation_reply_path(ticket.id), params: { text: " " }
    follow_redirect!

    expect(doc.css(".flash--alert").text).to include("texto")
    expect(Message.where(direction: "outbound")).to be_empty
  end

  it "RNF-24: conta de outra marca recebe 404 ao agir e nada é gravado" do
    joe = analyst_in(jm[:team], email: "joe@jim.test")
    delete logout_path
    sign_in(joe)

    post conversation_reply_path(ticket.id), params: { text: "intruso" }
    expect(response).to have_http_status(:not_found)
    post conversation_note_path(ticket.id), params: { text: "intruso" }
    expect(response).to have_http_status(:not_found)
    post conversation_resolution_path(ticket.id), params: { reason: "outro" }
    expect(response).to have_http_status(:not_found)
    expect(Message.where(direction: "outbound")).to be_empty
    expect(ticket.reload.state).to eq("com_analista")
  end

  it "sem login, as ações mandam para o login" do
    delete logout_path

    post conversation_reply_path(ticket.id), params: { text: "x" }

    expect(response).to redirect_to(login_path)
  end

  it "escapa o texto da conversa" do
    post conversation_note_path(ticket.id), params: { text: "<script>alert(1)</script>" }
    follow_redirect!

    expect(response.body).not_to include("<script>alert(1)")
  end
end
