require "rails_helper"

# RN-57 (07, seção 3.4, "Regras de tempo": "O worker registra a entrega do aviso somente enquanto o mesmo ciclo
# estiver pendente, com a IA e antes do timeout"; 07, seção 3.2: o aviso é uma saída com seq e delivery_id como as
# demais; 07, seção 4, deliveries.ai_first_pending_seq; ADR-016, ADR-021, ADR-022).
RSpec.describe Turns::ProgressNotice, "RN-57: worker do aviso de progresso" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }
  let(:pt_text) { Turns::Policy.for(infinitepay).progress_notice_text("pt-BR") }
  let(:en_text) { Turns::Policy.for(jim).progress_notice_text("en") }

  before { allow(DatabaseClock).to receive(:now) { Time.current } }

  def ingest_at(time, text = "meu repasse não caiu", brand: "infinitepay", trace_id: SecureRandom.hex(16))
    travel_to(time, with_usec: true) { ingest(text, brand:, identity: "acc_aviso_#{brand}", trace_id:) }.ticket.reload
  end

  # O scheduler registra o aviso aos 15 s (Deadlines::ProgressDue).
  def due_notice(ticket, at: t0 + 15.seconds)
    travel_to(at, with_usec: true) { Deadlines::ProgressDue.call(now: Time.current, limit: 100, ticket_ids: [ ticket.id ]) }
    OutboxEvent.find_by!(dedup_key: "progress:#{ticket.id}:#{ticket.reload.first_pending_seq}")
  end

  def run_at(item, at = t0 + 15.1.seconds) = travel_to(at, with_usec: true) { described_class.call(item.id) }

  def outbound(ticket) = Message.where(ticket_id: ticket.id, brand_id: ticket.brand_id, direction: "outbound")
  def audits(ticket, type) = AuditEvent.where(ticket_id: ticket.id, event_type: type).order(:id)

  describe "RN-57: caso pendente com a IA aos 15 s" do
    let!(:ticket) { ingest_at(t0, trace_id: "c" * 32) }
    let!(:item) { due_notice(ticket) }

    it "grava a mensagem de saída do bot com o próximo seq, pelo canal e pela conta da última mensagem do cliente" do
      ingest_at(t0 + 2.seconds, "é o de ontem")

      expect(run_at(item).status).to eq(:sent)

      expect(outbound(ticket).sole).to have_attributes(
        brand_id: infinitepay.id, author_type: "bot", author_id: nil, internal: false, body: pt_text, seq: 3,
        channel: "chat", provider_account: "infinitepay-chat-mock", external_id: nil, trace_id: "c" * 32,
        received_at: be_within(0.000001).of(t0 + 15.1.seconds)
      )
    end

    it "grava a entrega kind progress pending com ai_first_pending_seq do ciclo e ai_assignment_version" do
      ticket.update_columns(assignment_version: 2)
      item.update_columns(payload: item.payload.merge("assignment_version" => 2))

      run_at(item)

      delivery = Delivery.where(ticket_id: ticket.id).sole
      expect(delivery).to have_attributes(brand_id: infinitepay.id, message_id: outbound(ticket).sole.id, seq: 2,
                                          kind: "progress", status: "pending", ai_first_pending_seq: 1,
                                          ai_assignment_version: 2, trace_id: "c" * 32, attempts: 0)
    end

    it "RNF-14: grava o item delivery.requested com a chave da entrega e conclui o item do aviso na mesma transação" do
      run_at(item)

      delivery = Delivery.where(ticket_id: ticket.id).sole
      requested = OutboxEvent.find_by!(dedup_key: "delivery:#{delivery.delivery_id}")
      expect(requested).to have_attributes(event_type: "delivery.requested", brand_id: infinitepay.id, ticket_id: ticket.id,
                                           trace_id: "c" * 32, completed_at: nil)
      expect(requested.payload).to eq("delivery_id" => delivery.delivery_id, "ticket_id" => ticket.id, "seq" => 2)
      expect(item.reload.completed_at).to be_present
    end

    it "RF-54: audita delivery.requested (kind progress) e progress.notice_sent com delivery_id e seq" do
      run_at(item)

      delivery = Delivery.where(ticket_id: ticket.id).sole
      expect(audits(ticket, "delivery.requested").sole.data)
        .to include("delivery_id" => delivery.delivery_id, "seq" => 2, "kind" => "progress", "first_pending_seq" => 1)
      sent = audits(ticket, "progress.notice_sent").sole
      expect(sent).to have_attributes(brand_id: infinitepay.id, actor_type: "system", trace_id: "c" * 32)
      expect(sent.data).to include("delivery_id" => delivery.delivery_id, "seq" => 2, "first_pending_seq" => 1,
                                   "outbox_event_id" => item.id)
    end

    it "RN-55, RF-33: é saída visível: sobe context_version em 1 e zera progress_due_at, sem encerrar o ciclo" do
      before = ticket.reload.context_version

      run_at(item)

      expect(ticket.reload).to have_attributes(context_version: before + 1, progress_due_at: nil, first_pending_seq: 1,
                                               first_pending_at: t0, ai_deadline_at: t0 + 60.seconds)
    end

    it "invariante 2: acorda o envio só depois do commit, sem HTTP no worker" do
      run_at(item)

      requested = OutboxEvent.find_by!(event_type: "delivery.requested", ticket_id: ticket.id)
      expect(OutboxJob).to have_been_enqueued.with(requested.id)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "repetição: o mesmo item duas vezes grava um único aviso" do
      first = run_at(item)
      second = run_at(item, t0 + 16.seconds)

      expect([ first.status, second.status ]).to eq(%i[sent already_done])
      expect(outbound(ticket).count).to eq(1)
      expect(Delivery.where(ticket_id: ticket.id).count).to eq(1)
      expect(audits(ticket, "progress.notice_sent").count).to eq(1)
    end

    it "RN-57: um novo item do mesmo ciclo colide na chave (um aviso por ciclo)" do
      run_at(item)

      expect(travel_to(t0 + 16.seconds) { Deadlines::ProgressDue.call(now: Time.current, limit: 100) }).to eq([])
    end

    it "RN-49: o aviso não conta como resposta: o turno seguinte ainda leva todas as pendentes do ciclo" do
      run_at(item)
      ingest_at(t0 + 16.seconds, "alguém aí?")

      turn = travel_to(t0 + 18.seconds) { open_turn_for(ticket.reload) }

      expect(turn.context.fetch("pending_messages").map { _1["seq"] }).to eq([ 1, 3 ])
    end

    it "RF-06: o envio sai pelo Deliveries::Send com o texto do aviso" do
      create(:provider_account, brand: infinitepay)
      stub_channels
      travel_to(t0 + 1.second) do # o destino (customer_ref) vem do webhook cru do chat
        Ingestion::Receive.call(normalized_message(identity: "acc_aviso_infinitepay"), provider_payload: { "customer_ref" => "cus_ref_1" })
      end
      run_at(item)
      requested = OutboxEvent.find_by!(event_type: "delivery.requested", ticket_id: ticket.id)

      expect(Deliveries::Send.call(requested.id).status).to eq(:delivered)
      expect(JSON.parse(channel_requests.sole.body)).to include("text" => pt_text)
    end
  end

  describe "marca (invariante 6)" do
    it "JIM: o aviso vai em inglês, com o brand_id da JIM em tudo" do
      ticket = ingest_at(t0, brand: "jim")
      item = due_notice(ticket)

      run_at(item)

      expect(outbound(ticket).sole).to have_attributes(brand_id: jim.id, body: en_text, provider_account: "jim-chat-mock")
      expect(Delivery.where(ticket_id: ticket.id).sole.brand_id).to eq(jim.id)
      expect(OutboxEvent.find_by!(event_type: "delivery.requested", ticket_id: ticket.id).brand_id).to eq(jim.id)
      expect(audits(ticket, "progress.notice_sent").sole.brand_id).to eq(jim.id)
    end

    it "marca errada: o banco recusa um item do aviso com a marca de outro atendimento" do
      ticket = ingest_at(t0)
      item = due_notice(ticket)

      expect { item.update_columns(brand_id: jim.id) }.to raise_error(ActiveRecord::InvalidForeignKey, /same_brand/)
    end
  end

  describe "revalidação sob o lock: o aviso não vale mais" do
    let!(:ticket) { ingest_at(t0) }
    let!(:item) { due_notice(ticket) }

    def expect_discarded(reason, progress_due_at: nil)
      result = run_at(item)

      expect(result.status).to eq(:discarded)
      expect(outbound(ticket).where(body: pt_text)).to be_empty
      expect(Delivery.where(ticket_id: ticket.id, kind: "progress")).to be_empty
      expect(item.reload).to have_attributes(completed_at: be_present, last_error: reason)
      expect(audits(ticket, "progress.notice_discarded").sole.data)
        .to include("reason" => reason, "source" => "worker", "first_pending_seq" => 1, "outbox_event_id" => item.id)
      expect(ticket.reload.progress_due_at&.iso8601(3)).to eq(progress_due_at&.iso8601(3))
    end

    it "resposta_aplicada: a resposta do ciclo chegou antes do aviso" do
      turn = travel_to(t0 + 2.seconds) { open_turn_for(ticket) }
      travel_to(t0 + 15.05.seconds) { AgentActions::Apply.call(agent_action_for(turn)) }

      expect_discarded("resposta_aplicada")
    end

    it "ciclo_encerrado: o ciclo acabou sem resposta aplicada" do
      ticket.update_columns(first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil,
                            progress_due_at: nil)

      expect_discarded("ciclo_encerrado")
    end

    it "ciclo_novo: outro ciclo começou; o prazo do ciclo novo fica" do
      ticket.update_columns(first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil,
                            progress_due_at: nil)
      ingest_at(t0 + 15.05.seconds, "outra dúvida")

      expect_discarded("ciclo_novo", progress_due_at: t0 + 30.05.seconds)
    end

    it "fora_da_ia: o caso foi para um humano" do
      ticket.update_columns(state: "aguardando_humano")

      expect_discarded("fora_da_ia")
    end

    it "fora_da_ia: a atribuição mudou depois do registro do aviso" do
      ticket.update_columns(assignment_version: 1)

      expect_discarded("fora_da_ia")
    end

    it "handoff_pedido: já há um pedido de handoff para a atribuição atual (interface, item 1)" do
      OutboxEvent.create!(brand_id: ticket.brand_id, ticket:, event_type: "handoff.requested", dedup_key: "handoff:#{ticket.id}:0",
                          trace_id: "d" * 32, next_attempt_at: Time.current,
                          payload: { ticket_id: ticket.id, reason: "prazo_do_turno", source: "scheduler", turn: 1,
                                     first_pending_seq: 1, assignment_version: 0 })

      expect_discarded("handoff_pedido")
    end

    describe "tempo no limite: o teto do ciclo (60 s) pelo relógio do banco" do
      it "relógio do banco no teto exato: prazo_vencido" do
        allow(DatabaseClock).to receive(:now).and_return(t0 + 60.seconds)

        expect_discarded("prazo_vencido")
      end

      it "um instante antes do teto: o aviso sai" do
        allow(DatabaseClock).to receive(:now).and_return(t0 + 60.seconds - 0.000001)

        expect(run_at(item).status).to eq(:sent)
      end
    end
  end

  describe "relógio do banco antes do prazo do aviso" do
    it "não grava o aviso e reagenda o item no progress_due_at" do
      ticket = ingest_at(t0)
      item = due_notice(ticket)
      allow(DatabaseClock).to receive(:now).and_return(t0 + 14.9.seconds)

      result = run_at(item)

      expect(result).to have_attributes(status: :not_due, next_attempt_at: t0 + 15.seconds)
      expect(item.reload).to have_attributes(completed_at: nil, next_attempt_at: t0 + 15.seconds)
      expect(outbound(ticket)).to be_empty
    end
  end

  describe "ADR-023: atendimento de eval" do
    it "o aviso é gravado no atendimento, mas não vai ao canal (delivery.cancelled eval)" do
      ProviderAccount.evaluation_for!(infinitepay, "chat")
      msg = normalized_message(identity: "eval_aviso").merge("provider_account" => "infinitepay-chat-eval")
      ticket = travel_to(t0) { Ingestion::Receive.call(msg, provider_payload: {}) }.ticket.reload
      expect(ticket.evaluation).to be(true)
      item = due_notice(ticket)
      stub_channels

      run_at(item)
      requested = OutboxEvent.find_by!(event_type: "delivery.requested", ticket_id: ticket.id)

      expect(Deliveries::Send.call(requested.id).status).to eq(:cancelled)
      expect(Delivery.where(ticket_id: ticket.id).sole).to have_attributes(kind: "progress", status: "cancelled")
      expect(audits(ticket, "delivery.cancelled").sole.data).to include("reason" => "eval")
      expect(channel_requests).to be_empty
    end
  end

  it "invariante 6: atendimento inexistente na marca do item é descartado (atendimento_inexistente), sem laço" do
    ticket = ingest_at(t0)
    item = OutboxEvent.create!(brand_id: jim.id, ticket_id: nil, event_type: Deadlines::ProgressDue::EVENT_TYPE,
                               dedup_key: "progress:#{ticket.id}:1", trace_id: "d" * 32, next_attempt_at: t0,
                               payload: { "ticket_id" => ticket.id, "first_pending_seq" => 1, "assignment_version" => 0 })

    expect(run_at(item)).to have_attributes(status: :discarded)
    expect(item.reload).to have_attributes(completed_at: be_present, last_error: "atendimento_inexistente")
    expect(Delivery.where(ticket_id: ticket.id)).to be_empty
  end

  it "item inexistente ou já concluído não faz nada" do
    expect(described_class.call(SecureRandom.uuid).status).to eq(:already_done)
  end
end
