require "rails_helper"

RSpec.describe Outbox::Publish, "RF-34, RN-43: limites da publicação quando a recuperação retoma o item" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-21T10:00:00Z") }
  let(:jitter) { -> { 0.0 } }

  around { |example| travel_to(start) { example.run } }

  def open_event(text = "meu repasse não caiu", **)
    OutboxEvent.find(open_turn_for(ingest(text, **)).event_id)
  end

  def publish(item) = described_class.call(item.id, jitter:)
  def audits(type) = AuditEvent.where(event_type: type).order(:id)

  describe "RN-43: tentativas abandonadas (worker caiu depois da reserva) contam no limite" do
    it "a 6ª tentativa ainda sai; a 7ª reserva encerra como retentativas_esgotadas sem chamar o broker" do
      item = open_event
      AiTurn.find_by!(event_id: item.id).update_columns(deadline_at: start + 1.hour)
      stub_broker
      item.update_columns(attempts: 5, lease_until: start - 1.second)

      expect(publish(item).status).to eq(:published)

      other = open_event("outro", identity: "acc_outro")
      AiTurn.find_by!(event_id: other.id).update_columns(deadline_at: start + 1.hour)
      other.update_columns(attempts: 6, lease_until: start - 1.second)

      expect(publish(other).status).to eq(:exhausted)
      expect(broker_requests.size).to eq(1)
      expect(other.reload).to have_attributes(attempts: 7, lease_until: nil, published_at: nil)
      expect(other.completed_at).to eq(start)
      expect(audits("agent_event.publish_failed").sole.data).to include(
        "event_id" => other.id, "attempt" => 7, "retry" => false, "outcome" => "retentativas_esgotadas", "origin" => "recuperacao"
      )
    end

    it "com a tentativa abandonada e o turno já superado, encerra como descarte (sem falha de publicação)" do
      item = open_event
      item.update_columns(attempts: 6, lease_until: start - 1.second)
      ingest("é o de ontem")
      stub_broker

      expect(publish(item).status).to eq(:discarded)
      expect(broker_requests).to be_empty
      expect(audits("agent_event.discarded").sole.data["reason"]).to eq("turno_superseded")
    end
  end

  describe "RNF-17: a reserva da tentativa" do
    it "cobre a chamada ao broker inteira e vence antes do prazo do turno, para a recuperação retomar a tempo" do
      call = (Outbox::BrokerClient::OPEN_TIMEOUT + Outbox::BrokerClient::READ_TIMEOUT).seconds

      expect(described_class::LEASE).to be > call
      expect(described_class::LEASE).to be < Turns::Policy.for(infinitepay).turn_deadline
    end
  end

  describe "RN-38, RF-34 + RF-35: caso fora da IA não volta para o agente" do
    it "atendimento passou a humano (estado) sem mudar a atribuição: o evento antigo não é publicado" do
      item = open_event
      item.ticket.update_columns(state: "aguardando_humano")
      stub_broker

      expect(publish(item).status).to eq(:discarded)
      expect(broker_requests).to be_empty
      expect(audits("agent_event.discarded").sole.data).to include("reason" => "fora_da_ia")
    end
  end
end
