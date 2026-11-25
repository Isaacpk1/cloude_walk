require "rails_helper"

RSpec.describe "RF-58, ADR-028: cadastro de marca pelo supervisor", :anonymous do
  let!(:brand) { create(:brand, :infinitepay) }
  let!(:setup) { distribution_setup(brand) }
  let!(:boss) { analyst_in(setup[:team], role: "supervisor") }
  let(:attributes) { { name: "Marca de teste", slug: "marca-teste", locale: "pt-BR", timezone: "America/Sao_Paulo" } }

  it "RF-58: cria marca, equipe, bot e filas, e o criador consegue configurá-la" do
    sign_in(boss)
    post "/configuracao/marcas", params: attributes
    expect(response).to have_http_status(:see_other)
    created = Brand.find_by!(slug: "marca-teste")
    expect(boss.brand_ids_in_scope).to include(created.id)
    expect(created.queues.where(is_default: true).count).to eq(1)
    expect(created.queues.where(escalation: true).count).to eq(1)
    expect(User.joins(:teams).where(teams: { brand_id: created.id }, kind: "bot").count).to eq(1)
    expect(ProviderAccount.where(brand_id: created.id)).to be_empty
    follow_redirect!
    expect(response.body).to include("Marca de teste")
  end

  it "RN-53: analista não cria marca" do
    boss.update!(role: "analyst")
    sign_in(boss)
    post "/configuracao/marcas", params: attributes
    expect(response).to have_http_status(:not_found)
    expect(Brand.find_by(slug: "marca-teste")).to be_nil
  end

  it "RF-58: slug repetido ou idioma e fuso inválidos não criam registros parciais" do
    sign_in(boss)
    post "/configuracao/marcas", params: attributes.merge(slug: brand.slug)
    expect(Brand.count).to eq(1)
    post "/configuracao/marcas", params: attributes.merge(locale: "xx", timezone: "inexistente")
    expect(Brand.count).to eq(1)
  end

  it "RF-58, ADR-020: a tela oferece criação de marca e edição dos tempos com versão e erros" do
    sign_in(boss)
    get configuration_path(marca: brand.slug)
    doc = Nokogiri::HTML(response.body)
    expect(doc.css('form[action="/configuracao/marcas"]')).not_to be_empty
    expect(doc.css('input[name="policy[turn_deadline]"]')).not_to be_empty
    put "/configuracao/tempos-ia", params: { marca: brand.slug, policy: { turn_deadline: 10 } }
    follow_redirect!
    expect(response.body).to include("versão 1", "Vale para ciclos novos")
    put "/configuracao/tempos-ia", params: { marca: brand.slug, policy: { turn_deadline: 2 } }
    follow_redirect!
    expect(Nokogiri::HTML(response.body).css('.flash--alert').text).to include("5 a 60")
  end
end
