require "rails_helper"

RSpec.describe "RN-25, RN-26: registro dos alertas de SLA" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:setup) { distribution_setup(infinitepay) }
  let(:started) { Time.zone.parse("2026-11-24 10:00:00") }
  let(:due) { started + 10.minutes }
  let!(:ticket) { waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_a", started_at: started, sla_due_at: due) }

  def alert(at, **) = Deadlines::SlaAlert.call(now: at, limit: 50, **)
  def breach(at, **) = Deadlines::SlaBreach.call(now: at, limit: 50, **)

  describe Deadlines::SlaAlert do
    it "RN-25: aos 80% do prazo registra, e um instante antes não" do
      expect(alert(started + 8.minutes - 1.second)).to eq([])

      item = OutboxEvent.find(alert(started + 8.minutes).sole)

      expect(item).to have_attributes(event_type: "sla.alert", ticket_id: ticket.id, brand_id: infinitepay.id,
                                      dedup_key: "sla.alert:#{ticket.id}:0")
    end

    it "RF-54: audita o registro com o prazo e o atraso do scheduler" do
      alert(started + 8.minutes + 2.seconds)

      expect(AuditEvent.where(ticket_id: ticket.id, event_type: "sla.alert_scheduled").sole.data)
        .to include("delay_ms" => 2000, "sla_due_at" => due.utc.iso8601(3))
    end

    it "repetição: registrar duas vezes gera um item só" do
      expect(alert(started + 9.minutes).size).to eq(1)
      expect(alert(started + 9.minutes)).to eq([])
    end

    it "só casos esperando na fila, sem analista e sem alerta anterior" do
      with_analyst = waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_b", started_at: started, sla_due_at: due)
      with_analyst.update_columns(state: "com_analista", assignee_id: analyst_in(setup[:team]).id)
      alerted = waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_c", started_at: started, sla_due_at: due)
      alerted.update_columns(sla_alerted_at: started + 8.minutes)
      no_sla = waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_d")

      expect(OutboxEvent.where(id: alert(started + 9.minutes)).pluck(:ticket_id)).to eq([ ticket.id ])
    end

    it "uma atribuição nova (devolvido à fila) gera chave nova" do
      alert(started + 9.minutes)
      ticket.update_columns(assignment_version: 2)

      expect(alert(started + 9.minutes).size).to eq(1)
      expect(OutboxEvent.pluck(:dedup_key)).to include("sla.alert:#{ticket.id}:0", "sla.alert:#{ticket.id}:2")
    end

    it "RF-25 (marca errada): com brand_id, só aquela marca" do
      jim_setup = distribution_setup(jim)
      waiting_case(brand: jim, queue: jim_setup[:queue], identity: "acc_j", started_at: started, sla_due_at: due)

      ids = alert(started + 9.minutes, brand_id: infinitepay.id)

      expect(OutboxEvent.where(id: ids).pluck(:brand_id)).to eq([ infinitepay.id ])
    end

    it "acorda o worker depois do commit" do
      expect { alert(started + 9.minutes) }.to have_enqueued_job(OutboxJob).with(be_a(String))
    end
  end

  describe Deadlines::SlaBreach do
    it "RN-26: no instante do prazo registra, e um instante antes não" do
      expect(breach(due - 1.second)).to eq([])

      item = OutboxEvent.find(breach(due).sole)

      expect(item).to have_attributes(event_type: "sla.breach", ticket_id: ticket.id, dedup_key: "sla.breach:#{ticket.id}:0")
    end

    it "não registra de novo o que já estourou, nem caso com analista (a assunção foi cumprida)" do
      ticket.update_columns(sla_breached: true)
      taken = waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_t", started_at: started, sla_due_at: due)
      taken.update_columns(state: "com_analista", assignee_id: analyst_in(setup[:team]).id)

      expect(breach(due + 1.hour)).to eq([])
    end

    it "repetição: um item só" do
      expect(breach(due).size).to eq(1)
      expect(breach(due + 1.minute)).to eq([])
    end
  end
end
