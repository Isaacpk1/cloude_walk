require "rails_helper"

# ROADMAP 11, Frontend: "exibir categoria, prioridade e explicação do roteamento no detalhe do atendimento" (RF-10,
# RF-12, RF-15, RF-18, RF-24, RF-54, RN-11 a RN-16, RN-20, RN-28) e o critério "RF-18 + RF-54" do docs/04 na linha do
# tempo. Registros no formato combinado do bloco 11 (spec/support/triage_records.rb).
RSpec.describe "ROADMAP 11: triagem e roteamento no painel" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 22, 14, 0, 0) }
  let!(:ticket) { at(t0) { ingest("preciso de empréstimo urgente").ticket } }
  let!(:geral) { routing_queue_for(infinitepay, name: "Geral") }
  let!(:credito) { routing_queue_for(infinitepay, name: "Crédito", ai_first: false) }
  let(:conditions) do
    [ { "field" => "category", "op" => "eq", "value" => "credito" },
      { "field" => "priority", "op" => "in", "value" => %w[alta critica] } ]
  end

  def at(time, &) = travel_to(time, with_usec: true, &)
  def doc = Nokogiri::HTML(response.body)
  def card = doc.at_css("section.card.triage")
  def card_text = card.text.squish

  def show(id = ticket.id)
    at(t0 + 10.seconds) { get conversation_path(id) }
    expect(response).to have_http_status(:ok)
  end

  def timeline_rows
    at(t0 + 10.seconds) { get timeline_path(ticket.id) }
    expect(response).to have_http_status(:ok)
    doc.css(".timeline tbody tr").map { _1.text.squish }
  end

  def triage_credit(rule_name: "Crédito alto", ruleset_version: 3)
    at(t0 + 1.second) do
      record_triage_classified(ticket, category: "credito", priority: "alta", tags: %w[emprestimo urgente],
                                       matched: %w[empréstimo urgente])
      record_routing_decided(ticket, queue: credito, ruleset_version:, rule_index: 1, rule_name:, group_index: 0,
                                     conditions:)
      record_ticket_assigned(ticket, to: "fila_humana", reason: "fila_sem_ia", queue: credito)
    end
  end

  describe "detalhe do atendimento: card Triagem e roteamento" do
    it "antes da triagem: diz que o caso aguarda a triagem" do
      show

      expect(card_text).to include("Triagem e roteamento", "Aguardando a triagem")
    end

    it "RN-11, RN-12, RF-10, RF-15, RN-20: categoria, prioridade, tags, palavras, explicação e atribuição" do
      triage_credit
      show

      expect(card.at_css(".triage__category").text).to eq("crédito")
      expect(card.at_css(".badge--priority-alta").text).to eq("alta")
      expect(card.css(".triage__tag").map(&:text)).to eq(%w[emprestimo urgente])
      expect(card_text).to include("palavras que decidiram empréstimo, urgente")
      expect(card.at_css(".triage__explanation").text.squish).to eq(
        "regra 2 «Crédito alto», conjunto de regras versão 3: categoria = crédito E prioridade em alta, crítica " \
        "→ fila Crédito, versão 1"
      )
      expect(card.at_css(".triage__assignment").text.squish).to eq("fila sem IA: aguardando humano na fila Crédito")
      expect(doc.text.squish).to include("Crédito Fila")
    end

    it "RN-13: não classificado" do
      at(t0 + 1.second) do
        record_triage_classified(ticket, category: "outros", priority: "media", unclassified: true)
        record_routing_decided(ticket, queue: geral, ruleset_version: 3)
      end
      show

      expect(card_text).to include("não classificado (RN-13): outros, prioridade média, fila padrão")
      expect(card.at_css(".triage__explanation").text.squish)
        .to eq("nenhuma regra casou: fila padrão Geral, versão 1 (RN-16), conjunto de regras versão 3")
    end

    it "sem conjunto de regras na marca: fila padrão" do
      at(t0 + 1.second) { record_routing_decided(ticket, queue: geral, ruleset_version: nil) }
      show

      expect(card.at_css(".triage__explanation").text.squish).to eq("sem conjunto de regras na marca: fila padrão Geral, versão 1")
    end

    it "RN-15: regras puladas por fila inativa" do
      fraude = routing_queue_for(infinitepay, name: "Fraude", active: false)
      at(t0 + 1.second) do
        record_routing_decided(ticket, queue: geral, ruleset_version: 2,
                                       skipped_rules: [ { "rule_index" => 0, "rule_name" => "Fraude", "queue_id" => fraude.id,
                                                          "reason" => "fila_inativa" } ])
      end
      show

      expect(card.css(".triage__skipped-rule").map { _1.text.squish })
        .to eq([ "regra 1 «Fraude» pulada: fila Fraude inativa (RN-15)" ])
    end

    it "RF-24: IA primeiro, com a IA" do
      bot = create(:user, :bot, name: "Agente de IA")
      at(t0 + 1.second) do
        record_triage_classified(ticket, category: "repasses", priority: "alta")
        record_routing_decided(ticket, queue: geral, ruleset_version: 1)
        record_ticket_assigned(ticket, to: "ia", reason: "ia_primeiro", queue: geral, assignee: bot)
      end
      show

      expect(card.at_css(".triage__assignment").text.squish).to eq("IA primeiro: com a IA (RF-24), fila Geral")
      expect(doc.text.squish).to include("Agente de IA IA")
    end

    it "RN-28: categoria somente humana vai para a fila de escalas" do
      escalas = routing_queue_for(infinitepay, name: "Escalas N1", ai_first: false, escalation: true)
      at(t0 + 1.second) do
        record_triage_classified(ticket, category: "cadastro", priority: "baixa")
        record_ticket_assigned(ticket, to: "fila_humana", reason: "categoria_somente_humana", queue: escalas)
      end
      show

      expect(card.at_css(".triage__assignment").text.squish)
        .to eq("categoria somente humana (RN-28): fila de escalas Escalas N1")
    end

    it "RN-28, RN-34: triagem pulada porque o caso chegou pedindo humano" do
      at(t0 + 1.second) { record_triage_skipped(ticket, reason: "handoff_pedido") }
      show

      expect(card.at_css(".triage__skipped").text.squish)
        .to eq("triagem pulada: o cliente pediu um humano antes da triagem (RN-28, RN-34)")
    end

    it "conteúdo de fora escapado: nome de regra e tag com HTML" do
      at(t0 + 1.second) do
        record_triage_classified(ticket, category: "credito", priority: "alta", tags: [ "<b>tag</b>" ])
        record_routing_decided(ticket, queue: credito, ruleset_version: 1, rule_index: 0, group_index: 0,
                                       rule_name: "<script>alert(1)</script>", conditions:)
      end
      show

      expect(response.body).not_to include("<script>alert(1)</script>", "<b>tag</b>")
      expect(response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(card.at_css(".triage__explanation").text).to include("«<script>alert(1)</script>»")
    end

    it "repetição: dois routing.decided, o card mostra o mais recente" do
      at(t0 + 1.second) { record_routing_decided(ticket, queue: geral, ruleset_version: 1) }
      triage_credit(ruleset_version: 2)
      show

      expect(card.at_css(".triage__explanation").text).to include("conjunto de regras versão 2")
      expect(card_text).not_to include("fila padrão Geral")
    end

    it "invariante 6: a triagem de um caso de outra marca não aparece neste caso" do
      other = at(t0) { ingest("empréstimo", brand: "jim", identity: "acc_jim_1").ticket }
      at(t0 + 1.second) do
        record_triage_classified(other, category: "pix", priority: "critica")
        record_routing_decided(other, queue: routing_queue_for(jim, name: "Fila JIM"), ruleset_version: 7)
      end
      show

      expect(card_text).to include("Aguardando a triagem")
      expect(response.body).not_to include("Fila JIM")
    end
  end

  describe "RF-18 + RF-54: linha do tempo" do
    it "os quatro tipos de auditoria, e o routing.decided com a regra e a versão do conjunto" do
      triage_credit
      at(t0 + 2.seconds) { record_triage_skipped(ticket, reason: "ja_triado") }
      rows = timeline_rows

      expect(rows.grep(/TriagemCategoria/).sole).to include("Categoria crédito, prioridade alta")
      expect(rows.grep(/RoteamentoNa criação/).sole).to include("regra 2 «Crédito alto», conjunto de regras versão 3")
      expect(rows.grep(/Atribuição pela triagemfila/).sole).to include("estado novo → aguardando_humano")
      expect(rows.grep(/Triagem puladatriagem/).sole).to include("o caso já tinha sido triado")
    end

    it "repetição: dois routing.decided aparecem os dois" do
      at(t0 + 1.second) { record_routing_decided(ticket, queue: geral, ruleset_version: 1) }
      at(t0 + 2.seconds) { record_routing_decided(ticket, queue: geral, ruleset_version: 2) }

      expect(timeline_rows.grep(/Roteamento/).map { _1[/conjunto de regras versão \d/] })
        .to eq([ "conjunto de regras versão 1", "conjunto de regras versão 2" ])
    end
  end

  describe "fila humana e lista de conversas" do
    it "RF-10: /fila mostra a categoria de cada caso" do
      triage_credit
      at(t0 + 10.seconds) { get human_queue_path }

      expect(response).to have_http_status(:ok)
      expect(doc.at_css("#queue-ticket-#{ticket.id} .human-queue__category").text.squish).to eq("crédito")
    end

    it "RF-10: /fila sem triagem diz que não foi triado" do
      at(t0 + 1.second) { ticket.update_columns(state: "aguardando_humano") }
      at(t0 + 10.seconds) { get human_queue_path }

      expect(doc.at_css("#queue-ticket-#{ticket.id} .human-queue__category").text.squish).to eq("sem triagem")
    end

    it "RF-10: a lista de conversas mostra categoria e prioridade" do
      triage_credit
      at(t0 + 10.seconds) { get conversations_path }

      item = doc.css(".conversation-list__item").find { _1.at_css(%(a[href="#{conversation_path(ticket.id)}"])) }
      expect(item.at_css(".conversation-list__category").text.squish).to eq("crédito")
      expect(item.at_css(".badge--priority-alta").text.squish).to eq("alta")
    end
  end
end
