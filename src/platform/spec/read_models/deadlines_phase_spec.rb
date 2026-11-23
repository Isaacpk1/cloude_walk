require "rails_helper"

# Prazos do atendimento na conversa (ROADMAP 08 Frontend; RN-46, RN-57, RF-36, RF-55): teto do ciclo, prazo do
# turno atual e o aviso de progresso do ciclo, lidos de tickets, ai_turns, deliveries e da auditoria no formato
# combinado dos blocos 08 e 09 (spec/support/handoff_records.rb).
RSpec.describe "RN-46, RN-57, RF-36: prazos do atendimento na conversa (DeadlinesPhase)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 21, 13, 40, 0) }
  let!(:ticket) { at(t0) { ingest("meu repasse não caiu").ticket.tap { record_progress_due(_1) } } }

  def at(time, &) = travel_to(time, with_usec: true, &)
  def view_at(time) = at(time) { DeadlinesPhase.new(ticket.reload).view }

  describe "RN-46: ciclo pendente com a IA" do
    it "mostra o teto do ciclo e quanto falta, sem turno aberto, e o aviso previsto aos 15 s" do
      view = view_at(t0 + 2.seconds)

      expect(view).to have_attributes(pending: true, first_pending_seq: 1, ai_deadline_at: t0 + 60.seconds,
                                      remaining_ms: 58_000, turn: nil, turn_deadline_at: nil)
      expect(view.remaining_text).to eq("faltam 58,0 s")
      expect(view.progress).to have_attributes(state: :scheduled, due_at: t0 + 15.seconds, overdue: false)
      expect(view.progress.state_label).to eq("Previsto")
    end

    it "com o turno aberto, mostra o prazo do turno (20 s desde a abertura) e quanto falta" do
      turn = at(t0 + 1.5.seconds) { record_turn_06(ticket) }
      view = view_at(t0 + 5.seconds)

      expect(view).to have_attributes(turn: turn.turn, turn_deadline_at: t0 + 21.5.seconds, turn_remaining_ms: 16_500)
      expect(view.turn_limited_by_cycle).to be(false)
    end

    it "turno aberto perto do teto: o prazo do turno é o teto do ciclo (ADR-020)" do
      at(t0 + 50.seconds) { record_turn_06(ticket) }.update_columns(deadline_at: t0 + 60.seconds)

      expect(view_at(t0 + 51.seconds).turn_limited_by_cycle).to be(true)
    end

    it "tempo no limite: no teto exato vence agora; um instante depois, vencido" do
      expect(view_at(t0 + 60.seconds)).to have_attributes(remaining_ms: 0, overdue: false)
      expect(view_at(t0 + 60.seconds).remaining_text).to eq("vence agora")

      late = view_at(t0 + 60.5.seconds)
      expect(late).to have_attributes(remaining_ms: -500, overdue: true)
      expect(late.remaining_text).to eq("vencido há 0,5 s")
    end

    it "aviso previsto que passou do horário sem registro do scheduler aparece como atrasado" do
      expect(view_at(t0 + 16.seconds).progress).to have_attributes(state: :scheduled, overdue: true)
    end
  end

  describe "RN-57: estado do aviso de progresso do ciclo" do
    it "registrado pelo scheduler: agendado com o atraso do registro" do
      at(t0 + 15.2.seconds) { record_progress_scheduled(ticket) }

      progress = view_at(t0 + 15.3.seconds).progress
      expect(progress).to have_attributes(state: :scheduled, scheduled_at: be_within(0.001).of(t0 + 15.2.seconds), delay_ms: 200)
    end

    it "enviado: mostra a entrega kind progress, o seq e o status dela" do
      at(t0 + 15.2.seconds) { record_progress_scheduled(ticket) }
      delivery = at(t0 + 15.3.seconds) { record_progress_sent(ticket) }

      progress = view_at(t0 + 16.seconds).progress
      expect(progress).to have_attributes(state: :sent, delivery_id: delivery.delivery_id, seq: 2,
                                          delivery_status: "pending", occurred_at: be_within(0.001).of(t0 + 15.3.seconds))
      expect(progress.state_label).to eq("Enviado")

      at(t0 + 15.5.seconds) { record_delivery_delivered(delivery) }
      expect(view_at(t0 + 16.seconds).progress.delivery_status).to eq("delivered")
    end

    it "cancelado pela resposta aplicada: o ciclo fecha e o bloco mostra o aviso do último ciclo com o motivo" do
      delivery = at(t0 + 15.3.seconds) { record_progress_sent(ticket) }
      at(t0 + 15.4.seconds) do
        record_delivery_cancelled(delivery, reason: "resposta_aplicada")
        close_cycle(ticket)
      end

      view = view_at(t0 + 16.seconds)
      expect(view).to have_attributes(pending: false, ai_deadline_at: nil)
      expect(view.progress).to have_attributes(state: :cancelled, reason: "resposta_aplicada", delivery_id: delivery.delivery_id)
      expect(view.progress.reason_label).to eq("a resposta da IA foi aplicada antes do envio do aviso (07, seção 3.4)")
    end

    it "descartado pelo worker: mostra o motivo" do
      at(t0 + 15.2.seconds) { record_progress_scheduled(ticket) }
      at(t0 + 15.3.seconds) { record_progress_discarded(ticket, reason: "ciclo_encerrado") }

      progress = view_at(t0 + 16.seconds).progress
      expect(progress).to have_attributes(state: :discarded, reason: "ciclo_encerrado", occurred_at: be_within(0.001).of(t0 + 15.3.seconds))
      expect(progress.state_label).to eq("Descartado")
    end

    it "repetição: um ciclo novo não herda o aviso do ciclo anterior" do
      delivery = at(t0 + 15.3.seconds) { record_progress_sent(ticket) }
      at(t0 + 20.seconds) do
        record_delivery_cancelled(delivery, reason: "resposta_aplicada")
        close_cycle(ticket)
      end
      at(t0 + 30.seconds) { ingest("outra dúvida").tap { record_progress_due(_1.ticket) } }

      progress = view_at(t0 + 31.seconds).progress
      expect(progress).to have_attributes(state: :scheduled, due_at: t0 + 45.seconds)
    end
  end

  describe "invariante 6: marca errada e fora da IA" do
    it "o aviso e o turno de um atendimento de outra marca não entram" do
      other = at(t0) { ingest("oi da JIM", brand: "jim", identity: "acc_jim_000021").ticket.tap { record_progress_due(_1) } }
      at(t0 + 15.3.seconds) { record_progress_sent(other) }
      at(t0 + 1.5.seconds) { record_turn_06(other) }

      view = view_at(t0 + 16.seconds)
      expect(view.progress.state).to eq(:scheduled)
      expect(view.turn).to be_nil
    end

    it "sem ciclo e sem aviso: sem bloco; caso com humano: sem bloco" do
      close_cycle(ticket)
      expect(view_at(t0 + 1.second)).to be_nil

      ticket.update_columns(state: "aguardando_humano")
      expect(view_at(t0 + 1.second)).to be_nil
    end
  end
end
