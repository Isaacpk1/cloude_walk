require "rails_helper"

RSpec.describe "RN-55, RF-56: a página da linha do tempo mostra o fim da janela de agrupamento" do
  let!(:brand) { create(:brand, :infinitepay) }

  it "lista a espera intencional e a abertura do turno pelo scheduler antes da publicação" do
    received = ingest("meu repasse não caiu")
    open_turn_for(received)

    get timeline_path(received.ticket.id)

    expect(response).to have_http_status(:ok)
    body = response.body
    expect(body).to include("Espera intencional (janela de agrupamento)", "Fim da janela de agrupamento")
    expect(body.index("Fim da janela de agrupamento")).to be < body.index("Publicação no broker")
  end
end
