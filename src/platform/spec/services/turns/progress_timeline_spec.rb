require "rails_helper"

# RN-57, RNF-05 ("pronto quando" do aviso no bloco 08): a linha do tempo com as peças reais. A ingestão grava as
# mensagens, o laço do scheduler (Deadlines::Loop#tick: DispatchDue e ProgressDue) registra as ações, o worker
# (OutboxJob) abre os turnos e grava o aviso, e o consumer aplica a resposta (AgentActions::Apply).
RSpec.describe "RN-57: aviso de progresso na linha do tempo do atendimento" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }
  let(:looper) { Deadlines::Loop.new(interval: 0.25, batch: 100, sleeper: ->(_) { }) }

  before { allow(DatabaseClock).to receive(:now) { Time.current } }

  def at(seconds, &) = travel_to(t0 + seconds, with_usec: true, &)
  def ingest_at(seconds, text = "mais uma coisa") = at(seconds) { ingest(text, identity: "acc_linha_do_tempo") }.ticket

  # Uma volta do scheduler e o worker processando o que ela registrou (sem publicar no broker).
  def tick_at(seconds)
    at(seconds) do
      looper.tick
      OutboxEvent.where(completed_at: nil, event_type: %w[turn.dispatch progress.notice]).order(:created_at).pluck(:id)
                 .each { OutboxJob.perform_now(_1) }
    end
  end

  def notices(ticket) = Delivery.where(ticket_id: ticket.id, kind: "progress").order(:seq)

  it "o cliente escreve a cada 2 s: um aviso aos 15 s desde a primeira pendente, não um por mensagem" do
    ticket = nil
    (0..20).step(0.5).each do |s|
      ticket = ingest_at(s, "mensagem #{s}") if (s % 2).zero?
      tick_at(s + 0.25)
    end

    notice = notices(ticket).sole
    expect(notice).to have_attributes(ai_first_pending_seq: 1, status: "pending", seq: 9)
    expect(notice.message.received_at).to eq(t0 + 15.25.seconds)
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "progress.notice_sent").count).to eq(1)
  end

  it "novo ciclo depois da resposta: outro aviso possível aos 15 s do novo ciclo" do
    ticket = ingest_at(0, "meu repasse não caiu")
    tick_at(1.5)
    turn = AiTurn.sole
    at(10) { AgentActions::Apply.call(agent_action_for(turn)) }
    tick_at(15)
    expect(notices(ticket)).to be_empty

    ingest_at(20, "outra dúvida")
    tick_at(34.9)
    expect(notices(ticket)).to be_empty
    tick_at(35)

    expect(notices(ticket).sole).to have_attributes(ai_first_pending_seq: 3, seq: 4)
  end
end
