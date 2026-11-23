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

  it "supervisor vê Evals, DLQ e Configuração como links; não há itens reservados" do
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
