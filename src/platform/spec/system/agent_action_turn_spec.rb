require "rails_helper"

# ROADMAP 04, "pronto quando": abrir o turno e conferir as mensagens enviadas e a ação resultante.
RSpec.describe "ROADMAP 04, RF-31: abrir o turno e conferir a ação do agente" do
  let!(:brand) { create(:brand, :infinitepay) }

  it "vai da lista ao turno, com as mensagens enviadas e a ação, e dele à linha do tempo" do
    turn = open_turn_for(ingest("meu repasse não caiu"))
    record_agent_action(turn, agent_action_payload(turn, text: "Seu repasse cai hoje até as 18h.", agent_ms: 2_345))

    visit "/"
    click_link "meu repasse não caiu", match: :first

    within(".turn", text: "Turno 1") do
      expect(page).to have_content("seq 1: meu repasse não caiu")
      expect(page).to have_content("Ação recebida: Resposta ao cliente")
      expect(page).to have_content("Seu repasse cai hoje até as 18h.")
      expect(page).to have_content("consultar_repasse")
      expect(page).to have_content("2345 ms")
      expect(page).to have_content("Aplicada")
    end

    click_link "Ver linha do tempo"

    expect(page).to have_content("Ação recebida do agente")
    expect(page).to have_content("Aplicação da resposta")
  end
end
