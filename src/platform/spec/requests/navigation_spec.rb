require "rails_helper"

RSpec.describe "ROADMAP 01: navegação inicial do painel" do
  it "leva a rota raiz à lista de conversas" do
    get "/"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Conversas")
    expect(response.body).to include("meu repasse não caiu")
  end

  it "tem Conversas e Linha do tempo no menu" do
    get "/"

    expect(response.body).to include(%(href="#{conversations_path}"))
    expect(response.body).to include(%(href="#{timelines_path}"))
  end

  it "usa nomes de tela claros: Falhas (DLQ) e Qualidade da IA (evals)" do
    get "/"

    labels = Nokogiri::HTML(response.body).css("nav.nav a").map { _1.text.squish }
    expect(labels).to include("Falhas", "Qualidade da IA")
    expect(labels).not_to include("DLQ", "Evals")
  end

  it "mostra a logo da CloudWalk no menu e não oferece troca de tema (o painel é só escuro)" do
    get "/"

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css(%(header.topbar svg[role="img"][aria-label="CloudWalk"]))).to be_present
    expect(doc.at_css(%(header.topbar button[data-controller="theme"]))).to be_nil
  end

  it "supervisor vê Qualidade da IA, Falhas e Configuração como links; não há itens reservados" do
    get "/"

    [ evals_path, dead_letters_path, configuration_path ].each { expect(response.body).to include(%(href="#{_1}")) }
    expect(response.body).not_to include("nav__item--disabled")
  end

  it "analista não vê Evals, DLQ nem Configuração no menu", :anonymous do
    infinitepay = create(:brand, :infinitepay)
    ana = analyst_in(distribution_setup(infinitepay)[:team])
    sign_in(ana)

    get "/"

    [ evals_path, dead_letters_path, configuration_path ].each { expect(response.body).not_to include(%(href="#{_1}")) }
    expect(response.body).to include("Sair")
  end
end
