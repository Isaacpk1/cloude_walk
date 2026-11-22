require "rails_helper"

# Falha definitiva escala na hora (RN-46, ADR-020 item 3, RN-49; 07, seção 3.4 "Regras de tempo"; interface
# combinada, item 3): o serviço que encerra a publicação ou recusa o turno grava handoff.requested na mesma
# transação, só para turno ainda eligible com o caso na IA.
RSpec.describe "RN-46: falha definitiva da publicação pede o handoff na hora" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  def open_event
    OutboxEvent.find(opened_turn.event_id)
  end

  def publish(item) = Outbox::Publish.call(item.id, jitter: -> { 0.0 })

  describe Outbox::Publish do
    it "retentativas esgotadas: publish_failed terminal e handoff publicacao_falhou (source outbox), mesma transação" do
      item = open_event
      turn = AiTurn.find_by!(event_id: item.id)
      turn.update_columns(deadline_at: start + 1.hour)
      stub_broker({ status: 503 })
      result = nil
      6.times do
        result = publish(item)
        item.reload
        travel_to(item.next_attempt_at)
      end

      expect(result.status).to eq(:exhausted)
      handoff = handoff_items.sole
      expect(result.handoff_event_id).to eq(handoff.id)
      expect(handoff).to have_attributes(ticket_id: turn.ticket_id, brand_id: infinitepay.id, trace_id: item.trace_id,
                                         dedup_key: "handoff:#{turn.ticket_id}:0")
      expect(handoff.payload).to eq("ticket_id" => turn.ticket_id, "reason" => "publicacao_falhou", "source" => "outbox",
                                    "turn" => turn.turn, "first_pending_seq" => 1, "assignment_version" => 0)
      # Mesmo commit: o pedido e o desfecho da publicação são gravados juntos.
      failed = AuditEvent.where(event_type: "agent_event.publish_failed").where("data->>'retry' = 'false'").sole
      requested = AuditEvent.where(event_type: "handoff.requested").sole
      expect(requested.id).to eq(failed.id + 1)
    end

    it "RN-43: erro de conexão até o prazo do turno também é falha definitiva" do
      item = open_event
      stub_request(:post, BrokerHelpers::BROKER_URL).to_raise(Errno::ECONNREFUSED)
      result = nil
      5.times do
        result = publish(item)
        travel_to(item.reload.next_attempt_at)
      end

      expect(result.status).to eq(:expired)
      expect(handoff_items.sole.payload["reason"]).to eq("publicacao_falhou")
    end

    it "recusa do broker (401): handoff na hora" do
      item = open_event
      stub_broker({ status: 401 })

      result = publish(item)

      expect(result.status).to eq(:rejected)
      expect(handoff_items.sole.payload).to include("reason" => "publicacao_falhou", "source" => "outbox")
    end

    it "contrato inválido na saída (plataforma): handoff na hora, sem chamar o broker" do
      item = open_event
      item.update_columns(payload: item.payload.except("turn"))
      stub_broker

      publish(item)

      expect(broker_requests).to be_empty
      expect(handoff_items.sole.payload["reason"]).to eq("publicacao_falhou")
    end

    it "falha transitória com retentativa ainda possível não pede handoff" do
      item = open_event
      stub_broker({ status: 503 })

      expect(publish(item).status).to eq(:retry_scheduled)
      expect(handoff_items).to be_empty
    end

    it "07, seção 6: turno já applied antes da publicação: descarte, sem handoff" do
      item = open_event
      turn = AiTurn.find_by!(event_id: item.id)
      allow(DatabaseClock).to receive(:now) { Time.current }
      expect(AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT).status).to eq(:applied)
      stub_broker({ status: 401 })

      publish(item)

      expect(handoff_items).to be_empty
    end

    it "caso já com humano na recusa: sem handoff novo" do
      item = open_event
      Ticket.find(item.ticket_id).update_columns(state: "com_analista")
      stub_broker({ status: 401 })

      publish(item)

      expect(handoff_items).to be_empty
    end
  end

  describe Turns::Open do
    it "RN-49: pendentes acima do limite pedem o handoff contexto_excede_limite (source turns)" do
      ingest("a" * 8_000)
      received = ingest("b" * 8_001)

      result = Turns::Open.call(due_dispatch(received).id)

      expect(result.status).to eq(:context_too_large)
      handoff = handoff_items.sole
      expect(result.handoff_event_id).to eq(handoff.id)
      expect(handoff.payload).to eq("ticket_id" => received.ticket.id, "reason" => "contexto_excede_limite",
                                    "source" => "turns", "turn" => nil, "first_pending_seq" => 1, "assignment_version" => 0)
    end

    it "ADR-020: evento do turno fora do contrato é falha definitiva da publicação (source turns)" do
      received = ingest
      allow(HelpdeskContracts).to receive(:errors).and_call_original
      allow(HelpdeskContracts).to receive(:errors).with(:agent_inbound, anything)
                                                  .and_return([ Struct.new(:pointer).new("/turn") ])

      result = Turns::Open.call(due_dispatch(received).id)

      expect(result.status).to eq(:invalid)
      expect(handoff_items.sole.payload).to include("reason" => "publicacao_falhou", "source" => "turns")
    end

    it "recusas que o timeout já cobre (prazo_vencido) não pedem handoff aqui" do
      received = ingest
      item = due_dispatch(received)
      received.ticket.update_columns(ai_deadline_at: start - 1.second)

      expect(Turns::Open.call(item.id).status).to eq(:expired)
      expect(handoff_items).to be_empty
    end
  end
end
