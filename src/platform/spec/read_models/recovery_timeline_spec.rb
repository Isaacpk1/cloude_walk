require "rails_helper"

# ROADMAP 09, Frontend, na linha do tempo do atendimento (RF-55, RF-56): o evento DLQ com o desfecho da RN-45,
# o resumo das tentativas de cada item do outbox e o motivo da falha em cada etapa (ingestão, publicação,
# agente, aplicação, entrega), com o mesmo TimelineView::Error das etapas.
RSpec.describe "ROADMAP 09: tentativas, DLQ e falhas por etapa na linha do tempo" do
  subject(:source) { RecordedConversations.new }

  let!(:brand) { create(:brand, :infinitepay) }
  let(:t0) { Time.zone.parse("2026-11-20 12:00:00") }

  before { travel_to(t0) }

  def opened_turn = open_turn_for(ingest("meu repasse não caiu"))
  def timeline(ticket) = source.timeline(ticket.id.to_s)

  describe "RN-45: evento DLQ" do
    it "escalou: o evento DLQ liga-se ao turno, ao trace_id e ao registro, com o desfecho" do
      turn = opened_turn
      travel_to(t0 + 4)
      dead_letter = record_dead_letter(ticket: turn.ticket, turn:, source: "broker", reason: "contrato", outcome: "escalated")

      event = timeline(turn.ticket).events.find { _1.kind == :dead_letter }

      expect(event).to have_attributes(started_at: t0 + 4, turn: 1, seq: turn.context_until_seq, trace_id: dead_letter.trace_id,
                                       label: "DLQ")
      expect(event.dead_letter.id).to eq(dead_letter.id)
      expect(event.detail).to include("Broker (publicação para o agente)", "Fora do contrato", dead_letter.event_id.first(8),
                                      "Escalou o atendimento")
      expect(event.error.origin_label).to eq("DLQ: desviado por Broker (publicação para o agente)")
      expect(event.error.outcome_label).to eq("Escalou o atendimento: turno ainda válido (RN-45)")
      expect(event.error.message).to eq("Fora do contrato (RN-44, RNF-28); violações: /turn")
    end

    it "só auditado: um evento só, mesmo com dead_letter.recorded e dead_letter.audited (sem repetir)" do
      turn = opened_turn
      record_dead_letter(ticket: turn.ticket, turn:, source: "platform", outcome: "audited")

      events = timeline(turn.ticket).events.select { _1.kind == :dead_letter }

      expect(events.size).to eq(1)
      expect(events.sole.error.outcome_label).to start_with("Só auditado")
    end

    it "sem correlação: não entra na linha do tempo de nenhum atendimento" do
      turn = opened_turn
      record_dead_letter(outcome: "uncorrelated")

      expect(timeline(turn.ticket).events.map(&:kind)).not_to include(:dead_letter)
    end

    it "invariante 6: registro de outro atendimento não entra" do
      turn = opened_turn
      other = open_turn_for(ingest("outro", identity: "acc_infinitepay_000099"))
      record_dead_letter(ticket: other.ticket, turn: other)

      expect(timeline(turn.ticket).events.map(&:kind)).not_to include(:dead_letter)
    end
  end

  describe "RF-34: resumo das tentativas na linha do tempo" do
    it "um evento por item, com N tentativas e o desfecho" do
      turn = opened_turn
      stub_broker({ status: 503 })
      Outbox::Publish.call(turn.event_id, jitter: -> { 0.0 })

      event = timeline(turn.ticket).events.find { _1.kind == :outbox_item }

      expect(event.outbox).to have_attributes(event_type: "agent.event", attempts_count: 1, outcome: :retrying)
      expect(event.detail).to include("Publicação do turno 1", "1 tentativa · Em retentativa")
      expect(event).to have_attributes(turn: 1, finished_at: nil)
    end
  end

  describe "RF-55: motivo da falha por etapa" do
    it "agrupa as falhas nas cinco etapas, cada uma com o rótulo do mesmo TimelineView::Error" do
      turn = opened_turn
      stub_broker({ status: 503 }, { status: 200 })
      Outbox::Publish.call(turn.event_id, jitter: -> { 0.0 })
      travel_to(t0 + 2)
      Outbox::Publish.call(turn.event_id, jitter: -> { 0.0 })
      record_agent_action(turn, agent_action_payload(turn), rejected: "contexto_divergente")
      record_dead_letter(ticket: turn.ticket, turn:, source: "agent-mock", reason: "acao_invalida", outcome: "audited")

      failures = timeline(turn.ticket).failures_by_stage

      expect(failures.keys).to eq(%i[ingestao publicacao agente aplicacao entrega])
      expect(failures[:ingestao]).to be_empty
      expect(failures[:publicacao].map(&:failure_label)).to eq([ TimelineView::Error::ORIGINS.fetch("kafka") ])
      expect(failures[:agente].map(&:kind)).to eq([ :dead_letter ])
      expect(failures[:agente].sole.failure_label).to eq("DLQ: desviado por Agente (agent-mock)")
      expect(failures[:aplicacao].sole.kind).to eq(:discarded)
      expect(failures[:aplicacao].sole.failure_label).to eq(AgentActionView::REJECTION_REASONS.fetch("contexto_divergente"))
      expect(failures[:entrega]).to be_empty
    end

    it "entrega: retentativa e conciliação ficam na etapa de entrega" do
      create(:provider_account, brand:, slug: "infinitepay-chat-mock")
      ticket = customer_message.ticket
      delivery = requested_delivery(ticket)
      record_delivery_sending(delivery)
      record_delivery_retry(delivery, error: "503 falha simulada")
      record_reconciliation_needed(delivery, attempts: 6)

      failures = timeline(ticket).failures_by_stage[:entrega]

      expect(failures.map(&:kind)).to eq(%i[delivery_retry_scheduled delivery_reconciliation])
      expect(failures.last.failure_label).to start_with("Confirmação do provedor incerta")
    end

    it "o resumo do item não conta como falha (o motivo não aparece duas vezes)" do
      turn = opened_turn
      stub_broker({ status: 503 })
      Outbox::Publish.call(turn.event_id, jitter: -> { 0.0 })

      expect(timeline(turn.ticket).failures_by_stage[:publicacao].map(&:kind)).to eq([ :publish_failed ])
    end
  end
end
