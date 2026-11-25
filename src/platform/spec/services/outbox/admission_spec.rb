require "rails_helper"

# ADR-035: controle de admissão. A plataforma segura a fila do agente e só publica quando há vaga; com o agente cheio,
# o turno espera na plataforma (prazo mais próximo primeiro), o cliente é avisado cedo e, se a resposta não couber no
# prazo do turno, o caso vai para um humano na hora (RN-46, motivo agente_sem_vaga).
RSpec.describe Outbox::Admission, "ADR-035: fila na plataforma e limite de turnos no agente" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }

  around { |example| travel_to(start) { example.run } }
  before { stub_broker }

  def open_event(number)
    OutboxEvent.find(opened_turn(identity: "acc_infinitepay_0001#{number}").event_id)
  end

  def publish(item) = Outbox::Publish.call(item.id, jitter: -> { 0.0 })
  def turn_of(item) = AiTurn.find_by!(event_id: item.id)

  it "sem limite configurado fica desligado e a publicação segue como antes" do
    expect(described_class.limit).to be_nil
    publish(open_event(1))

    expect(publish(open_event(2)).status).to eq(:published)
  end

  context "com o agente aceitando 1 turno por vez" do
    before { allow(described_class).to receive(:limit).and_return(1) }

    it "agente cheio: o turno espera na plataforma, sem chamar o broker nem gastar tentativa" do
      publish(open_event(1))
      waiting = open_event(2)

      result = publish(waiting)

      expect(result).to have_attributes(status: :waiting_slot, next_attempt_at: start + described_class::POLL)
      expect(broker_requests.size).to eq(1)
      expect(waiting.reload).to have_attributes(attempts: 0, completed_at: nil, published_at: nil, lease_until: nil,
                                                next_attempt_at: start + described_class::POLL)
    end

    it "a vaga volta quando a resposta do turno chega, e o próximo sai" do
      first = open_event(1)
      publish(first)
      waiting = open_event(2)
      publish(waiting)
      turn_of(first).update_columns(response_received_at: start)
      travel described_class::POLL

      expect(publish(waiting).status).to eq(:published)
    end

    it "prazo mais próximo primeiro: com dois na espera, só o da frente ocupa a vaga" do
      ahead = open_event(1)
      behind = open_event(2)
      turn_of(behind).update_columns(deadline_at: start + 25.seconds)

      expect(publish(behind).status).to eq(:waiting_slot)
      expect(publish(ahead).status).to eq(:published)
    end

    it "na espera há 5 s: adianta o aviso de progresso ao cliente (RN-57)" do
      publish(open_event(1))
      waiting = open_event(2)
      travel described_class::NOTICE_AFTER

      publish(waiting)

      expect(Ticket.find(waiting.ticket_id).progress_due_at).to eq(Time.current)
    end

    it "a resposta não cabe mais no prazo do turno: pede o handoff na hora (agente_sem_vaga), sem esperar o timeout" do
      publish(open_event(1))
      waiting = open_event(2)
      turn = turn_of(waiting)
      travel_to(turn.deadline_at - described_class.expected_agent_time + 1.second)

      result = publish(waiting)

      expect(result.status).to eq(:expired)
      handoff = OutboxEvent.find(result.handoff_event_id)
      expect(handoff.payload).to include("reason" => "agente_sem_vaga", "source" => "outbox", "turn" => turn.turn)
      expect(waiting.reload.completed_at).to be_present
      expect(AuditEvent.where(event_type: "agent_event.publish_failed").sole.data).to include("outcome" => "agente_sem_vaga")
      expect(broker_requests.size).to eq(1)
    end

    it "turno que ficou obsoleto na espera é descartado sem ocupar o agente" do
      publish(open_event(1))
      waiting = open_event(2)
      turn_of(waiting).update_columns(status: "superseded")

      expect(publish(waiting).status).to eq(:discarded)
      expect(broker_requests.size).to eq(1)
    end
  end
end
