require "rails_helper"

# ROADMAP 07, Frontend: o primeiro eval do cenário dos 3 s, com esperado, observado e link para o turno.
# ROADMAP, "O que o painel precisa conseguir mostrar" → Evals: cenário, execução, versão do agente, esperado,
# observado, status e link para a evidência; cenário que nunca rodou aparece como tal (ADR-023, RNF-30).
RSpec.describe "ADR-023, RNF-30: aba de evals" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:ticket) { ingest("meu repasse não caiu").ticket }

  def doc = Nokogiri::HTML(response.body)
  def scenario_card = doc.at_css("#scenario-corrida-3s")

  describe "navegação" do
    it "Qualidade da IA (evals) é link no menu do supervisor" do
      get "/"

      expect(doc.at_css(%(nav a[href="#{evals_path}"])).text).to eq("Qualidade da IA")
      get evals_path
      expect(doc.at_css(%(nav a[aria-current="page"])).text).to eq("Qualidade da IA")
    end
  end

  describe "GET /evals" do
    it "cenário sem execução aparece como nunca executado, com o comando para rodar" do
      get evals_path

      expect(response).to have_http_status(:ok)
      expect(scenario_card.text).to include("corrida-3s", "Nunca executado", "bin/rails evals:run[corrida-3s]", "make eval")
      expect(scenario_card.at_css(".eval-history")).to be_nil
    end

    it "mostra a última execução (status, quando, versão do agente) e um histórico curto, da mais nova para a mais antiga" do
      old = create_eval_run(brand: infinitepay, ticket:, status: "failed", checks: race_checks(failing: "uma única saída ao cliente"),
                            started_at: Time.current - 2.hours)
      last = create_eval_run(brand: infinitepay, ticket:, started_at: Time.current - 1.minute)

      get evals_path

      latest = scenario_card.at_css(".eval-latest")
      expect(latest.text).to include("Passou", "eval-fixture", "corrida-3s.v1", PanelClock.format(last.started_at), "InfinitePay")
      expect(latest.at_css(%(a[href="#{eval_path(last.id)}"]))).to be_present
      expect(scenario_card.css(".eval-history li a").map { _1["href"] }).to eq([ eval_path(last.id), eval_path(old.id) ])
      expect(scenario_card.at_css(".eval-history").text).to include("Falhou")
      expect(scenario_card.text).not_to include("Nunca executado")
    end

    it "o histórico mostra no máximo as 5 execuções mais recentes" do
      runs = Array.new(7) { |i| create_eval_run(brand: infinitepay, ticket:, started_at: Time.current - (10 - i).minutes) }

      get evals_path

      expect(scenario_card.css(".eval-history li a").map { _1["href"] }).to eq(runs.last(5).reverse.map { eval_path(_1.id) })
    end

    it "marca errada: com ?marca=jim, a execução da InfinitePay não aparece e o cenário fica como nunca executado na JIM" do
      create_eval_run(brand: infinitepay, ticket:)

      get evals_path(marca: "jim")

      expect(scenario_card.text).to include("Nunca executado")
      expect(response.body).not_to include("InfinitePay")
    end

    it "marca desconhecida no filtro responde 404" do
      get evals_path(marca: "outra")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /evals/:id" do
    it "passed: cenário, execução, agente, horários, duração, checagens e links de evidência para o turno e a mensagem" do
      run = create_eval_run(brand: infinitepay, ticket:)

      get eval_path(run.id)

      expect(response).to have_http_status(:ok)
      text = doc.text
      expect(text).to include("corrida-3s", run.id, "eval-fixture", "corrida-3s.v1", "ab12ab12ab12", "Passou", "4200 ms",
                              PanelClock.format(run.started_at, precise: true), PanelClock.format(run.finished_at, precise: true))
      expect(text).not_to include("ab12" * 16)
      rows = doc.css("table.eval-checks tbody tr")
      expect(rows.map { _1.at_css("td").text.strip }).to eq(EvalRunHelpers::RACE_CHECKS.map(&:first))
      first = rows.first
      expect(first.at_css(%(a[href="/conversas/#{ticket.id}#turn-1"]))).to be_present
      expect(first.at_css(%(a[href="/conversas/#{ticket.id}#seq-1"]))).to be_present
      expect(rows.last.at_css(%(a[href="/conversas/#{ticket.id}#seq-3"]))).to be_present
      expect(rows.last.css("a").map { _1["href"] }).not_to include(a_string_matching(/#turn-/))
      expect(doc.at_css(%(a[href="/conversas/#{ticket.id}"]))).to be_present
      expect(doc.at_css(".eval-expected").text).to include(%("outbound_seqs"))
      expect(doc.at_css(".eval-observed").text).to include("turno_superado")
      expect(doc.css("table.eval-checks tr.check--failed")).to be_empty
    end

    it "RN-56: com a corrida gravada pelo caminho real, cada link de evidência aponta para uma âncora da conversa" do
      race = record_three_second_race
      run = create_eval_run(brand: infinitepay, ticket: race[:ticket], trace_id: race[:ticket].messages.first.trace_id,
                            checks: race_checks.reject { _1["name"] == "uma única saída ao cliente" })

      get eval_path(run.id)
      hrefs = doc.css("table.eval-checks a").map { _1["href"] }
      get conversation_path(race[:ticket].id)
      anchors = doc.css("[id]").map { "/conversas/#{race[:ticket].id}##{_1['id']}" }

      expect(hrefs).to include("/conversas/#{race[:ticket].id}#turn-1", "/conversas/#{race[:ticket].id}#seq-2")
      expect(anchors).to include(*hrefs)
    end

    it "failed: destaca a checagem que falhou, com o esperado e o observado" do
      run = create_eval_run(brand: infinitepay, ticket:, status: "failed", checks: race_checks(failing: "uma única saída ao cliente"))

      get eval_path(run.id)

      expect(doc.at_css(".eval-status").text).to include("Falhou")
      failed = doc.css("table.eval-checks tr.check--failed")
      expect(failed.size).to eq(1)
      expect(failed.sole.text).to include("uma única saída ao cliente", "1", "2", "não")
    end

    it "error: mostra o erro e o que foi observado até ali" do
      run = create_eval_run(brand: infinitepay, ticket:, status: "error", checks: [], error: "RuntimeError: broker caiu",
                            observed: { "turns" => [ { "turn" => 1, "status" => "eligible" } ] })

      get eval_path(run.id)

      expect(doc.at_css(".eval-status").text).to include("Erro")
      expect(doc.at_css(".eval-error").text).to include("RuntimeError: broker caiu")
      expect(doc.at_css(".eval-observed").text).to include("eligible")
      expect(doc.text).to include("Nenhuma checagem registrada")
    end

    it "sem atendimento de evidência, as checagens ficam sem link" do
      run = create_eval_run(brand: infinitepay, ticket: nil, status: "error", error: "falhou antes da ingestão")

      get eval_path(run.id)

      expect(doc.css("table.eval-checks a")).to be_empty
      expect(doc.text).to include("Sem atendimento de evidência")
    end

    it "escapa HTML em observed, error e nas checagens" do
      run = create_eval_run(brand: infinitepay, ticket:, status: "error", error: "<script>alert('e')</script>",
                            observed: { "nota" => "<img src=x onerror=alert(1)>" },
                            checks: [ { "name" => "<b>nome</b>", "expected" => "<i>x</i>", "observed" => 1, "ok" => false,
                                        "evidence" => { "turn" => 1, "seq" => nil } } ])

      get eval_path(run.id)

      expect(response.body).not_to include("<script>alert('e')</script>", "<img src=x", "<b>nome</b>", "<i>x</i>")
      expect(response.body).to include("&lt;script&gt;", "&lt;b&gt;nome&lt;/b&gt;")
    end

    it "evidência com valor fora do formato (turn não numérico) não vira link" do
      run = create_eval_run(brand: infinitepay, ticket:, checks: [ { "name" => "x", "expected" => 1, "observed" => 1, "ok" => true,
                                                                     "evidence" => { "turn" => "1\" onmouseover=\"x", "seq" => nil } } ])

      get eval_path(run.id)

      expect(doc.css("table.eval-checks a")).to be_empty
    end

    it "marca errada: a execução da InfinitePay com ?marca=jim responde 404" do
      run = create_eval_run(brand: infinitepay, ticket:)

      get eval_path(run.id, marca: "jim")
      expect(response).to have_http_status(:not_found)

      get eval_path(run.id, marca: "infinitepay")
      expect(response).to have_http_status(:ok)
    end

    it "id inexistente ou fora do formato responde 404" do
      get eval_path(SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)

      get eval_path("nao-e-uuid")
      expect(response).to have_http_status(:not_found)
    end
  end
end
