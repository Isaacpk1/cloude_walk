require "rails_helper"

RSpec.describe "RF-13 a RF-18: supervisor configura pelo formulário completo", type: :system do
  let!(:brand) { create(:brand, :infinitepay) }
  let!(:setup) { triage_setup(brand, ai_first: false) }

  it "publica ignorando as linhas extras vazias e o próximo caso segue a regra, com versão visível" do
    log_in_as_supervisor
    visit "/configuracao"
    fill_in "new_queue_name", with: "Repasses da operação"
    uncheck "new_queue_ai"
    click_button "Criar fila"
    expect(page).to have_content("Fila criada")

    fill_in "rule_0_name", with: "Repasse da operação"
    select "Repasses da operação", from: "rule_0_queue"
    select "categoria", from: "rule_0_0_0_field"
    fill_in "rule_0_0_0_value", with: "repasses"
    click_button "Publicar regras" # envia também as condições e os grupos extras em branco, como no navegador
    expect(page).to have_content("Regras publicadas: versão 1")

    ticket = ingest("meu repasse não caiu", brand: brand.slug, identity: "acc_operator").ticket
    run_triage(ticket)
    expect(ticket.reload.queue.current_version.name).to eq("Repasses da operação")
    visit "/conversas/#{ticket.id}"
    expect(page).to have_content("conjunto de regras versão 1")
    expect(page).to have_content("Repasse da operação")

    visit "/configuracao"
    click_button "Publicar regras" # salvar de novo sem preencher nenhuma linha extra também funciona
    expect(page).to have_content("Regras publicadas: versão 2")
    expect(ticket.reload.ruleset_version).to eq(1)
  end
end
