require "rails_helper"

# ROADMAP 05, Frontend: distinguir ação recebida, resposta aplicada e resposta entregue. Os registros são
# gravados no formato combinado do bloco 05 (spec/support/delivery_records.rb): mensagem outbound,
# deliveries e auditoria delivery.*. Tempo controlado com freeze_time e travel.
RSpec.describe "ROADMAP 05: entrega no painel (RecordedConversations)" do
  subject(:source) { RecordedConversations.new }

  let!(:brand) { create(:brand, :infinitepay) }
  let(:t0) { Time.zone.parse("2026-11-20 12:00:00") }

  before { travel_to(t0) }

  # t0: mensagem do cliente; +3 s: turno aberto; +5 s: ação recebida; +6 s: saída gravada (applied);
  # +7 s: envio; +8 s: entregue.
  def applied_turn(text: "Seu repasse cai hoje até as 18h.")
    turn = open_turn_for(ingest("meu repasse não caiu"))
    travel_to(t0 + 3)
    turn.update_columns(created_at: Time.current)
    travel_to(t0 + 5)
    record_agent_action(turn, agent_action_payload(turn, text:), occurred_at: Time.current)
    travel_to(t0 + 6)
    [ turn, record_outbound(turn, text:) ]
  end

  def deliver(delivery, provider_message_id: "pmsg_0001")
    travel_to(t0 + 7)
    record_delivery_sending(delivery)
    travel_to(t0 + 8)
    record_delivery_delivered(delivery, duration_ms: 180, provider_message_id:)
  end

  def outbound_message(view) = view.messages.find { _1.direction == "outbound" }

  describe "RF-06: status da entrega na conversa" do
    it "entregue: mostra horário e provider_message_id, ligada ao turno" do
      turn, delivery = applied_turn
      deliver(delivery)

      message = outbound_message(source.find(turn.ticket_id.to_s))

      expect(message).to have_attributes(seq: 2, author_type: "bot", delivery_status: "delivered",
                                         delivery_id: delivery.delivery_id)
      expect(message.delivery).to have_attributes(status: "delivered", provider_message_id: "pmsg_0001",
                                                  delivered_at: t0 + 8, turn: 1, attempts: 1,
                                                  reconciliation_needed: false)
    end

    it "pendente: sem tentativa ainda" do
      turn, = applied_turn

      message = outbound_message(source.find(turn.ticket_id.to_s))

      expect(message.delivery).to have_attributes(status: "pending", attempts: 0, delivered_at: nil)
    end

    it "RNF-15: enviando na 2ª tentativa, depois de uma retentativa agendada com o mesmo delivery_id" do
      turn, delivery = applied_turn
      record_delivery_sending(delivery, attempt: 1)
      travel_to(t0 + 7)
      record_delivery_retry(delivery, attempt: 1, error: "503 falha simulada", next_attempt_at: t0 + 9)
      travel_to(t0 + 9)
      record_delivery_sending(delivery, attempt: 2)

      message = outbound_message(source.find(turn.ticket_id.to_s))

      expect(message.delivery).to have_attributes(status: "sending", attempts: 2, last_error: "503 falha simulada",
                                                  delivery_id: delivery.delivery_id)
    end

    it "falhou: mostra o motivo e o status HTTP da auditoria" do
      turn, delivery = applied_turn
      record_delivery_sending(delivery)
      record_delivery_failed(delivery, reason: "seq_anterior", http_status: 409)

      message = outbound_message(source.find(turn.ticket_id.to_s))

      expect(message.delivery).to have_attributes(status: "failed", failure_reason: "seq_anterior", http_status: 409)
      expect(message.delivery.failure_reason_label).to include("seq")
    end

    it "RNF-16: marca a conciliação pendente" do
      turn, delivery = applied_turn
      record_delivery_sending(delivery, attempt: 3)
      record_reconciliation_needed(delivery, attempts: 3)

      expect(outbound_message(source.find(turn.ticket_id.to_s)).delivery.reconciliation_needed).to be(true)
    end

    it "cancelada" do
      turn, delivery = applied_turn
      delivery.update_columns(status: "cancelled")

      expect(outbound_message(source.find(turn.ticket_id.to_s))).to have_attributes(delivery_status: "cancelled")
    end

    it "ordem: duas saídas aparecem na ordem do seq, cada uma com a sua entrega" do
      turn, first = applied_turn(text: "Primeira resposta")
      deliver(first)
      travel_to(t0 + 10)
      ingest("e o de hoje?")
      turn2 = open_turn_for(Ticket.find(turn.ticket_id))
      record_agent_action(turn2, agent_action_payload(turn2, text: "Segunda resposta"), occurred_at: Time.current)
      second = record_outbound(turn2, text: "Segunda resposta")

      view = source.find(turn.ticket_id.to_s)

      outbound = view.messages.select { _1.direction == "outbound" }
      expect(view.messages.map(&:seq)).to eq([ 1, 2, 3, 4 ])
      expect(outbound.map(&:body)).to eq([ "Primeira resposta", "Segunda resposta" ])
      expect(outbound.map { _1.delivery.status }).to eq(%w[delivered pending])
      expect(outbound.map { _1.delivery.turn }).to eq([ 1, 2 ])
      expect(outbound.map(&:delivery_id)).to eq([ first.delivery_id, second.delivery_id ])
    end

    it "marca errada: a entrega e a auditoria de outra marca não entram na conversa" do
      turn, delivery = applied_turn
      deliver(delivery)
      other = create(:brand, :jim)
      travel_to(t0 + 20)
      jim_turn = open_turn_for(ingest("meu repasse não caiu", brand: "jim"))
      jim_delivery = record_outbound(jim_turn, text: "Resposta da JIM")
      record_delivery_failed(jim_delivery)

      view = source.find(turn.ticket_id.to_s)
      timeline = source.timeline(turn.ticket_id.to_s)

      expect(jim_turn.brand_id).to eq(other.id)
      expect(view.messages.map(&:body)).not_to include("Resposta da JIM")
      expect(timeline.events.map(&:trace_id)).not_to include(jim_delivery.trace_id)
      expect(timeline.events.map(&:kind)).not_to include(:delivery_failed)
    end
  end

  describe "RNF-05: estágios do turno (ação recebida, resposta aplicada, resposta entregue)" do
    it "entregue: os três estágios com horário, duração desde o anterior e o tempo total percebido" do
      turn, delivery = applied_turn
      deliver(delivery)

      stages = source.find(turn.ticket_id.to_s).turns.first.stages

      expect(stages).to have_attributes(opened_at: t0 + 3, received_at: t0 + 5, applied_at: t0 + 6,
                                        delivered_at: t0 + 8, first_customer_at: t0, discarded: false)
      expect(stages.received_ms).to eq(2_000)
      expect(stages.applied_ms).to eq(1_000)
      expect(stages.delivered_ms).to eq(2_000)
      expect(stages.perceived_total_ms).to eq(8_000)
    end

    it "aplicada e ainda não entregue: sem o estágio 3 nem o tempo total" do
      turn, = applied_turn

      stages = source.find(turn.ticket_id.to_s).turns.first.stages

      expect(stages.applied_at).to eq(t0 + 6)
      expect(stages.delivered_at).to be_nil
      expect(stages.perceived_total_ms).to be_nil
    end

    it "RN-56: turno descartado não tem os estágios 2 e 3" do
      turn = open_turn_for(ingest("meu repasse não caiu"))
      travel_to(t0 + 2)
      ingest("é o de ontem")
      turn.update_columns(status: "superseded")
      travel_to(t0 + 4)
      record_agent_action(turn, agent_action_payload(turn), rejected: "turno_superado", occurred_at: Time.current)

      stages = source.find(turn.ticket_id.to_s).turns.first.stages

      expect(stages).to have_attributes(received_at: t0 + 4, applied_at: nil, delivered_at: nil, discarded: true)
      expect(stages.perceived_total_ms).to be_nil
    end

    it "turno sem resposta do agente: sem estágios" do
      turn = open_turn_for(ingest("meu repasse não caiu"))

      expect(source.find(turn.ticket_id.to_s).turns.first.stages).to be_nil
    end
  end

  describe "RF-55, RF-56: eventos de entrega na linha do tempo" do
    it "liga cada evento ao seq da saída, ao turno e ao trace_id, com tentativa e duração da chamada" do
      turn, delivery = applied_turn
      deliver(delivery)
      travel_to(t0 + 9)
      record_status_received(delivery, status: "read")

      events = source.timeline(turn.ticket_id.to_s).events.select { _1.kind.to_s.start_with?("deliver") }

      expect(events.map(&:kind)).to eq(%i[delivery_requested delivery_sending delivered delivery_status])
      expect(events.map(&:seq).uniq).to eq([ 2 ])
      expect(events.map(&:turn).uniq).to eq([ 1 ])
      expect(events.map(&:trace_id).uniq).to eq([ delivery.trace_id ])
      delivered = events.find { _1.kind == :delivered }
      expect(delivered).to have_attributes(started_at: t0 + 8 - Rational(180, 1000), finished_at: t0 + 8, duration_ms: 180)
      expect(delivered.detail).to include("tentativa 1", "pmsg_0001")
    end

    it "retentativa e falha viram eventos com a origem do erro, a tentativa e o próximo passo" do
      turn, delivery = applied_turn
      record_delivery_sending(delivery, attempt: 1)
      record_delivery_retry(delivery, attempt: 1, error: "503 falha simulada", next_attempt_at: t0 + 9)
      travel_to(t0 + 9)
      record_delivery_sending(delivery, attempt: 2)
      record_delivery_failed(delivery, attempt: 2, reason: "contrato", http_status: 422)
      record_reconciliation_needed(delivery, attempts: 2)

      events = source.timeline(turn.ticket_id.to_s).events

      retry_event = events.find { _1.kind == :delivery_retry_scheduled }
      expect(retry_event.error).to have_attributes(attempt: 1, retry: true, next_attempt_at: t0 + 9,
                                                   message: "503 falha simulada", retry_key: "delivery_id")
      failed = events.find { _1.kind == :delivery_failed }
      expect(failed.error).to have_attributes(origin: "contrato", http_status: 422, attempt: 2, retry: false)
      expect(events.find { _1.kind == :delivery_reconciliation }.error.outcome).to eq("conciliacao_pendente")
      expect(events.select { _1.kind == :delivery_sending }.map { _1.detail[/tentativa \d/] }).to eq([ "tentativa 1", "tentativa 2" ])
    end
  end
end
