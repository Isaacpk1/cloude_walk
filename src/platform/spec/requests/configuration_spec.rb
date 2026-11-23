require "rails_helper"

# Bloco 12, Frontend (RF-13 a RF-18, RF-22, RF-58, RN-53, RNF-07): o supervisor configura filas, regras, equipes e
# atendentes no navegador, com erros visíveis; o analista não vê a tela.
RSpec.describe "Bloco 12: configuração pelo supervisor", :anonymous do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:config) { triage_setup(infinitepay, ai_first: false) }
  let!(:jim_config) { distribution_setup(jim) }
  let!(:boss) { analyst_in(config[:team], role: "supervisor", email: "boss@ip.test", name: "Chefe IP") }
  let!(:ana) { analyst_in(config[:team], email: "ana@ip.test") }
  let(:t0) { Time.utc(2026, 11, 24, 13, 0, 0) }

  def doc = Nokogiri::HTML(response.body)

  it "RN-53: o analista recebe 404; sem login vai para o login" do
    get configuration_path
    expect(response).to redirect_to(login_path)

    sign_in(ana)
    get configuration_path
    expect(response).to have_http_status(:not_found)
    post configuration_queues_path, params: { marca: "infinitepay", name: "x", team_id: config[:team].id }
    expect(response).to have_http_status(:not_found)
    expect(HelpdeskQueue.where(brand_id: infinitepay.id).count).to eq(2)
  end

  it "RNF-24: o supervisor da InfinitePay não configura a JIM" do
    sign_in(boss)

    get configuration_path(marca: "jim")
    expect(response).to have_http_status(:not_found)
    post configuration_queues_path, params: { marca: "jim", name: "x", team_id: jim_config[:team].id }
    expect(response).to have_http_status(:not_found)
  end

  it "mostra filas com versão, equipes, atendentes e a versão do conjunto de regras em uso" do
    sign_in(boss)

    get configuration_path

    expect(response).to have_http_status(:ok)
    expect(doc.css(".config-queue").map(&:text).join).to include("Geral", "Escalas N1", "versão 1")
    expect(doc.css(".config-team").text).to include(config[:team].name)
    expect(doc.css(".config-analyst").text).to include("Chefe IP")
    expect(doc.css(".config-rules__version").text).to include("sem regras")
  end

  it "RF-13: cria a fila e mostra o aviso; nome em branco volta com o erro visível" do
    sign_in(boss)

    post configuration_queues_path, params: { marca: "infinitepay", team_id: config[:team].id, name: "Crédito", ai_first: "1" }
    follow_redirect!
    expect(doc.css(".flash--notice").text).to include("Fila criada")
    expect(doc.css(".config-queue").text).to include("Crédito")

    post configuration_queues_path, params: { marca: "infinitepay", team_id: config[:team].id, name: " " }
    follow_redirect!
    expect(doc.css(".flash--alert").text).to include("o nome é obrigatório")
  end

  it "RF-13, RF-18: editar publica versão 2; desativar e excluir respeitam a fila padrão" do
    sign_in(boss)
    queue = Configuration::Queues.create(brand: infinitepay, team_id: config[:team].id, name: "Crédito", created_by: boss).record

    patch configuration_queue_path(queue), params: { marca: "infinitepay", name: "Crédito PJ", ai_first: "0" }
    expect(queue.reload.current_version).to have_attributes(version: 2, name: "Crédito PJ", ai_first: false)

    delete configuration_queue_path(config[:default], marca: "infinitepay")
    follow_redirect!
    expect(doc.css(".flash--alert").text).to include("fila padrão")

    post desativar_configuration_queue_path(queue), params: { marca: "infinitepay" }
    expect(queue.reload.active).to be(false)
    delete configuration_queue_path(queue, marca: "infinitepay")
    expect(queue.reload.archived_at).to be_present
  end

  it "RF-14, RF-16: publica a regra pelo formulário, o próximo atendimento cai na fila nova e a decisão fica rastreável" do
    sign_in(boss)
    credit = Configuration::Queues.create(brand: infinitepay, team_id: config[:team].id, name: "Crédito", created_by: boss).record
    rule = { "name" => "Repasse VIP", "queue_id" => credit.id.to_s,
             "groups" => { "0" => { "conditions" => { "0" => { "field" => "category", "op" => "eq", "value" => "repasses" },
                                                      "1" => { "field" => "channel", "op" => "in", "value" => "chat, whatsapp" } } } } }

    put configuration_rules_path, params: { marca: "infinitepay", default_queue_id: config[:default].id, rules: { "0" => rule } }
    follow_redirect!

    expect(doc.css(".flash--notice").text).to include("versão 1")
    expect(doc.css(".config-rules__version").text).to include("versão 1")
    ticket = ingest("meu repasse de ontem não caiu", brand: "infinitepay", identity: "acc_cfg").ticket
    travel_to(t0) { run_triage(ticket) }
    expect(ticket.reload).to have_attributes(queue_id: credit.id, ruleset_version: 1)
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "routing.decided").sole.data)
      .to include("rule_name" => "Repasse VIP", "ruleset_version" => 1)
  end

  it "RF-17: regra com fila inexistente mostra o motivo e não publica" do
    sign_in(boss)
    rule = { "name" => "Ruim", "queue_id" => "999999",
             "groups" => { "0" => { "conditions" => { "0" => { "field" => "channel", "op" => "eq", "value" => "chat" } } } } }

    put configuration_rules_path, params: { marca: "infinitepay", default_queue_id: config[:default].id, rules: { "0" => rule } }
    follow_redirect!

    expect(doc.css(".flash--alert").text).to include("não existe")
    expect(RoutingRuleset.where(brand_id: infinitepay.id)).to be_empty
  end

  it "RF-22, RF-58: cria equipe e analista; o novo analista consegue entrar" do
    sign_in(boss)

    post configuration_teams_path, params: { marca: "infinitepay", name: "Crédito" }
    team = Team.find_by!(brand_id: infinitepay.id, name: "Crédito")
    post configuration_analysts_path, params: { marca: "infinitepay", team_id: team.id, name: "Bia", email: "bia@ip.test",
                                                role: "analyst", password: "senha-forte-123", capacity: "3" }
    follow_redirect!
    expect(doc.css(".flash--notice").text).to include("Atendente cadastrado")

    delete logout_path
    post login_path, params: { email: "bia@ip.test", password: "senha-forte-123" }
    expect(response).to redirect_to(root_path)
  end

  it "escapa nomes de fila e equipe" do
    sign_in(boss)
    Configuration::Queues.create(brand: infinitepay, team_id: config[:team].id, name: "<script>alert(1)</script>", created_by: boss)

    get configuration_path

    expect(response.body).not_to include("<script>alert(1)")
  end
end
