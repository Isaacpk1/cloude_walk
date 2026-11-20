require "rails_helper"

# ROADMAP 04, frontend: "mostrar a consulta e a ação recebida, com a duração da execução do mock".
# Os registros seguem o formato combinado do bloco 04 (ai_turns.response e audit_events
# agent_action.applied/rejected), gravados direto pelo helper, sem o consumer.
RSpec.describe RecordedConversations, "ROADMAP 04: ação do agente no painel" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-20T13:00:00Z") }
  let(:source) { described_class.new }

  around { |example| travel_to(start) { example.run } }

  def turn_of(text = "meu repasse não caiu", **)
    open_turn_for(ingest(text, **))
  end

  describe "RF-31, RF-32, RN-37: ação do agente no turno" do
    it "turno aplicado mostra a ação reply, as consultas, o agente, a duração do agente e o desfecho" do
      turn = turn_of
      payload = agent_action_payload(turn, text: "Seu repasse cai hoje até as 18h.", agent_ms: 2_345)
      record_agent_action(turn, payload)

      view = source.find(turn.ticket_id.to_s).turns.sole
      action = view.agent_action

      expect(view).to have_attributes(status: "applied", action: "reply")
      expect(action).to have_attributes(action: "reply", reply_text: "Seu repasse cai hoje até as 18h.",
                                        model: "mock-deterministico", version: "0.3.0",
                                        config_hash: "sha256:9f2c4e1ab7d03c55e8f1aa90", agent_ms: 2_345,
                                        outcome: :applied, rejection_reason: nil, event_id: payload["event_id"])
      expect(action.short_config_hash).to eq("sha256:9f2c4")
      expect(action.outcome_label).to eq("Aplicada")
      expect(action.tool_calls.sole).to have_attributes(tool: "consultar_repasse", args: { "periodo" => "ontem" },
                                                        result: { "status" => "programado", "valor" => "1200.00" },
                                                        duration_ms: 120)
    end

    it "escalate mostra o motivo e o resumo do handoff; resolve mostra o motivo" do
      escalated = turn_of
      record_agent_action(escalated, agent_action_payload(escalated, action: "escalate"))
      resolved = turn_of("já caiu, obrigado", identity: "acc_infinitepay_000077")
      record_agent_action(resolved, agent_action_payload(resolved, action: "resolve", text: "Que bom! Encerrando."))

      escalation = source.find(escalated.ticket_id.to_s).turns.sole.agent_action
      resolution = source.find(resolved.ticket_id.to_s).turns.sole.agent_action

      expect(escalation).to have_attributes(action: "escalate", escalation_reason: "contestacao_de_cobranca")
      expect(escalation.escalation_summary).to include("problema" => "Cobrança em duplicidade",
                                                       "pendente" => "abrir contestação")
      expect(resolution).to have_attributes(action: "resolve", resolution_reason: "cliente confirmou que o repasse caiu",
                                            resolution_text: "Que bom! Encerrando.")
    end

    it "RN-56: resposta rejeitada fica no turno como descartada, com o motivo da auditoria" do
      turn = turn_of
      ingest("é o de ontem")
      turn.update_columns(status: "superseded")
      record_agent_action(turn, agent_action_payload(turn), rejected: "turno_superado")

      view = source.find(turn.ticket_id.to_s).turns.find { _1.number == 1 }

      expect(view.agent_action).to have_attributes(outcome: :rejected, rejection_reason: "turno_superado")
      expect(view.agent_action.outcome_label).to eq("Descartada")
      expect(view.agent_action.rejection_reason_label).to include("superado")
    end

    it "repetição: uma segunda ação para o mesmo turno não troca a resposta mostrada nem o motivo" do
      turn = turn_of
      first = agent_action_payload(turn, text: "primeira")
      record_agent_action(turn, first, rejected: "prazo_vencido")
      record_agent_action(turn, agent_action_payload(turn, text: "segunda"), rejected: "turno_nao_elegivel")

      action = source.find(turn.ticket_id.to_s).turns.sole.agent_action

      expect(action).to have_attributes(reply_text: "primeira", event_id: first["event_id"],
                                        rejection_reason: "prazo_vencido")
    end

    it "turno publicado sem resposta fica aguardando; turno encerrado sem resposta fica sem resposta" do
      turn = turn_of
      view = source.find(turn.ticket_id.to_s).turns.sole
      expect(view.agent_action).to be_nil
      expect(view.response_state_label).to eq("Aguardando resposta do agente")

      turn.update_columns(status: "expired")
      expect(source.find(turn.ticket_id.to_s).turns.sole.response_state_label).to eq("Sem resposta do agente")
    end

    it "marca errada: cada atendimento mostra só a ação da sua marca, e o banco recusa auditoria cruzada" do
      mine = turn_of
      record_agent_action(mine, agent_action_payload(mine, text: "resposta InfinitePay"))
      create(:brand, :jim)
      other = open_turn_for(ingest("oi", brand: "jim", identity: "acc_jim_000021"))
      record_agent_action(other, agent_action_payload(other, text: "resposta JIM"), rejected: "prazo_vencido")

      expect(source.find(mine.ticket_id.to_s).turns.sole.agent_action)
        .to have_attributes(reply_text: "resposta InfinitePay", outcome: :applied)
      expect(source.find(other.ticket_id.to_s).turns.sole.agent_action)
        .to have_attributes(reply_text: "resposta JIM", outcome: :rejected)
      expect do
        AuditEvent.create!(brand_id: other.brand_id, ticket_id: mine.ticket_id, actor_type: "agent",
                           event_type: "agent_action.rejected", data: { "turn" => 1 }, trace_id: SecureRandom.hex(16))
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "ação recebida sem auditoria de desfecho fica como recebida" do
      turn = turn_of
      turn.update_columns(response: agent_action_payload(turn), response_received_at: Time.current)

      action = source.find(turn.ticket_id.to_s).turns.sole.agent_action

      expect(action).to have_attributes(outcome: :received, rejection_reason: nil)
      expect(action.outcome_label).to eq("Recebida, sem desfecho registrado")
    end
  end

  describe "RF-55, RF-56: ação recebida na linha do tempo" do
    let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }

    it "a execução do agente dura agent_ms, liga ao turno e ao trace_id e a aplicação vem depois" do
      turn = turn_of(trace_id:)
      travel 2.seconds
      record_agent_action(turn, agent_action_payload(turn, agent_ms: 1_500))

      events = source.timeline(turn.ticket_id.to_s).events
      run = events.find { _1.kind == :agent_run }
      applied = events.find { _1.kind == :applied }

      expect(run).to have_attributes(turn: 1, seq: 1, trace_id:, duration_ms: 1_500, source: DataSource::SYSTEM)
      expect(run.detail).to include("Ação recebida do agente", "reply", "mock-deterministico 0.3.0", "consultar_repasse (120 ms)")
      expect(run.agent_action).to have_attributes(action: "reply", outcome: :applied)
      expect(applied).to have_attributes(turn: 1, trace_id:, agent_action: run.agent_action)
      expect(events.index(run)).to be < events.index(applied)
    end

    it "RN-56: a ação rejeitada vira descarte com o motivo" do
      turn = turn_of(trace_id:)
      record_agent_action(turn, agent_action_payload(turn), rejected: "in_reply_to_divergente")

      discarded = source.timeline(turn.ticket_id.to_s).events.find { _1.kind == :discarded }

      expect(discarded).to have_attributes(turn: 1, trace_id:)
      expect(discarded.detail).to include("in_reply_to")
      expect(discarded.agent_action).to have_attributes(outcome: :rejected, rejection_reason: "in_reply_to_divergente")
    end

    it "repetição: cada ação recebida aparece com o seu desfecho; o texto só existe para a primeira (ai_turns.response)" do
      turn = turn_of(trace_id:)
      record_agent_action(turn, agent_action_payload(turn, text: "a"))
      record_agent_action(turn, agent_action_payload(turn, text: "b"), rejected: "turno_nao_elegivel")

      events = source.timeline(turn.ticket_id.to_s).events

      expect(events.count { _1.kind == :agent_run }).to eq(2)
      expect(events.find { _1.kind == :applied }.agent_action).to have_attributes(reply_text: "a")
      expect(events.find { _1.kind == :discarded }.agent_action)
        .to have_attributes(reply_text: nil, rejection_reason: "turno_nao_elegivel", tool_calls: [ be_a(AgentActionView::ToolCall) ])
    end

    it "marca errada: a linha do tempo de um atendimento não mostra a ação de outro, de outra marca" do
      turn = turn_of
      create(:brand, :jim)
      other = open_turn_for(ingest("oi", brand: "jim", identity: "acc_jim_000021"))
      record_agent_action(other, agent_action_payload(other))

      expect(source.timeline(turn.ticket_id.to_s).events.map(&:kind)).not_to include(:agent_run, :applied)
      expect(source.timeline(other.ticket_id.to_s).events.map(&:kind)).to include(:agent_run, :applied)
    end
  end
end
