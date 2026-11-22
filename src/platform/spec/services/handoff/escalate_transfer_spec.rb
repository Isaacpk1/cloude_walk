require "rails_helper"

# Bloco 10: o Escalate completo (07, seção 3.2 "Transferência e ordem de entrega"; RF-42, RF-43, RN-12, RN-14,
# RN-17, RN-38, RN-39, RN-41, RN-42). Na mesma transação do handoff mínimo do bloco 08: fila de escalas, subida
# de prioridade, aviso de transferência, resumo (ou o pedido do resumo da plataforma) e contador de trocas zerado.
RSpec.describe Handoff::Escalate, "bloco 10: escala com fila de escalas, aviso e resumo" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:default) { default_queue(infinitepay) }

  let(:notice_pt) { Handoff::Policy::DEFAULT.transfer_notice_text("pt-BR") }
  let(:notice_en) { Handoff::Policy::DEFAULT.transfer_notice_text("en") }
  let(:summary) do
    { "problema" => "repasse não caiu", "dados_cliente" => "lojista ***21", "acoes_tomadas" => "consultei o repasse",
      "motivo" => "cliente pediu humano", "pendente" => "confirmar o depósito" }
  end

  def escalation_queue(brand, active: true)
    queue = create(:queue_record, team: create(:team, brand:), escalation: true, active:)
    queue.publish_version!(name: "Escalas N1", created_by: nil, ai_first: false)
    queue.reload
  end

  def escalate(id) = described_class.call(id)
  def escalated(ticket) = audits(ticket, "ticket.escalated").sole
  def notices(ticket) = Delivery.where(ticket_id: ticket.id, kind: "handoff_notice")

  def request_with_summary(ticket, reason: "decisao_do_agente", source: "agent", summary: self.summary)
    ActiveRecord::Base.transaction do
      locked = Ticket.lock.find_by!(id: ticket.id, brand_id: ticket.brand_id)
      Handoff::Request.call(ticket: locked, reason:, source:, trace_id: "c" * 32, summary:)
    end
  end

  describe "RF-42, RN-17: fila da escalação" do
    it "vai para a fila de escalas ativa da marca, com a versão corrente dela" do
      escalas = escalation_queue(infinitepay)
      ticket = ingest.ticket

      escalate(request_handoff(ticket))

      expect(ticket.reload).to have_attributes(queue_id: escalas.id, queue_version: escalas.current_version.version)
      expect(escalated(ticket).data).to include("queue_id" => escalas.id, "queue_kind" => "escalation",
                                                "queue_version" => escalas.current_version.version, "queue_missing" => false)
    end

    it "sem fila de escalas ativa (só uma inativa): usa a padrão" do
      escalation_queue(infinitepay, active: false)
      ticket = ingest.ticket

      escalate(request_handoff(ticket))

      expect(ticket.reload.queue_id).to eq(default.id)
      expect(escalated(ticket).data).to include("queue_kind" => "default", "queue_missing" => false)
    end

    it "sem fila de escalas nem padrão: escala sem fila (missing)" do
      ticket = ingest("hi", brand: "jim").ticket

      escalate(request_handoff(ticket))

      expect(ticket.reload).to have_attributes(state: "aguardando_humano", queue_id: nil, queue_version: nil)
      expect(escalated(ticket).data).to include("queue_kind" => "missing", "queue_missing" => true, "queue_id" => nil)
    end

    it "invariante 6: a fila de escalas de outra marca nunca é usada" do
      escalation_queue(jim)
      ticket = ingest.ticket

      escalate(request_handoff(ticket))

      expect(ticket.reload.queue_id).to eq(default.id)
      expect(escalated(ticket).data).to include("queue_kind" => "default")
    end
  end

  describe "RN-41, RN-14, RN-12: prioridade" do
    it "escalação por tempo sobe um nível e audita ticket.priority_raised" do
      ticket = ingest.ticket
      ticket.update_columns(priority: "media")

      escalate(request_handoff(ticket, reason: "prazo_do_turno"))

      expect(ticket.reload.priority).to eq("alta")
      raised = audits(ticket, "ticket.priority_raised").sole
      expect(raised).to have_attributes(trace_id: "c" * 32, brand_id: infinitepay.id)
      expect(raised.data).to include("from" => "media", "to" => "alta", "reason" => "prazo_do_turno")
      expect(escalated(ticket).data).to include("priority_from" => "media", "priority_to" => "alta")
    end

    it "falha de integração sem prioridade (sem triagem): vale a média da RN-13 e sobe para alta" do
      ticket = ingest.ticket

      escalate(request_handoff(ticket, reason: "falha_de_integracao", source: "dlq"))

      expect(ticket.reload.priority).to eq("alta")
      expect(audits(ticket, "ticket.priority_raised").sole.data).to include("from" => nil, "to" => "alta")
    end

    it "pedido do cliente mantém a prioridade" do
      ticket = ingest.ticket
      ticket.update_columns(priority: "baixa")

      escalate(request_handoff(ticket, reason: "pedido_do_cliente", source: "ingestion"))

      expect(ticket.reload.priority).to eq("baixa")
      expect(audits(ticket, "ticket.priority_raised")).to be_empty
      expect(escalated(ticket).data).to include("priority_from" => "baixa", "priority_to" => "baixa")
    end

    it "RN-14: crítica não sobe nem desce, e não há auditoria de subida" do
      ticket = ingest.ticket
      ticket.update_columns(priority: "critica")

      escalate(request_handoff(ticket, reason: "teto_do_ciclo"))

      expect(ticket.reload.priority).to eq("critica")
      expect(audits(ticket, "ticket.priority_raised")).to be_empty
    end
  end

  describe "RN-42, RF-43: aviso de transferência" do
    it "grava a mensagem do sistema, a entrega handoff_notice pending e o delivery.requested no outbox" do
      ticket = ingest.ticket
      ingest("é o de ontem")
      context_version = ticket.reload.context_version

      result = escalate(request_handoff(ticket))

      message = Message.where(ticket_id: ticket.id, direction: "outbound").sole
      expect(message).to have_attributes(author_type: "system", body: notice_pt, seq: 3, channel: "chat",
                                         provider_account: "infinitepay-chat-mock", brand_id: infinitepay.id,
                                         trace_id: "c" * 32)
      notice = notices(ticket).sole
      expect(notice).to have_attributes(message_id: message.id, seq: 3, status: "pending", ai_assignment_version: nil,
                                        channel: "chat", provider_account: "infinitepay-chat-mock")
      item = delivery_item(notice)
      expect(item).to have_attributes(event_type: "delivery.requested", brand_id: infinitepay.id, completed_at: nil)
      expect(item.payload).to eq("delivery_id" => notice.delivery_id, "ticket_id" => ticket.id, "seq" => 3)
      requested = audits(ticket, "delivery.requested").sole
      expect(requested.data).to include("delivery_id" => notice.delivery_id, "message_id" => message.id, "seq" => 3,
                                        "kind" => "handoff_notice", "context_until_seq" => 2)
      expect(ticket.reload.context_version).to eq(context_version + 1) # ADR-022: saída visível
      expect(escalated(ticket).data).to include("transfer_delivery_id" => notice.delivery_id, "transfer_seq" => 3)
      expect(result.wake_ids).to include(item.id)
    end

    it "JIM: o aviso sai no idioma da marca (inglês)" do
      ticket = ingest("I need help", brand: "jim").ticket

      escalate(request_handoff(ticket))

      expect(Message.where(ticket_id: ticket.id, author_type: "system").sole.body).to eq(notice_en)
    end

    it "RN-38: cancela a resposta pending da IA, mantém a sending e o aviso vem depois de toda saída anterior" do
      ticket = ingest.ticket
      sending = requested_delivery(ticket, text: "primeira")
      sending.update_columns(status: "sending", attempts: 1, lease_until: 30.seconds.from_now)
      pending = requested_delivery(ticket, text: "segunda")

      escalate(request_handoff(ticket))

      notice = notices(ticket).sole
      expect(pending.reload.status).to eq("cancelled")
      expect(sending.reload.status).to eq("sending")
      expect(notice.status).to eq("pending")
      expect(notice.seq).to be > [ sending.seq, pending.seq ].max
      expect(audits(ticket, "delivery.cancelled").map { _1.data["delivery_id"] }).to eq([ pending.delivery_id ])
    end

    it "sem mensagem do cliente (caso sem canal): não grava aviso e audita o motivo" do
      ticket = ingest.ticket
      Message.where(ticket_id: ticket.id).delete_all

      result = escalate(request_handoff(ticket))

      expect(result.status).to eq(:escalated)
      expect(notices(ticket)).to be_empty
      expect(audits(ticket, "handoff.notice_skipped").sole.data).to include("reason" => "sem_mensagem_do_cliente")
      expect(escalated(ticket).data).to include("transfer_delivery_id" => nil, "transfer_seq" => nil)
    end
  end

  describe "RN-39, RN-40: resumo" do
    it "com o resumo do agente: grava HandoffSummary disponível e audita handoff.summary_available na hora" do
      ticket = ingest.ticket

      result = escalate(request_with_summary(ticket))

      stored = HandoffSummary.where(ticket_id: ticket.id).sole
      expect(stored).to have_attributes(brand_id: infinitepay.id, source: "agent", status: "available",
                                        from_assignment_version: 0, fields: summary, trace_id: "c" * 32)
      expect(audits(ticket, "handoff.summary_available").sole.data)
        .to include("source" => "agent", "from_assignment_version" => 0, "ms_since_escalated" => 0)
      expect(OutboxEvent.where(ticket_id: ticket.id, event_type: "handoff.summary")).to be_empty
      expect(escalated(ticket).data).to include("summary_status" => "available")
      expect(result.summary_event_id).to be_nil
    end

    it "sem resumo: grava o pedido handoff.summary no outbox para a plataforma montar" do
      ticket = ingest.ticket
      freeze_time

      result = escalate(request_handoff(ticket, reason: "prazo_do_turno"))

      item = OutboxEvent.where(ticket_id: ticket.id, event_type: "handoff.summary").sole
      expect(item).to have_attributes(brand_id: infinitepay.id, dedup_key: "summary:#{ticket.id}:0", completed_at: nil,
                                      trace_id: "c" * 32, next_attempt_at: Time.current)
      expect(item.payload).to eq("ticket_id" => ticket.id, "from_assignment_version" => 0, "reason" => "prazo_do_turno",
                                 "escalated_at" => Time.current.utc.iso8601(3))
      expect(HandoffSummary.where(ticket_id: ticket.id)).to be_empty
      expect(escalated(ticket).data).to include("summary_status" => "pending")
      expect(result.summary_event_id).to eq(item.id)
      expect(result.wake_ids).to include(item.id)
    end
  end

  describe "RN-33 item 6: contador de trocas" do
    it "zera ai_turns_count" do
      ticket = ingest.ticket
      ticket.update_columns(ai_turns_count: 7)

      escalate(request_handoff(ticket))

      expect(ticket.reload.ai_turns_count).to eq(0)
    end
  end

  describe "repetição" do
    it "o mesmo pedido duas vezes: um aviso, um pedido de resumo e uma subida de prioridade" do
      ticket = ingest.ticket
      ticket.update_columns(priority: "media")
      id = request_handoff(ticket, reason: "prazo_do_turno")

      escalate(id)
      result = escalate(id)

      expect(result).to have_attributes(status: :already_done, wake_ids: [])
      expect(notices(ticket).count).to eq(1)
      expect(Message.where(ticket_id: ticket.id, author_type: "system").count).to eq(1)
      expect(OutboxEvent.where(ticket_id: ticket.id, event_type: "handoff.summary").count).to eq(1)
      expect(audits(ticket, "ticket.priority_raised").count).to eq(1)
      expect(ticket.reload.priority).to eq("alta")
    end

    it "com o resumo do agente duas vezes: um resumo só" do
      ticket = ingest.ticket
      id = request_with_summary(ticket)

      2.times { escalate(id) }

      expect(HandoffSummary.where(ticket_id: ticket.id).count).to eq(1)
      expect(audits(ticket, "handoff.summary_available").count).to eq(1)
    end
  end

  describe "ordem" do
    it "mensagem do cliente depois do handoff entra com seq maior, não abre ciclo da IA nem mexe no aviso" do
      ticket = ingest.ticket
      escalate(request_handoff(ticket))
      notice = notices(ticket).sole

      ingest("ainda estou esperando")

      expect(ticket.reload).to have_attributes(latest_customer_seq: 3, first_pending_seq: nil, dispatch_due_at: nil,
                                               ai_deadline_at: nil, state: "aguardando_humano")
      expect(notice.reload).to have_attributes(status: "pending", seq: 2)
      expect(Delivery.where(ticket_id: ticket.id).where.not(kind: "handoff_notice")).to be_empty
      expect(AiTurn.where(ticket_id: ticket.id)).to be_empty
    end
  end

  describe "tempo" do
    it "escalated_at do pedido de resumo é o instante do Escalate, não o do pedido de handoff" do
      t0 = Time.current.utc.change(usec: 0)
      ticket = travel_to(t0) { ingest.ticket }
      id = travel_to(t0 + 1.second) { request_handoff(ticket) }

      travel_to(t0 + 3.seconds) { escalate(id) }

      item = OutboxEvent.where(ticket_id: ticket.id, event_type: "handoff.summary").sole
      expect(item.payload["escalated_at"]).to eq((t0 + 3.seconds).iso8601(3))
      expect(item.next_attempt_at).to eq(t0 + 3.seconds)
    end
  end
end
