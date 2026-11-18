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

  it "reserva Filas, Evals e Configuração, desabilitados e sem link" do
    get "/"

    %w[Filas Evals Configuração].each do |item|
      expect(response.body).to match(%r{<span[^>]*aria-disabled="true"[^>]*>\s*#{item}})
    end
  end
end
