require "rails_helper"

# ROADMAP 09, Frontend: tentativas e desfecho de cada item do outbox ligado ao atendimento (RF-34, RNF-16,
# RN-43, RN-44). Publicação e entrega passam pelo caminho real (Outbox::Publish e Deliveries::Send, com o
# broker e o provedor simulados); recuperação e encerramento por obsolescência no formato combinado
# (spec/support/recovery_records.rb). Tempo controlado com travel_to.
RSpec.describe OutboxAttempts, "RF-34: tentativas e desfecho por item do outbox" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:t0) { Time.zone.parse("2026-11-20 12:00:00") }
  let(:no_jitter) { -> { 0.0 } }

  before { travel_to(t0) }

  def opened_turn
    turn = open_turn_for(ingest("meu repasse não caiu"))
    turn.update_columns(deadline_at: t0 + 10.minutes)
    turn
  end

  # Cada chamada viaja até o despertador do item, como o worker acordado no next_attempt_at.
  def publish(turn, times)
    times.times do
      travel_to(OutboxEvent.find(turn.event_id).next_attempt_at)
      Outbox::Publish.call(turn.event_id, jitter: no_jitter)
    end
  end

  def item_for(ticket, event_type) = described_class.new(ticket.reload).items.find { _1.event_type == event_type }

  describe "RN-43: publicação do turno" do
    it "3 tentativas e publicado: duas falhas com o erro e a próxima tentativa, e a confirmação do Kafka" do
      turn = opened_turn
      stub_broker({ status: 503 }, { status: 503 }, { status: 200 })

      publish(turn, 3)

      item = item_for(turn.ticket, "agent.event")
      expect(item).to have_attributes(id: turn.event_id, turn: 1, attempts_count: 3, outcome: :published,
                                      outcome_label: "Publicado")
      expect(item.summary).to eq("3 tentativas · Publicado")
      first, second, third = item.attempts
      # Os horários das tentativas vêm da auditoria (relógio do banco); o despertador, do tempo do teste.
      expect(first).to have_attributes(number: 1, next_attempt_at: t0 + 1, result_label: "Falhou, nova tentativa agendada")
      expect(first.error.origin_label).to start_with("Kafka")
      expect(first.error.message).to eq("Kafka sem confirmação (via broker)")
      expect(second).to have_attributes(number: 2, next_attempt_at: t0 + 3)
      expect(third).to have_attributes(number: 3, error: nil, next_attempt_at: nil, duration_ms: 0, result_label: "Publicado")
      expect(item.attempts.map(&:at)).to eq(item.attempts.map(&:at).sort)
    end

    it "RN-43: esgotou as retentativas: falhou definitivo, com o desfecho na última tentativa" do
      turn = opened_turn
      stub_broker({ status: 503 })

      publish(turn, 6)

      item = item_for(turn.ticket, "agent.event")
      expect(item).to have_attributes(attempts_count: 6, outcome: :failed)
      expect(item.outcome_label).to eq("Falhou definitivo: Retentativas esgotadas (RN-43)")
      expect(item.attempts.size).to eq(6)
      expect(item.attempts.last.error).to have_attributes(retry: false, outcome: "retentativas_esgotadas")
      expect(item.attempts.last.next_attempt_at).to be_nil
    end

    it "RN-44: recusa permanente do broker: uma tentativa, falhou definitivo com a origem" do
      turn = opened_turn
      stub_broker({ status: 401 })

      publish(turn, 1)

      item = item_for(turn.ticket, "agent.event")
      expect(item).to have_attributes(attempts_count: 1, outcome: :failed)
      expect(item.outcome_label).to eq("Falhou definitivo: Assinatura HMAC recusada pelo broker (RNF-23)")
    end

    it "em retentativa: o item aberto mostra a próxima tentativa (tempo no limite do despertador)" do
      turn = opened_turn
      stub_broker({ status: 503 })

      publish(turn, 1)

      item = item_for(turn.ticket, "agent.event")
      expect(item).to have_attributes(outcome: :retrying, next_attempt_at: t0 + 1)
      expect(item.outcome_label).to eq("Em retentativa")
    end

    it "descartado: turno superado antes de sair, com o motivo" do
      turn = opened_turn
      turn.update_columns(status: "superseded")

      publish(turn, 1)

      expect(item_for(turn.ticket, "agent.event").outcome_label).to eq("Descartado: Turno superado por mensagem nova do cliente (RN-56)")
    end

    it "aguardando: item ainda sem tentativa" do
      turn = opened_turn

      expect(item_for(turn.ticket, "agent.event")).to have_attributes(attempts_count: 0, outcome: :pending,
                                                                         summary: "0 tentativas · Aguardando")
    end
  end

  describe "RNF-15: entrega ao canal" do
    let!(:account) { create(:provider_account, brand:, slug: "infinitepay-chat-mock") }

    def send_delivery(delivery, times)
      times.times do
        travel_to(delivery_item(delivery).reload.next_attempt_at)
        Deliveries::Send.call(delivery_item(delivery).id, jitter: no_jitter)
      end
    end

    it "retentativa e entregue: a tentativa falha com o erro e a seguinte entrega, com a duração da chamada" do
      ticket = customer_message.ticket
      delivery = requested_delivery(ticket)
      stub_channels({ status: 503 }, { status: 200 })

      send_delivery(delivery, 2)

      item = item_for(ticket, "delivery.requested")
      expect(item).to have_attributes(delivery_id: delivery.delivery_id, seq: delivery.seq, turn: 1, attempts_count: 2,
                                      outcome: :delivered, outcome_label: "Entregue")
      first, second = item.attempts
      expect(first).to have_attributes(number: 1, next_attempt_at: t0 + 1)
      expect(first.error.origin_label).to start_with("Provedor: falha transitória")
      expect(first.error.message).to eq("http 503")
      expect(second).to have_attributes(number: 2, error: nil, duration_ms: 0, result_label: "Entregue")
    end

    it "conciliação: resultado incerto em todas as tentativas, a entrega fica em conciliação" do
      ticket = customer_message.ticket
      delivery = requested_delivery(ticket)
      stub_channels({ timeout: true })

      send_delivery(delivery, Deliveries::Policy::MAX_ATTEMPTS)

      item = item_for(ticket, "delivery.requested")
      expect(item).to have_attributes(attempts_count: 6, outcome: :reconciliation)
      expect(item.outcome_label).to eq("Em conciliação")
      expect(item.attempts.last.error.outcome).to eq("conciliacao_pendente")
    end
  end

  describe "ROADMAP 09: recuperação" do
    it "obsoleto: item encerrado pela política de recuperação, com o motivo" do
      turn = opened_turn
      travel_to(t0 + 2)
      record_outbox_closed_obsolete(OutboxEvent.find(turn.event_id), reason: "turno_superseded")

      item = item_for(turn.ticket, "agent.event")
      expect(item).to have_attributes(outcome: :closed_obsolete, completed_at: t0 + 2)
      expect(item.outcome_label).to eq("Encerrado como obsoleto: Turno superado por mensagem nova do cliente (RN-56)")
      expect(item.attempts.last).to have_attributes(at: t0 + 2, result_label: item.outcome_label)
    end

    it "reoferecido pela recuperação: o item aberto mostra o reoferecimento e quantas vezes (repetição)" do
      turn = opened_turn
      item = OutboxEvent.find(turn.event_id)
      travel_to(t0 + 6)
      record_outbox_recovered(item)
      travel_to(t0 + 12)
      record_outbox_recovered(item)

      view = item_for(turn.ticket, "agent.event")
      expect(view).to have_attributes(outcome: :recovered, recovered_count: 2)
      expect(view.outcome_label).to eq("Reoferecido pela recuperação")
      expect(view.attempts.map(&:at)).to eq([ t0 + 6, t0 + 12 ])
    end

    it "reoferecido e depois publicado: o desfecho final é a publicação" do
      turn = opened_turn
      travel_to(t0 + 6)
      record_outbox_recovered(OutboxEvent.find(turn.event_id))
      stub_broker({ status: 200 })

      publish(turn, 1)

      expect(item_for(turn.ticket, "agent.event")).to have_attributes(outcome: :published, recovered_count: 1)
    end
  end

  describe "invariante 6: marca errada" do
    it "não mistura auditoria de outro atendimento de outra marca que cite o mesmo item" do
      turn = opened_turn
      create(:brand, :jim)
      other = ingest(brand: "jim").ticket
      AuditEvent.create!(brand_id: other.brand_id, ticket_id: other.id, actor_type: "system", event_type: "outbox.recovered",
                         trace_id: "x", data: { outbox_event_id: turn.event_id, event_id: turn.event_id })

      view = item_for(turn.ticket, "agent.event")

      expect(view.recovered_count).to eq(0)
      expect(view.outcome).to eq(:pending)
      expect(described_class.new(other).items).to be_empty
    end
  end

  it "não lista message.received nem turn.dispatch (sem tentativa a mostrar)" do
    turn = opened_turn

    expect(described_class.new(turn.ticket.reload).items.map(&:event_type)).to eq([ "agent.event" ])
  end
end
