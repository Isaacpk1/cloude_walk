require "rails_helper"

# Handoff mínimo do bloco 08 (interface combinada, item 1; 07, seção 3.2 "Transferência e ordem de entrega";
# RN-33, RN-46, RF-36). O aviso de transferência (RN-42), o resumo (RN-39) e a atribuição a analista são do
# bloco 10.
RSpec.describe Handoff::Escalate, "RF-36: handoff mínimo pelo outbox" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let!(:queue) { default_queue(infinitepay) }

  def escalate(id) = described_class.call(id)

  describe "RN-46 / RN-33: pedido válido" do
    it "manda o caso à fila padrão da marca, troca a atribuição, encerra o ciclo e audita ticket.escalated" do
      turn = opened_turn
      ticket = turn.ticket.reload
      ticket.update_columns(progress_due_at: ticket.first_pending_at + 15.seconds)
      id = request_handoff(ticket, reason: "prazo_do_turno", source: "scheduler", turn: turn.turn)

      result = escalate(id)

      expect(result.status).to eq(:escalated)
      expect(ticket.reload).to have_attributes(
        state: "aguardando_humano", queue_id: queue.id, queue_version: queue.current_version.version,
        assignment_version: 1, first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil,
        progress_due_at: nil, ai_deadline_at: nil
      )
      expect(ticket.with_ai?).to be(false)
      expect(turn.reload.status).to eq("expired")
      expect(audits(ticket, "ai_turn.expired").sole.data).to include("turn" => turn.turn, "reason" => "handoff")
      escalated = audits(ticket, "ticket.escalated").sole
      expect(escalated).to have_attributes(brand_id: infinitepay.id, actor_type: "system", trace_id: "c" * 32)
      expect(escalated.data).to include("reason" => "prazo_do_turno", "source" => "scheduler", "from_assignment_version" => 0,
                                        "to_assignment_version" => 1, "queue_id" => queue.id,
                                        "queue_version" => queue.current_version.version, "turn" => turn.turn)
      expect(OutboxEvent.find(id).completed_at).to be_present
    end

    it "RF-06 / 07, seção 3.2: cancela entregas pending da IA e preserva a sending para conciliação" do
      turn = opened_turn
      ticket = turn.ticket.reload
      sending = requested_delivery(ticket, text: "primeira")
      sending.update_columns(status: "sending", attempts: 1, lease_until: 30.seconds.from_now)
      pending = requested_delivery(ticket, text: "aviso", kind: "progress")
      id = request_handoff(ticket)

      escalate(id)

      expect(sending.reload.status).to eq("sending")
      expect(pending.reload).to have_attributes(status: "cancelled", last_error: "handoff")
      expect(delivery_item(pending).completed_at).to be_present
      expect(delivery_item(sending).completed_at).to be_nil
      cancelled = audits(ticket, "delivery.cancelled").sole
      expect(cancelled.data).to include("delivery_id" => pending.delivery_id, "reason" => "handoff", "seq" => pending.seq)
    end

    it "sem fila padrão na marca: escala mesmo assim, sem fila, e registra o motivo" do
      ticket = opened_turn("oi", brand: "jim", identity: "acc_jim_000021").ticket
      id = request_handoff(ticket)

      escalate(id)

      expect(ticket.reload).to have_attributes(state: "aguardando_humano", queue_id: nil)
      expect(audits(ticket, "ticket.escalated").sole.data).to include("queue_id" => nil, "queue_missing" => true)
    end
  end

  describe "repetição" do
    it "o mesmo item duas vezes: um efeito só" do
      ticket = opened_turn.ticket
      id = request_handoff(ticket)

      escalate(id)
      result = escalate(id)

      expect(result.status).to eq(:already_done)
      expect(audits(ticket, "ticket.escalated").count).to eq(1)
      expect(ticket.reload.assignment_version).to eq(1)
    end

    it "dois gatilhos na mesma atribuição: o segundo pedido colide com a chave e não grava nada" do
      ticket = opened_turn.ticket

      first = request_handoff(ticket, reason: "prazo_do_turno")
      second = request_handoff(ticket, reason: "publicacao_falhou", source: "outbox")

      expect(first).to be_present
      expect(second).to be_nil
      expect(handoff_items(ticket).sole.dedup_key).to eq("handoff:#{ticket.id}:0")
      expect(audits(ticket, "handoff.requested").count).to eq(1)
    end
  end

  describe "pedido obsoleto: descarte auditado (handoff.discarded)" do
    it "atribuição antiga" do
      ticket = opened_turn.ticket
      id = request_handoff(ticket)
      ticket.update_columns(assignment_version: 3)

      result = escalate(id)

      expect(result).to have_attributes(status: :discarded, reason: "atribuicao_mudou")
      expect(ticket.reload).to have_attributes(state: "novo", assignment_version: 3)
      # Formato combinado com o painel (A3): o data do pedido, o motivo do descarte e o motivo pedido.
      expect(audits(ticket, "handoff.discarded").sole.data).to include(
        OutboxEvent.find(id).payload.merge("reason" => "atribuicao_mudou", "handoff_reason" => "prazo_do_turno",
                                           "expected_version" => 0, "current_version" => 3)
      )
      expect(audits(ticket, "ticket.escalated")).to be_empty
      expect(OutboxEvent.find(id).completed_at).to be_present
    end

    it "caso já fora da IA" do
      ticket = opened_turn.ticket
      id = request_handoff(ticket)
      ticket.update_columns(state: "com_analista")

      expect(escalate(id)).to have_attributes(status: :discarded, reason: "fora_da_ia")
      expect(audits(ticket, "ticket.escalated")).to be_empty
    end

    it "caso já na fila humana na mesma atribuição: ja_escalado" do
      ticket = opened_turn.ticket
      id = request_handoff(ticket, reason: "publicacao_falhou", source: "outbox")
      ticket.update_columns(state: "aguardando_humano")

      expect(escalate(id)).to have_attributes(status: :discarded, reason: "ja_escalado")
      expect(audits(ticket, "handoff.discarded").sole.data).to include("reason" => "ja_escalado",
                                                                       "handoff_reason" => "publicacao_falhou")
    end
  end

  describe "invariante 6: marca errada" do
    it "item sem atendimento na marca do item (a FK composta impede apontar para o de outra marca): não altera nada" do
      ticket = opened_turn.ticket
      item = OutboxEvent.create!(brand_id: jim.id, ticket_id: nil, event_type: Handoff::Request::EVENT_TYPE,
                                 dedup_key: "handoff:#{ticket.id}:0", trace_id: "d" * 32, next_attempt_at: Time.current,
                                 payload: { "ticket_id" => ticket.id, "reason" => "prazo_do_turno", "source" => "scheduler",
                                            "assignment_version" => 0 })

      result = escalate(item.id)

      expect(result).to have_attributes(status: :discarded, reason: "atendimento_inexistente")
      expect(ticket.reload).to have_attributes(state: "novo", assignment_version: 0)
      expect(AuditEvent.where(event_type: "handoff.discarded", brand_id: jim.id).sole.ticket_id).to be_nil
    end

    it "usa a fila padrão da própria marca, nunca a de outra" do
      default_queue(jim)
      ticket = opened_turn.ticket
      escalate(request_handoff(ticket))

      expect(ticket.reload.queue_id).to eq(queue.id)
    end
  end

  describe "depois do handoff (07, seção 3.3)" do
    it "mensagem nova do cliente não abre ciclo da IA nem gera dispatch_due_at" do
      ticket = opened_turn.ticket
      escalate(request_handoff(ticket))

      ingest("ainda estou esperando")

      expect(ticket.reload).to have_attributes(latest_customer_seq: 2, first_pending_seq: nil, dispatch_due_at: nil,
                                               ai_deadline_at: nil)
      expect(Deadlines::DispatchDue.call(now: 1.minute.from_now, limit: 10)).to eq([])
    end

    it "ação atrasada do agente é rejeitada pela atribuição, sem saída" do
      turn = opened_turn
      escalate(request_handoff(turn.ticket))

      result = AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)

      expect(result).to have_attributes(status: :rejected, reason: "atribuicao_mudou")
      expect(Message.where(ticket_id: turn.ticket_id, direction: "outbound")).to be_empty
    end

    it "evento antigo do turno no outbox é descartado pela publicação (turno_expired)" do
      stub_broker
      turn = opened_turn
      escalate(request_handoff(turn.ticket))

      result = Outbox::Publish.call(turn.event_id)

      expect(result.status).to eq(:discarded)
      expect(broker_requests).to be_empty
      expect(audits(turn.ticket, "agent_event.discarded").sole.data).to include("reason" => "turno_expired")
    end
  end
end
