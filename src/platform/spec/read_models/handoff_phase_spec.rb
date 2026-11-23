require "rails_helper"

# Motivo do timeout e do handoff na conversa (ROADMAP 08 Frontend; RN-46, RF-36, RNF-18), lido da auditoria no formato
# combinado dos blocos 08 e 09 (itens 1 e 5): handoff.requested, ticket.escalated, handoff.discarded e delivery.cancelled
# com reason "handoff" (spec/support/handoff_records.rb).
RSpec.describe "RN-46, RF-36, RNF-18: motivo do timeout e do handoff (HandoffPhase)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 21, 13, 40, 0) }
  let!(:ticket) { at(t0) { ingest("meu repasse não caiu").ticket } }
  let!(:queue) { default_queue_for(infinitepay, name: "Suporte InfinitePay") }

  def at(time, &) = travel_to(time, with_usec: true, &)
  def view = HandoffPhase.new(ticket.reload).view

  describe "RN-46: timeout do turno" do
    it "o caso na fila humana com a fila, o motivo, o gatilho, o turno e a espera desde a primeira pendente" do
      turn = at(t0 + 1.5.seconds) { record_turn_06(ticket) }
      request = at(t0 + 21.6.seconds) do
        record_timeout_scheduled(ticket, scope: :turn, turn:)
        record_turn_expired(turn)
        record_handoff_requested(ticket, reason: "prazo_do_turno", source: "scheduler", turn:)
      end
      at(t0 + 21.8.seconds) { record_escalated(ticket, request) }

      expect(view).to have_attributes(state: :escalated, reason: "prazo_do_turno", source: "scheduler", turn: 1,
                                      first_pending_seq: 1, queue_name: "Suporte InfinitePay", queue_id: queue.id,
                                      from_assignment_version: 0, to_assignment_version: 1,
                                      trace_id: request.trace_id, waited_ms: 21_800)
      expect(view.requested_at).to be_within(0.001).of(t0 + 21.6.seconds)
      expect(view.resolved_at).to be_within(0.001).of(t0 + 21.8.seconds)
      expect(view.headline).to eq("Na fila humana: Suporte InfinitePay")
      expect(view.reason_label).to eq("Prazo do turno vencido (20 s desde a abertura, RN-46)")
      expect(view.source_label).to eq("Scheduler: prazo vencido no Postgres (ADR-016)")
    end
  end

  describe "RN-46: teto do ciclo, sem turno publicado" do
    it "mostra teto do ciclo como motivo, sem turno" do
      request = at(t0 + 60.2.seconds) do
        record_timeout_scheduled(ticket, scope: :cycle)
        record_handoff_requested(ticket, reason: "teto_do_ciclo", source: "scheduler")
      end
      at(t0 + 60.3.seconds) { record_escalated(ticket, request) }

      expect(view).to have_attributes(state: :escalated, reason: "teto_do_ciclo", turn: nil, waited_ms: 60_300)
      expect(view.reason_label).to eq("Teto do ciclo vencido (60 s desde a primeira mensagem pendente, RN-46)")
    end
  end

  describe "RN-46: publicação falhou de forma definitiva" do
    it "mostra publicação falhou com o gatilho do outbox" do
      turn = at(t0 + 1.5.seconds) { record_turn_06(ticket) }
      request = at(t0 + 2.seconds) { record_handoff_requested(ticket, reason: "publicacao_falhou", source: "outbox", turn:) }
      at(t0 + 2.1.seconds) { record_escalated(ticket, request) }

      expect(view).to have_attributes(reason: "publicacao_falhou", source: "outbox", turn: 1)
      expect(view.reason_label).to eq("Publicação do turno falhou de forma definitiva (RN-46)")
      expect(view.source_label).to eq("Outbox: publicação para o agente")
    end
  end

  describe "07, seção 3.2: saídas canceladas pelo handoff" do
    it "lista as entregas pending da atribuição antiga canceladas com o motivo handoff; sending fica para conciliação" do
      at(t0) { record_progress_due(ticket) }
      progress = at(t0 + 15.3.seconds) { record_progress_sent(ticket) }
      turn = at(t0 + 16.seconds) { record_turn_06(ticket) }
      reply = at(t0 + 17.seconds) { record_outbound(turn) }
      at(t0 + 17.1.seconds) { record_delivery_sending(reply) }
      request = at(t0 + 60.2.seconds) { record_handoff_requested(ticket, reason: "teto_do_ciclo", source: "scheduler") }
      at(t0 + 60.3.seconds) { record_escalated(ticket, request) }

      expect(view.cancelled_deliveries.map { [ _1.delivery_id, _1.seq, _1.kind ] })
        .to eq([ [ progress.delivery_id, 2, "progress" ] ])
      expect(reply.reload.status).to eq("sending")
    end
  end

  describe "pedido sem desfecho e pedido descartado" do
    it "pedido registrado e ainda não processado pelo worker" do
      at(t0 + 60.2.seconds) { record_handoff_requested(ticket, reason: "teto_do_ciclo", source: "scheduler") }

      expect(view).to have_attributes(state: :requested, resolved_at: nil, queue_name: nil)
      expect(view.headline).to eq("Handoff pedido: aguardando o worker")
    end

    it "descartado: mostra o motivo do descarte e o motivo pedido; o caso continua como estava" do
      request = at(t0 + 60.2.seconds) { record_handoff_requested(ticket, reason: "teto_do_ciclo", source: "scheduler") }
      at(t0 + 60.3.seconds) { record_handoff_discarded(ticket, request, reason: "atribuicao_mudou") }

      expect(view).to have_attributes(state: :discarded, reason: "teto_do_ciclo", discard_reason: "atribuicao_mudou")
      expect(view.headline).to eq("Pedido de handoff descartado")
      expect(view.discard_reason_label).to eq("o atendimento mudou de responsável desde o pedido")
    end

    it "ordem: o desfecho vale para o pedido da mesma atribuição; o pedido seguinte aparece como o atual" do
      first = at(t0 + 60.2.seconds) { record_handoff_requested(ticket, reason: "teto_do_ciclo", source: "scheduler") }
      at(t0 + 60.3.seconds) { record_escalated(ticket, first) }
      at(t0 + 61.seconds) { record_handoff_requested(ticket, reason: "falha_de_integracao", source: "dlq") }

      expect(view).to have_attributes(state: :requested, reason: "falha_de_integracao", source: "dlq")
    end

    it "sem pedido de handoff: sem bloco" do
      expect(view).to be_nil
    end
  end

  describe "invariante 6: marca errada" do
    it "o handoff de um atendimento de outra marca não aparece; a fila é a da marca do atendimento" do
      other = at(t0) { ingest("oi da JIM", brand: "jim", identity: "acc_jim_000021").ticket }
      default_queue_for(jim, name: "Suporte JIM")
      request = at(t0 + 60.2.seconds) { record_handoff_requested(other, reason: "teto_do_ciclo", source: "scheduler") }
      at(t0 + 60.3.seconds) { record_escalated(other, request) }

      expect(view).to be_nil
      expect(HandoffPhase.new(other.reload).view.queue_name).to eq("Suporte JIM")
    end
  end
end
