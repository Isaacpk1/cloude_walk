require "rails_helper"

RSpec.describe "ROADMAP 01: abrir uma conversa a partir da lista" do
  it "vai da lista à conversa e dela à linha do tempo" do
    visit "/"
    click_link "Repasse não caiu"

    expect(page).to have_css("h1", text: "Conversa")
    expect(page).to have_content("Exemplo sintético")
    expect(page).to have_content("meu repasse não caiu")
    expect(page).to have_content("Turno 1")

    click_link "Ver linha do tempo"

    expect(page).to have_css("h1", text: "Linha do tempo")
    expect(page).to have_content("Execução do agente")
  end
end
