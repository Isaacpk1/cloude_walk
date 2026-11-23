require "rails_helper"

# RN-57 (07, seção 3.4: "a mesma transação marca o turno applied, registra a ação final, limpa os prazos e cancela o
# aviso de progresso do ciclo que ainda estiver pending"; 07, seção 3.2: a entrega já em `sending` fica para a
# conciliação). A resposta aplicada encerra o ciclo e o aviso dele.
RSpec.describe AgentActions::Apply, "RN-57: a resposta aplicada cancela o aviso de progresso do ciclo" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }

  before { allow(DatabaseClock).to receive(:now) { Time.current } }

  def at(seconds, &) = travel_to(t0 + seconds, with_usec: true, &)

  def ingest_at(seconds, text = "meu repasse não caiu", brand: "infinitepay")
    msg = normalized_message(text:, brand:, identity: "acc_aplica_#{brand}")
    at(seconds) { Ingestion::Receive.call(msg, provider_payload: { "customer_ref" => "cus_ref_#{brand}" }) }.ticket.reload
  end

  def notice_at(seconds, ticket)
    at(seconds) do
      Deadlines::ProgressDue.call(now: Time.current, limit: 100, ticket_ids: [ ticket.id ]).each { Turns::ProgressNotice.call(_1) }
    end
  end

  def apply_at(seconds, turn) = at(seconds) { described_class.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT) }

  def progress(ticket) = Delivery.find_by!(ticket_id: ticket.id, kind: "progress")
  def reply(ticket) = Delivery.find_by!(ticket_id: ticket.id, kind: "reply")
  def audits(ticket, type) = AuditEvent.where(ticket_id: ticket.id, event_type: type).order(:id)

  describe "RN-57: resposta aplicada aos 15,5 s com o aviso ainda pending" do
    let!(:ticket) { ingest_at(0) }
    let!(:turn) { at(2) { open_turn_for(ticket) } }

    before do
      notice_at(15, ticket)
      apply_at(15.5, turn)
    end

    it "cancela a entrega do aviso, conclui o seu item e audita delivery.cancelled resposta_aplicada" do
      notice = progress(ticket)
      expect(notice).to have_attributes(status: "cancelled", last_error: "resposta_aplicada")
      expect(OutboxEvent.find_by!(dedup_key: "delivery:#{notice.delivery_id}"))
        .to have_attributes(completed_at: be_present, last_error: "resposta_aplicada")
      cancelled = audits(ticket, "delivery.cancelled").sole
      expect(cancelled).to have_attributes(brand_id: infinitepay.id, actor_type: "system", trace_id: AgentActionHelpers::TRACE_ID)
      expect(cancelled.data).to include("delivery_id" => notice.delivery_id, "seq" => 2, "kind" => "progress",
                                        "reason" => "resposta_aplicada", "first_pending_seq" => 1)
    end

    it "ordem: o aviso tem seq menor que a resposta, e a resposta segue pending para o envio" do
      expect(progress(ticket).seq).to eq(2)
      expect(reply(ticket)).to have_attributes(seq: 3, status: "pending")
    end

    it "zera progress_due_at e o ciclo" do
      expect(ticket.reload).to have_attributes(progress_due_at: nil, first_pending_seq: nil, first_pending_at: nil)
    end

    it "o envio do aviso cancelado não chama o provedor; a resposta sai em seguida" do
      create(:provider_account, brand: infinitepay)
      stub_channels

      notice_item = OutboxEvent.find_by!(dedup_key: "delivery:#{progress(ticket).delivery_id}")
      expect(Deliveries::Send.call(notice_item.id).status).to eq(:skipped)
      Deliveries::Send.call(OutboxEvent.find_by!(dedup_key: "delivery:#{reply(ticket).delivery_id}").id)

      expect(channel_requests.size).to eq(1)
      expect(JSON.parse(channel_requests.sole.body)).to include("text" => "Seu repasse de R$ 1.200 cai hoje até as 18h.")
    end
  end

  describe "aviso já em sending (07, seção 3.2)" do
    it "fica preservado para a conciliação; a resposta espera o resultado dele" do
      ticket = ingest_at(0)
      turn = at(2) { open_turn_for(ticket) }
      notice_at(15, ticket)
      progress(ticket).update_columns(status: "sending", attempts: 1, lease_until: t0 + 45.seconds)

      apply_at(15.5, turn)

      expect(progress(ticket).status).to eq("sending")
      expect(audits(ticket, "delivery.cancelled")).to be_empty
      expect(reply(ticket).seq).to be > progress(ticket).seq
    end
  end

  describe "RN-57: resposta aplicada aos 10 s, antes do prazo do aviso" do
    it "nenhum aviso: zera progress_due_at e o scheduler não registra nada aos 15 s" do
      ticket = ingest_at(0)
      turn = at(2) { open_turn_for(ticket) }

      apply_at(10, turn)
      notice_at(15, ticket)

      expect(ticket.reload.progress_due_at).to be_nil
      expect(Delivery.where(ticket_id: ticket.id).pluck(:kind)).to eq([ "reply" ])
      expect(OutboxEvent.where(event_type: "progress.notice")).to be_empty
    end
  end

  describe "ação aplicada sem texto (escalate) também encerra o aviso do ciclo" do
    it "cancela o aviso pending" do
      ticket = ingest_at(0)
      turn = at(2) { open_turn_for(ticket) }
      notice_at(15, ticket)
      escalate = agent_action_for(turn, action: "escalate", escalation: {
        "reason" => "retencao_suspeita", "summary" => { "problema" => "Repasse retido", "dados_cliente" => "Lojista",
                                                        "acoes_tomadas" => "Consultou", "motivo" => "Retenção", "pendente" => "Ver" }
      }).except("reply")

      at(15.5) { described_class.call(escalate) }

      expect(progress(ticket).status).to eq("cancelled")
    end
  end

  describe "rejeição não mexe no aviso" do
    it "resposta superada deixa o aviso pending e o prazo do ciclo" do
      ticket = ingest_at(0)
      turn = at(2) { open_turn_for(ticket) }
      ingest_at(3, "é o de ontem")
      notice_at(15, ticket)

      expect(apply_at(15.5, turn).status).to eq(:rejected)
      expect(progress(ticket).status).to eq("pending")
    end
  end

  describe "ciclos diferentes" do
    it "o aviso de um ciclo anterior já encerrado não é tocado; só o do ciclo da resposta" do
      ticket = ingest_at(0)
      turn1 = at(2) { open_turn_for(ticket) }
      apply_at(5, turn1)
      reply1 = reply(ticket)
      ingest_at(20, "outra dúvida")
      turn2 = at(22) { open_turn_for(ticket) }
      notice_at(35, ticket)

      apply_at(35.5, turn2)

      expect(Delivery.where(ticket_id: ticket.id, kind: "progress").sole)
        .to have_attributes(ai_first_pending_seq: 3, status: "cancelled")
      expect(reply1.reload.status).to eq("pending")
    end
  end

  describe "marca (invariante 6)" do
    it "o aviso de outra marca, no mesmo instante, fica intacto" do
      ip = ingest_at(0)
      jm = ingest_at(0, brand: "jim")
      turn = at(2) { open_turn_for(ip) }
      notice_at(15, ip)
      notice_at(15, jm)

      apply_at(15.5, turn)

      expect(progress(ip).status).to eq("cancelled")
      expect(progress(jm)).to have_attributes(status: "pending", brand_id: jim.id)
    end
  end
end
