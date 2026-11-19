require "rails_helper"

RSpec.describe Turns::Open, "RF-29, RF-33: abertura do turno e do evento para o agente" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "pt-BR") }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  def open_for(result) = described_class.call(received_item(result).id)

  describe "caminho feliz" do
    it "grava o turno elegível e o evento no outbox, e encerra o aviso da ingestão, na mesma transação" do
      received = ingest("meu repasse não caiu", trace_id: "4bf92f3577b34da6a3ce929d0e0e4736")

      result = open_for(received)

      turn = result.turn
      expect(result.status).to eq(:opened)
      expect(turn).to have_attributes(turn: 1, status: "eligible", context_until_seq: 1, assignment_version: 0,
                                      brand_id: infinitepay.id, ticket_id: received.ticket.id)
      event = OutboxEvent.find(turn.event_id)
      expect(event).to have_attributes(event_type: "agent.event", ticket_id: received.ticket.id, brand_id: infinitepay.id,
                                       trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", completed_at: nil, attempts: 0)
      expect(event.next_attempt_at).to eq(Time.current)
      expect(received_item(received).completed_at).to eq(Time.current)
    end

    it "RNF-28: o evento sai dentro do contrato agent_inbound, com o event_id igual ao id do outbox" do
      received = ingest
      turn = open_for(received).turn

      payload = OutboxEvent.find(turn.event_id).payload

      expect(HelpdeskContracts.errors(:agent_inbound, payload)).to be_empty
      expect(payload).to include(
        "schema" => "helpdesk.agent_event.v1", "event_id" => turn.event_id,
        "event_type" => "message.created", "conversation_id" => "tkt_#{received.ticket.id}", "brand" => "infinitepay",
        "locale" => "pt-BR", "turn" => 1, "context_until_seq" => 1, "assignment_version" => 0,
        "occurred_at" => start.utc.iso8601(3)
      )
      expect(payload["ticket"]).to eq("state" => "novo", "channel" => "chat", "ai_turns" => 0)
      expect(payload["customer"]).to include("id" => "cus_#{received.ticket.customer_id}", "verified" => false)
      expect(payload["message"]).to eq("id" => "msg_#{received.message.id}", "seq" => 1, "text" => "meu repasse não caiu")
    end

    it "RN-49: leva todas as mensagens do cliente ainda sem resposta, por inteiro e na ordem do seq" do
      ingest("meu repasse não caiu")
      second = ingest("é o de ontem, R$ 1.200")

      payload = OutboxEvent.find(open_for(second).turn.event_id).payload

      expect(payload.dig("context", "pending_messages")).to eq([ { "seq" => 1, "text" => "meu repasse não caiu" },
                                                                 { "seq" => 2, "text" => "é o de ontem, R$ 1.200" } ])
      expect(payload.dig("context", "history")).to eq([])
      expect(payload["context_until_seq"]).to eq(2)
      expect(payload["message"]).to include("seq" => 2)
    end

    it "RN-46: o prazo é 30 s desde a primeira mensagem pendente e é o mesmo para os turnos do ciclo" do
      first = ingest("meu repasse não caiu")
      first_turn = open_for(first).turn
      travel 3.seconds
      second_turn = open_for(ingest("é o de ontem")).turn

      expect(first_turn.deadline_at).to eq(start + 30.seconds)
      expect(second_turn).to have_attributes(turn: 2, deadline_at: start + 30.seconds)
      expect(OutboxEvent.find(second_turn.event_id).payload["deadline_at"]).to eq((start + 30.seconds).utc.iso8601(3))
    end

    it "RF-54, RF-56: audita a abertura com o trace_id da mensagem" do
      received = ingest(trace_id: "4bf92f3577b34da6a3ce929d0e0e4736")
      turn = open_for(received).turn

      audit = received.ticket.audit_events.find_by!(event_type: "ai_turn.opened")
      expect(audit).to have_attributes(trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", brand_id: infinitepay.id,
                                       actor_type: "system")
      expect(audit.data).to include("turn" => 1, "event_id" => turn.event_id, "context_until_seq" => 1,
                                    "pending_seqs" => [ 1 ])
    end
  end

  describe "repetição" do
    it "RNF-15: processar o mesmo aviso de novo não abre outro turno nem outro evento" do
      received = ingest
      open_for(received)

      again = open_for(received)

      expect(again.status).to eq(:already_done)
      expect(AiTurn.count).to eq(1)
      expect(OutboxEvent.where(event_type: "agent.event").count).to eq(1)
    end
  end

  describe "ordem" do
    it "o aviso da mensagem 2 processado antes do da 1: o turno cobre as duas e o aviso da 1 não abre outro" do
      first = ingest("meu repasse não caiu")
      second = ingest("é o de ontem")

      opened = open_for(second)
      covered = open_for(first)

      expect(opened.turn).to have_attributes(turn: 1, context_until_seq: 2)
      expect(covered.status).to eq(:covered)
      expect(AiTurn.count).to eq(1)
      expect(received_item(first).completed_at).to be_present
      expect(first.ticket.audit_events.where(event_type: "ai_turn.not_opened").last.data)
        .to include("reason" => "coberto", "covered_by_turn" => 1)
    end
  end

  describe "marca errada" do
    it "ADR-014: o evento leva só a marca e as mensagens do próprio atendimento" do
      ingest("mensagem da InfinitePay", identity: "acc_compartilhada")
      jim_received = ingest("mensagem da JIM", brand: "jim", identity: "acc_compartilhada")

      payload = OutboxEvent.find(open_for(jim_received).turn.event_id).payload

      expect(payload["brand"]).to eq("jim")
      expect(payload.dig("context", "pending_messages").map { _1["text"] }).to eq([ "mensagem da JIM" ])
      expect(AiTurn.last.brand_id).to eq(jim.id)
      expect(OutboxEvent.find(payload["event_id"]).brand_id).to eq(jim.id)
    end
  end

  describe "atendimento fora da IA" do
    it "07, seção 3.3: caso com analista não abre turno; o aviso é encerrado com auditoria" do
      received = ingest
      analyst = create(:user)
      received.ticket.update!(state: "com_analista", assignee: analyst)

      result = open_for(received)

      expect(result.status).to eq(:skipped)
      expect(AiTurn.count).to eq(0)
      expect(received_item(received).completed_at).to be_present
      expect(received.ticket.audit_events.last).to have_attributes(event_type: "ai_turn.not_opened")
      expect(received.ticket.audit_events.last.data).to include("reason" => "fora_da_ia", "state" => "com_analista")
    end
  end

  describe "tempo no limite (RN-46)" do
    it "abre o turno a 1 ms do prazo" do
      received = ingest
      travel_to(start + 30.seconds - 0.001, with_usec: true)

      expect(open_for(received).status).to eq(:opened)
    end

    it "não abre o turno com o prazo vencido: o caso segue pelo timeout (bloco 08)" do
      received = ingest
      travel_to(start + 30.seconds)

      result = open_for(received)

      expect(result.status).to eq(:expired)
      expect(AiTurn.count).to eq(0)
      expect(received.ticket.audit_events.last.data).to include("reason" => "prazo_vencido")
    end
  end

  describe "concorrência", :concurrency do
    it "dois workers com o mesmo aviso abrem um turno só" do
      item_id = received_item(ingest).id

      results = run_concurrently(threads: 2) { described_class.call(item_id) }

      expect(results.map(&:status)).to contain_exactly(:opened, :already_done)
      expect(AiTurn.count).to eq(1)
    end

    it "os avisos de duas mensagens da mesma conversa, juntos, numeram os turnos sem colisão" do
      ids = [ received_item(ingest("um")).id, received_item(ingest("dois")).id ]

      results = run_concurrently(threads: 2) { |i| described_class.call(ids[i]) }

      expect(results).to all(be_a(Turns::Open::Result))
      expect(AiTurn.order(:turn).pluck(:turn)).to eq((1..AiTurn.count).to_a)
      expect(AiTurn.maximum(:context_until_seq)).to eq(2)
    end
  end
end
