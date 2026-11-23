require "rails_helper"

RSpec.describe "RN-25, RN-26, RN-14: workers dos alertas de SLA" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:setup) { distribution_setup(infinitepay) }
  let(:started) { Time.zone.parse("2026-11-24 10:00:00") }
  let(:due) { started + 10.minutes }
  let!(:ticket) do
    waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_a", priority: "media", started_at: started, sla_due_at: due)
  end
  let(:db_now) { started + 8.minutes }

  before { allow(DatabaseClock).to receive(:now) { db_now } }

  def alert_item = OutboxEvent.find(Deadlines::SlaAlert.call(now: started + 8.minutes, limit: 5).sole)
  def breach_item = OutboxEvent.find(Deadlines::SlaBreach.call(now: due, limit: 5).sole)
  def audits(type) = AuditEvent.where(ticket_id: ticket.id, event_type: type).order(:id)

  describe Sla::Alert do
    it "RN-25: sobe a prioridade um nível, grava o alerta e recalcula o prazo pela prioridade nova" do
      item = alert_item

      expect(described_class.call(item.id)).to have_attributes(status: :alerted)

      expect(ticket.reload).to have_attributes(priority: "alta", sla_alerted_at: db_now, sla_started_at: started)
      expect(ticket.sla_due_at).to eq(due) # alta (900 s) daria 15 min, depois dos 10 min que já valiam: nunca empurra
      expect(item.reload.completed_at).to be_present
    end

    it "RN-14, RF-54: audita ticket.priority_raised (reason sla_80) e sla.alerted" do
      item = alert_item
      described_class.call(item.id)

      expect(audits("ticket.priority_raised").sole).to have_attributes(
        trace_id: item.trace_id, data: a_hash_including("from" => "media", "to" => "alta", "reason" => "sla_80")
      )
      expect(audits("sla.alerted").sole.data).to include("from" => "media", "to" => "alta")
    end

    it "RN-14: crítica não sobe mais, mas o alerta fica gravado" do
      ticket.update_columns(priority: "critica")
      item = alert_item
      described_class.call(item.id)

      expect(ticket.reload).to have_attributes(priority: "critica", sla_alerted_at: db_now)
      expect(audits("ticket.priority_raised")).to be_empty
    end

    it "RN-25: a prioridade mais alta encurta o prazo" do
      ticket.update_columns(priority: "baixa", sla_due_at: started + 3.hours)
      item = OutboxEvent.find(Deadlines::SlaAlert.call(now: started + 3.hours, limit: 5).sole)
      allow(DatabaseClock).to receive(:now) { started + 3.hours }

      described_class.call(item.id)

      expect(ticket.reload).to have_attributes(priority: "media", sla_due_at: started + 3600.seconds)
    end

    it "tempo: pelo relógio do banco ainda antes dos 80%, o item fica aberto para o prazo" do
      item = alert_item
      allow(DatabaseClock).to receive(:now) { started + 8.minutes - 1.second }

      expect(described_class.call(item.id)).to have_attributes(status: :not_due, next_attempt_at: started + 8.minutes)
      expect(item.reload.completed_at).to be_nil
      expect(ticket.reload.priority).to eq("media")
    end

    it "revalidação: o caso foi atribuído a um analista, então o item é descartado com auditoria" do
      item = alert_item
      ticket.update_columns(state: "com_analista", assignee_id: analyst_in(setup[:team]).id)

      expect(described_class.call(item.id)).to have_attributes(status: :discarded, reason: "atribuido")
      expect(ticket.reload.priority).to eq("media")
      expect(audits("sla.action_discarded").sole.data).to include("reason" => "atribuido", "action" => "sla.alert")
    end

    it "revalidação: a atribuição mudou" do
      item = alert_item
      ticket.update_columns(assignment_version: 3)

      expect(described_class.call(item.id)).to have_attributes(status: :discarded, reason: "atribuicao_mudou")
    end

    it "repetição: o worker duas vezes alerta uma vez só" do
      item = alert_item

      expect([ described_class.call(item.id).status, described_class.call(item.id).status ]).to eq(%i[alerted already_done])
      expect(audits("sla.alerted").count).to eq(1)
    end

    it "item inexistente é ignorado" do
      expect(described_class.call(0)).to have_attributes(status: :skipped)
    end
  end

  describe Sla::Breach do
    let(:db_now) { due }

    it "RN-26: marca fora do SLA e audita sla.breached com o atraso" do
      item = breach_item
      allow(DatabaseClock).to receive(:now) { due + 3.seconds }

      expect(described_class.call(item.id)).to have_attributes(status: :breached)

      expect(ticket.reload.sla_breached).to be(true)
      expect(audits("sla.breached").sole).to have_attributes(
        trace_id: item.trace_id, data: a_hash_including("sla_due_at" => due.utc.iso8601(3), "late_ms" => 3000)
      )
      expect(item.reload.completed_at).to be_present
    end

    it "tempo: um instante antes do prazo pelo relógio do banco, o item fica aberto" do
      item = breach_item
      allow(DatabaseClock).to receive(:now) { due - 1.second }

      expect(described_class.call(item.id)).to have_attributes(status: :not_due, next_attempt_at: due)
      expect(ticket.reload.sla_breached).to be(false)
    end

    it "revalidação: caso atribuído a analista cumpriu a assunção, então descarta" do
      item = breach_item
      ticket.update_columns(state: "com_analista", assignee_id: analyst_in(setup[:team]).id)

      expect(described_class.call(item.id)).to have_attributes(status: :discarded, reason: "atribuido")
      expect(ticket.reload.sla_breached).to be(false)
    end

    it "RN-26: o estouro é permanente, mesmo que o caso seja devolvido à fila" do
      described_class.call(breach_item.id)
      ticket.update_columns(state: "com_analista", assignee_id: analyst_in(setup[:team]).id)
      ticket.update_columns(state: "aguardando_humano", assignee_id: nil)

      expect(ticket.reload.sla_breached).to be(true)
    end

    it "RN-26 (banco): o banco recusa desmarcar o estouro" do
      ticket.update_columns(sla_breached: true)

      expect { ActiveRecord::Base.transaction(requires_new: true) { ticket.update_columns(sla_breached: false) } }
        .to raise_error(ActiveRecord::StatementInvalid, /sla_breached/)
    end

    it "repetição: o worker duas vezes marca uma vez só" do
      item = breach_item

      expect([ described_class.call(item.id).status, described_class.call(item.id).status ]).to eq(%i[breached already_done])
      expect(audits("sla.breached").count).to eq(1)
    end
  end
end
