require "rails_helper"

# ROADMAP 11 e critério "RF-18 + RF-54" do docs/04: "a auditoria de um atendimento mostra qual regra, e em qual versão,
# o colocou na fila". Os quatro tipos de auditoria do bloco 11 na linha do tempo (TriageEvents).
RSpec.describe "RF-18 + RF-54: triagem e roteamento na linha do tempo (TriageEvents)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:t0) { Time.utc(2026, 11, 22, 14, 0, 0) }
  let!(:ticket) { at(t0) { ingest("preciso de empréstimo urgente").ticket } }
  let!(:geral) { routing_queue_for(infinitepay, name: "Geral") }
  let!(:credito) { routing_queue_for(infinitepay, name: "Crédito", ai_first: false) }

  def at(time, &) = travel_to(time, with_usec: true, &)
  def events = TriageEvents.new(ticket.reload).events
  def details = events.map { [ _1.kind, _1.detail ] }

  it "triage.classified: categoria, prioridade, tags, palavras e a mensagem classificada" do
    audit = at(t0 + 1.second) do
      record_triage_classified(ticket, category: "credito", priority: "alta", tags: %w[emprestimo], matched: %w[empréstimo urgente])
    end

    expect(events.sole).to have_attributes(kind: :triage_classified, seq: 1, trace_id: audit.trace_id, label: "Triagem")
    expect(events.sole.detail)
      .to eq("Categoria crédito, prioridade alta, tags emprestimo; palavras que decidiram: empréstimo, urgente (RN-11, RN-12)")
  end

  it "RN-13: triage.classified sem classificação" do
    at(t0 + 1.second) { record_triage_classified(ticket, category: "outros", priority: "media", unclassified: true) }

    expect(events.sole.detail).to eq("não classificado (RN-13): outros, prioridade média, fila padrão; nenhuma palavra-chave")
  end

  it "routing.decided: a regra e a versão do conjunto que colocaram o caso na fila (RF-18 + RF-54)" do
    at(t0 + 1.second) do
      record_routing_decided(ticket, queue: credito, ruleset_version: 3, rule_index: 1, rule_name: "Crédito alto", group_index: 0,
                                     conditions: [ { "field" => "category", "op" => "eq", "value" => "credito" } ])
    end

    expect(events.sole).to have_attributes(kind: :routing_decided, label: "Roteamento")
    expect(events.sole.detail).to eq("Na criação: regra 2 «Crédito alto», conjunto de regras versão 3: categoria = crédito " \
                                     "→ fila Crédito, versão 1")
  end

  it "routing.decided com regras puladas (RN-15)" do
    fraude = routing_queue_for(infinitepay, name: "Fraude", active: false)
    at(t0 + 1.second) do
      record_routing_decided(ticket, queue: geral, ruleset_version: 2,
                                     skipped_rules: [ { "rule_index" => 0, "rule_name" => "Fraude", "queue_id" => fraude.id,
                                                        "reason" => "fila_inativa" } ])
    end

    expect(events.sole.detail).to eq("Na criação: nenhuma regra casou: fila padrão Geral, versão 1 (RN-16), conjunto de " \
                                     "regras versão 2 · regra 1 «Fraude» pulada: fila Fraude inativa (RN-15)")
  end

  it "ticket.assigned: a atribuição e a mudança de estado" do
    at(t0 + 1.second) { record_ticket_assigned(ticket, to: "fila_humana", reason: "fila_sem_ia", queue: credito) }

    expect(events.sole).to have_attributes(kind: :triage_assigned, label: "Atribuição pela triagem")
    expect(events.sole.detail).to eq("fila sem IA: aguardando humano na fila Crédito · estado novo → aguardando_humano")
  end

  it "triage.skipped: o motivo" do
    at(t0 + 1.second) { record_triage_skipped(ticket, reason: "handoff_pedido") }

    expect(events.sole).to have_attributes(kind: :triage_skipped, label: "Triagem pulada")
    expect(events.sole.detail).to eq("triagem pulada: o cliente pediu um humano antes da triagem (RN-28, RN-34)")
  end

  it "repetição: dois routing.decided aparecem os dois, na ordem" do
    at(t0 + 1.second) { record_routing_decided(ticket, queue: geral, ruleset_version: 1) }
    at(t0 + 2.seconds) { record_routing_decided(ticket, queue: geral, ruleset_version: 2) }

    expect(events.map { _1.detail[/versão (\d)\z/, 1] }).to eq(%w[1 2])
  end
end
