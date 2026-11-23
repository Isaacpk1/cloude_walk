require "rails_helper"

# ROADMAP 11, Frontend: "exibir categoria, prioridade e explicação do roteamento no detalhe do atendimento" (RF-10,
# RF-12, RF-15, RF-18, RF-54, RN-11 a RN-13, RN-15, RN-16, RN-20, RN-28). Lido da auditoria no formato combinado do
# bloco 11 (triage.classified, routing.decided, ticket.assigned, triage.skipped) e das colunas do ticket, gravados por
# spec/support/triage_records.rb.
RSpec.describe "ROADMAP 11: triagem e roteamento na conversa (TriagePhase)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 22, 14, 0, 0) }
  let!(:ticket) { at(t0) { ingest("preciso de empréstimo urgente, não consigo vender").ticket } }
  let!(:geral) { routing_queue_for(infinitepay, name: "Geral") }
  let!(:credito) { routing_queue_for(infinitepay, name: "Crédito", ai_first: false) }

  def at(time, &) = travel_to(time, with_usec: true, &)
  def view = TriagePhase.new(ticket.reload).view

  let(:credit_conditions) do
    [ { "field" => "category", "op" => "eq", "value" => "credito" },
      { "field" => "priority", "op" => "in", "value" => %w[alta critica] } ]
  end

  def classify(**)
    at(t0 + 1.second) do
      record_triage_classified(ticket, category: "credito", priority: "alta", tags: %w[emprestimo],
                                       matched: %w[empréstimo urgente], **)
    end
  end

  it "sem triagem ainda: nil" do
    expect(view).to be_nil
  end

  describe "RN-11, RN-12, RF-10: categoria, prioridade, tags e as palavras que decidiram" do
    it "mostra os rótulos legíveis da categoria e da prioridade, as tags e as palavras" do
      classify

      expect(view).to have_attributes(category: "credito", priority: "alta", tags: %w[emprestimo],
                                      matched: %w[empréstimo urgente], unclassified: false, classified_seq: 1)
      expect(view.category_label).to eq("crédito")
      expect(view.priority_label).to eq("alta")
    end

    it "cada categoria da RN-11 tem rótulo legível" do
      labels = %w[transacoes_e_pagamentos repasses pix credito conta_digital maquininha cadastro outros]
               .map { ConversationView::Category.label(_1) }

      expect(labels).to eq([ "transações e pagamentos", "repasses", "Pix", "crédito", "conta digital", "maquininha",
                             "cadastro", "outros" ])
    end
  end

  describe "RN-13: não classificado" do
    it "outros, média, com o aviso da RN-13" do
      at(t0 + 1.second) { record_triage_classified(ticket, category: "outros", priority: "media", unclassified: true) }

      expect(view.unclassified).to be(true)
      expect(view.unclassified_label).to eq("não classificado (RN-13): outros, prioridade média, fila padrão")
    end
  end

  describe "RF-15, RN-16, RN-20: explicação do roteamento" do
    it "regra que casou com E: número, nome, versão do conjunto, condições e fila com a versão" do
      classify
      at(t0 + 1.second) do
        record_routing_decided(ticket, queue: credito, ruleset_version: 3, rule_index: 1, rule_name: "Crédito alto",
                                       group_index: 0, conditions: credit_conditions)
      end

      expect(view.routing).to have_attributes(queue_id: credito.id, queue_name: "Crédito", queue_version: 1,
                                              ruleset_version: 3, rule_index: 1, default: false)
      expect(view.routing.explanation).to eq(
        "regra 2 «Crédito alto», conjunto de regras versão 3: categoria = crédito E prioridade em alta, crítica " \
        "→ fila Crédito, versão 1"
      )
    end

    it "regra que casou pelo segundo grupo do OU: diz qual grupo casou" do
      classify
      at(t0 + 1.second) do
        record_routing_decided(ticket, queue: credito, ruleset_version: 2, rule_index: 0, rule_name: "Pix ou tag",
                                       group_index: 1,
                                       conditions: [ { "field" => "tags", "op" => "contains", "value" => "emprestimo" },
                                                     { "field" => "channel", "op" => "neq", "value" => "email" } ])
      end

      expect(view.routing.explanation).to eq(
        "regra 1 «Pix ou tag», conjunto de regras versão 2, grupo 2 do OU: tags contém emprestimo E canal ≠ email " \
        "→ fila Crédito, versão 1"
      )
    end

    it "operadores not_in e campo marca nas condições" do
      classify
      at(t0 + 1.second) do
        record_routing_decided(ticket, queue: credito, ruleset_version: 1, rule_index: 0, rule_name: "Fora de Pix",
                                       group_index: 0,
                                       conditions: [ { "field" => "brand", "op" => "eq", "value" => "infinitepay" },
                                                     { "field" => "category", "op" => "not_in", "value" => %w[pix repasses] } ])
      end

      expect(view.routing.explanation).to include(": marca = infinitepay E categoria fora de Pix, repasses → fila Crédito")
    end

    it "RN-16: nenhuma regra casou: fila padrão, com a versão do conjunto" do
      classify
      at(t0 + 1.second) { record_routing_decided(ticket, queue: geral, ruleset_version: 4) }

      expect(view.routing.explanation)
        .to eq("nenhuma regra casou: fila padrão Geral, versão 1 (RN-16), conjunto de regras versão 4")
    end

    it "sem conjunto de regras na marca: fila padrão" do
      classify
      at(t0 + 1.second) { record_routing_decided(ticket, queue: geral, ruleset_version: nil) }

      expect(view.routing.explanation).to eq("sem conjunto de regras na marca: fila padrão Geral, versão 1")
    end

    it "sem conjunto e sem fila na marca: caso sem fila" do
      classify
      at(t0 + 1.second) { record_routing_decided(ticket, queue: nil, ruleset_version: nil) }

      expect(view.routing.explanation).to eq("sem conjunto de regras e sem fila padrão na marca: caso sem fila")
    end

    it "RN-15: regras puladas por fila inativa, com número, nome e fila" do
      fraude = routing_queue_for(infinitepay, name: "Fraude", active: false)
      classify
      at(t0 + 1.second) do
        record_routing_decided(ticket, queue: geral, ruleset_version: 5,
                                       skipped_rules: [ { "rule_index" => 0, "rule_name" => "Fraude", "queue_id" => fraude.id,
                                                          "reason" => "fila_inativa" } ])
      end

      expect(view.routing.skipped_rule_labels).to eq([ "regra 1 «Fraude» pulada: fila Fraude inativa (RN-15)" ])
    end

    it "RN-15, invariante 6: fila pulada de outra marca não tem o nome revelado" do
      outra = routing_queue_for(jim, name: "Fila JIM", active: false)
      classify
      at(t0 + 1.second) do
        record_routing_decided(ticket, queue: geral, ruleset_version: 5,
                                       skipped_rules: [ { "rule_index" => 2, "rule_name" => "X", "queue_id" => outra.id,
                                                          "reason" => "fila_inativa" } ])
      end

      expect(view.routing.skipped_rule_labels).to eq([ "regra 3 «X» pulada: fila ##{outra.id} inativa (RN-15)" ])
    end
  end

  describe "RF-24, RN-28: atribuição" do
    before { classify }

    it "IA primeiro: com a IA" do
      bot = create(:user, :bot)
      at(t0 + 1.second) do
        record_routing_decided(ticket, queue: geral, ruleset_version: 1)
        record_ticket_assigned(ticket, to: "ia", reason: "ia_primeiro", queue: geral, assignee: bot)
      end

      expect(view.assignment.label).to eq("IA primeiro: com a IA (RF-24), fila Geral")
      expect(view.assignment).to have_attributes(state_from: "novo", state_to: "com_ia")
    end

    it "fila sem IA: aguardando humano na fila" do
      at(t0 + 1.second) { record_ticket_assigned(ticket, to: "fila_humana", reason: "fila_sem_ia", queue: credito) }

      expect(view.assignment.label).to eq("fila sem IA: aguardando humano na fila Crédito")
    end

    it "categoria somente humana: fila de escalas" do
      escalas = routing_queue_for(infinitepay, name: "Escalas N1", ai_first: false, escalation: true)
      at(t0 + 1.second) do
        record_ticket_assigned(ticket, to: "fila_humana", reason: "categoria_somente_humana", queue: escalas)
      end

      expect(view.assignment.label).to eq("categoria somente humana (RN-28): fila de escalas Escalas N1")
    end
  end

  describe "RN-28, RN-34: triagem pulada" do
    it "caso que chegou pedindo humano: mostra o motivo" do
      at(t0 + 1.second) { record_triage_skipped(ticket, reason: "handoff_pedido") }

      expect(view.skipped.label).to eq("triagem pulada: o cliente pediu um humano antes da triagem (RN-28, RN-34)")
    end

    it "fora de novo: mostra o estado" do
      ticket.update_columns(state: "aguardando_humano")
      at(t0 + 1.second) { record_triage_skipped(ticket, reason: "fora_de_novo") }

      expect(view.skipped.label).to eq("triagem pulada: o caso já não estava em novo (estado aguardando_humano)")
    end

    it "pulos depois de uma triagem feita não escondem a triagem" do
      classify
      at(t0 + 2.seconds) { record_triage_skipped(ticket, reason: "ja_triado") }

      expect(view.skipped).to be_nil
      expect(view.category).to eq("credito")
    end
  end

  describe "repetição: dois routing.decided do mesmo caso" do
    it "vale o mais recente" do
      classify
      at(t0 + 1.second) { record_routing_decided(ticket, queue: geral, ruleset_version: 1) }
      at(t0 + 2.seconds) do
        record_routing_decided(ticket, queue: credito, ruleset_version: 2, rule_index: 0, rule_name: "Crédito",
                                       group_index: 0, conditions: credit_conditions)
      end

      expect(view.routing).to have_attributes(queue_name: "Crédito", ruleset_version: 2)
    end
  end

  describe "invariante 6: marca errada" do
    it "a triagem de um caso de outra marca não aparece (o banco já recusa auditoria com ticket de outra marca)" do
      other = at(t0) { ingest("meu empréstimo", brand: "jim", identity: "acc_jim_1").ticket }
      at(t0 + 1.second) do
        record_triage_classified(other, category: "credito", priority: "alta")
        record_routing_decided(other, queue: routing_queue_for(jim, name: "Fila JIM"), ruleset_version: 9)
      end

      expect(view).to be_nil
      expect(TriagePhase.new(other.reload).view.routing.queue_name).to eq("Fila JIM")
    end

    it "fila de outra marca na decisão, sem nome gravado: o nome não é lido" do
      outra = routing_queue_for(jim, name: "Fila JIM")
      at(t0 + 1.second) do
        AuditEvent.create!(brand_id: infinitepay.id, ticket_id: ticket.id, actor_type: "system", event_type: "routing.decided",
                           data: { "queue_id" => outra.id, "ruleset_version" => nil, "default" => true },
                           trace_id: SecureRandom.hex(16), occurred_at: Time.current)
      end

      expect(view.routing.queue_name).to be_nil
    end
  end
end
