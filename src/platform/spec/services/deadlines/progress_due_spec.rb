require "rails_helper"

# RN-57 (07, seção 3.4, "Regras de tempo" e "Registro dos prazos"; ADR-016): aos 15 s desde a primeira mensagem
# pendente, o scheduler registra sob o lock uma ação de aviso por ciclo no outbox, com chave única.
RSpec.describe Deadlines::ProgressDue, "RN-57: aviso de progresso registrado pelo scheduler" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }

  # O relógio do banco não anda com o travel_to: nos testes, ele acompanha o relógio de teste.
  before { allow(DatabaseClock).to receive(:now) { Time.current } }

  def ingest_at(time, text = "meu repasse não caiu", brand: "infinitepay", identity: "acc_aviso_#{brand}", trace_id: SecureRandom.hex(16))
    travel_to(time, with_usec: true) { ingest(text, brand:, identity:, trace_id:) }.ticket.reload
  end

  def emit_at(time, **)
    travel_to(time, with_usec: true) { described_class.call(now: Time.current, limit: 100, **) }
  end

  def progress_items = OutboxEvent.where(event_type: "progress.notice").order(:created_at)

  describe "RN-57: prazo vencido" do
    it "registra um progress.notice com a chave do ciclo, o payload, o trace e a marca do atendimento" do
      ticket = ingest_at(t0, trace_id: "a" * 32)

      ids = emit_at(t0 + 15.seconds)

      item = progress_items.sole
      expect(ids).to eq([ item.id ])
      expect(item).to have_attributes(brand_id: infinitepay.id, ticket_id: ticket.id, trace_id: "a" * 32,
                                      dedup_key: "progress:#{ticket.id}:1", next_attempt_at: t0 + 15.seconds,
                                      completed_at: nil, attempts: 0)
      expect(item.payload).to eq("ticket_id" => ticket.id, "first_pending_seq" => 1, "assignment_version" => 0,
                                 "progress_due_at" => (t0 + 15.seconds).iso8601(3))
    end

    it "RF-54: audita progress.notice_scheduled com o atraso, sem limpar progress_due_at" do
      ticket = ingest_at(t0, trace_id: "b" * 32)

      ids = emit_at(t0 + 15.3.seconds)

      audit = AuditEvent.where(event_type: "progress.notice_scheduled").sole
      expect(audit).to have_attributes(brand_id: infinitepay.id, ticket_id: ticket.id, actor_type: "system", trace_id: "b" * 32)
      expect(audit.data).to include("outbox_event_id" => ids.sole, "dedup_key" => "progress:#{ticket.id}:1",
                                    "first_pending_seq" => 1, "progress_due_at" => (t0 + 15.seconds).iso8601(3),
                                    "deadline_at" => (t0 + 15.seconds).utc.iso8601(3), "delay_ms" => 300)
      expect(ticket.reload.progress_due_at).to eq(t0 + 15.seconds)
    end

    it "acorda o worker pelo ID do item, depois do commit" do
      ingest_at(t0)

      ids = emit_at(t0 + 15.seconds)

      expect(OutboxJob).to have_been_enqueued.with(ids.sole).on_queue("timers")
    end

    it "falha de dependência: Redis fora não desfaz o item (a recuperação reoferece)" do
      ingest_at(t0)
      allow(OutboxJob).to receive(:perform_later).and_raise(StandardError, "redis fora")

      expect(emit_at(t0 + 15.seconds).size).to eq(1)
      expect(progress_items.count).to eq(1)
    end
  end

  describe "tempo no limite" do
    it "15 s exatos já registram" do
      ingest_at(t0)

      expect(emit_at(t0 + 15.seconds).size).to eq(1)
    end

    it "um instante antes dos 15 s não registra" do
      ingest_at(t0)
      clear_enqueued_jobs

      expect(emit_at(t0 + 15.seconds - 0.000001)).to eq([])
      expect(progress_items).to be_empty
      expect(OutboxJob).not_to have_been_enqueued
    end

    it "pelo relógio do banco: vencido no relógio do scheduler e não no do banco não registra" do
      ingest_at(t0)
      allow(DatabaseClock).to receive(:now).and_return(t0 + 14.999.seconds)

      expect(emit_at(t0 + 15.seconds)).to eq([])
      expect(progress_items).to be_empty
    end
  end

  describe "RN-57: um aviso por ciclo (repetição)" do
    it "várias voltas emitem uma vez só" do
      ingest_at(t0)

      first = emit_at(t0 + 15.seconds)
      later = [ emit_at(t0 + 15.25.seconds), emit_at(t0 + 16.seconds) ]

      expect(first.size).to eq(1)
      expect(later).to eq([ [], [] ])
      expect(progress_items.count).to eq(1)
    end

    it "mensagens novas no mesmo ciclo não geram outra chave" do
      ingest_at(t0)
      emit_at(t0 + 15.seconds)
      ingest_at(t0 + 15.5.seconds, "e aí?")

      expect(emit_at(t0 + 16.seconds)).to eq([])
    end

    it "ciclo novo: outra chave aos 15 s da sua primeira mensagem" do
      ticket = ingest_at(t0)
      emit_at(t0 + 15.seconds)
      ticket.update_columns(first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil,
                            progress_due_at: nil)
      ingest_at(t0 + 30.seconds, "outra dúvida")

      expect(emit_at(t0 + 44.seconds)).to eq([])
      expect(emit_at(t0 + 45.seconds).size).to eq(1)
      expect(progress_items.pluck(:dedup_key)).to eq([ "progress:#{ticket.id}:1", "progress:#{ticket.id}:2" ])
    end
  end

  describe "revalidação sob o lock" do
    it "caso fora da IA: não registra, zera progress_due_at e audita o descarte" do
      ticket = ingest_at(t0)
      ticket.update_columns(state: "com_analista", assignee_id: create(:user).id)

      expect(emit_at(t0 + 15.seconds)).to eq([])
      expect(progress_items).to be_empty
      expect(ticket.reload.progress_due_at).to be_nil
      expect(AuditEvent.where(event_type: "progress.notice_discarded").sole.data)
        .to include("reason" => "fora_da_ia", "source" => "scheduler", "first_pending_seq" => 1)
    end

    it "resposta já aplicada que cobre o ciclo: não registra (resposta_aplicada)" do
      ticket = ingest_at(t0)
      travel_to(t0 + 2.seconds) { open_turn_for(ticket) }.update_columns(status: "applied", applied_event_id: SecureRandom.uuid)

      expect(emit_at(t0 + 15.seconds)).to eq([])
      expect(ticket.reload.progress_due_at).to be_nil
      expect(AuditEvent.where(event_type: "progress.notice_discarded").sole.data).to include("reason" => "resposta_aplicada")
    end

    it "atendimento sem ciclo não aparece" do
      ticket = ingest_at(t0)
      ticket.update_columns(first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil,
                            progress_due_at: nil)

      expect(emit_at(t0 + 15.seconds)).to eq([])
    end
  end

  describe "marca (invariante 6)" do
    it "cada atendimento recebe a ação na própria marca; o escopo por marca só vê a sua" do
      ip = ingest_at(t0)
      jm = ingest_at(t0, brand: "jim")

      expect(emit_at(t0 + 15.seconds, brand_id: jim.id).size).to eq(1)
      expect(progress_items.sole).to have_attributes(brand_id: jim.id, ticket_id: jm.id)
      emit_at(t0 + 15.seconds)
      expect(progress_items.pluck(:brand_id, :ticket_id)).to contain_exactly([ jim.id, jm.id ], [ infinitepay.id, ip.id ])
    end
  end
end
