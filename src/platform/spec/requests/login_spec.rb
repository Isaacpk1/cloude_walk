require "rails_helper"

# Bloco 14 (ADR-024; RF-59, RNF-26): login do painel por e-mail e senha, sessão com expiração e perfis.
RSpec.describe "ADR-024: login do painel", :anonymous do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:config) { distribution_setup(infinitepay) }
  let!(:ana) { analyst_in(config[:team], name: "Ana", email: "ana@infinitepay.test", password: "senha-sintetica-1") }

  it "RNF-26: painel sem sessão manda para o login" do
    get human_queue_path

    expect(response).to redirect_to(login_path)
  end

  it "login certo abre o painel e guarda só o id do usuário na sessão" do
    post login_path, params: { email: "ana@infinitepay.test", password: "senha-sintetica-1" }

    expect(response).to redirect_to(root_path)
    get human_queue_path
    expect(response).to have_http_status(:ok)
  end

  it "senha errada e e-mail desconhecido dão a mesma resposta, sem revelar qual falhou" do
    post login_path, params: { email: "ana@infinitepay.test", password: "errada" }
    wrong_password = [ response.status, response.body ]
    post login_path, params: { email: "ninguem@infinitepay.test", password: "errada" }

    expect([ response.status, response.body ]).to eq(wrong_password)
    expect(response).to have_http_status(:unprocessable_content)
    get human_queue_path
    expect(response).to redirect_to(login_path)
  end

  it "bot e usuário sem senha não entram" do
    ana.update_columns(password_digest: nil)

    post login_path, params: { email: "ana@infinitepay.test", password: "" }

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "ADR-024: a sessão expira em 8 h sem uso e cada uso renova o prazo" do
    t0 = Time.utc(2026, 11, 24, 9, 0, 0)
    travel_to(t0) { post login_path, params: { email: "ana@infinitepay.test", password: "senha-sintetica-1" } }

    travel_to(t0 + 7.hours) { get human_queue_path }
    expect(response).to have_http_status(:ok)
    travel_to(t0 + 14.hours) { get human_queue_path }
    expect(response).to have_http_status(:ok) # o uso das 7 h renovou
    travel_to(t0 + 23.hours) { get human_queue_path }
    expect(response).to redirect_to(login_path)
  end

  it "sair encerra a sessão" do
    post login_path, params: { email: "ana@infinitepay.test", password: "senha-sintetica-1" }
    delete logout_path

    get human_queue_path
    expect(response).to redirect_to(login_path)
  end

  it "usuário que virou bot depois do login perde o acesso" do
    post login_path, params: { email: "ana@infinitepay.test", password: "senha-sintetica-1" }
    ana.update_columns(kind: "bot")

    get human_queue_path
    expect(response).to redirect_to(login_path)
  end

  it "os webhooks de entrada continuam sem login (a assinatura é do ADR-019)" do
    post "/webhooks/chat/nao-existe", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }

    expect(response).not_to redirect_to(login_path)
  end
end
