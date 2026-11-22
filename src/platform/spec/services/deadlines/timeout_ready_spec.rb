require "rails_helper"

# Bloco 08, "pronto quando": "uma resposta recebida a partir de T é rejeitada mesmo antes do job de timeout, e
# uma queda do broker antes do primeiro envio encaminha o caso para a fila humana". Critério de aceite do RF-36
# (04), RN-46 (exemplo do 06), RNF-18 (fila humana até T + 2 s), 07 seção 6.
#
# Peças reais: ingestão, scheduler (as consultas do Deadlines::Loop, a cada 250 ms do relógio de teste), worker
# (OutboxJob, que roda logo cada job vencido), publicação (broker simulado), consumer (AgentActions::Apply) e
# handoff. O relógio do banco não anda com o travel_to: aqui ele segue o relógio de teste (DatabaseClock).
RSpec.describe "RF-36 / RNF-18: timeout e queda do broker levam o caso à fila humana" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:queue) { default_queue(infinitepay) }
  let(:t0) { Time.zone.parse("2026-11-18T21:00:00Z") }
  let(:tick) { Deadlines::Loop::DEFAULT_INTERVAL.seconds }

  before { allow(DatabaseClock).to receive(:now) { Time.current } }

  # Uma volta do scheduler (sem o rescue do laço, para o erro aparecer no teste).
  def scheduler_tick
    Deadlines::Loop::REGISTRATIONS.sum { _1.constantize.call(now: Time.current, limit: 100).size }
  end

  # O worker processa logo os jobs vencidos no relógio de teste. `only` simula um worker que perdeu os outros.
  def drain_jobs(only: nil)
    loop do
      due = enqueued_jobs.select { _1[:job] == OutboxJob && (_1[:at].nil? || _1[:at] <= Time.current.to_f) }
      due = due.select { only.include?(OutboxEvent.find_by(id: _1[:args].first)&.event_type) } if only
      break if due.empty?

      due.each do |job|
        enqueued_jobs.delete(job)
        OutboxJob.perform_now(*job[:args])
      end
    end
  end

  # Roda o scheduler a cada 250 ms de `from` até `to` (ou até o caso escalar) e devolve o instante da escalação.
  def run_until_escalated(ticket, from:, to:, only: nil)
    at = from
    while at <= to
      travel_to(at, with_usec: true) do
        scheduler_tick
        drain_jobs(only:)
      end
      return escalated_at(ticket) if escalated_at(ticket)

      at += tick
    end
    nil
  end

  # Instante (relógio de teste) em que o handoff concluiu: o item handoff.requested encerra na transação do efeito.
  def escalated_at(ticket)
    return unless AuditEvent.exists?(ticket_id: ticket.id, event_type: "ticket.escalated")

    handoff_items(ticket).sole.completed_at
  end

  def ingest_at(at, text = "meu repasse não caiu")
    travel_to(at, with_usec: true) do
      result = ingest(text)
      drain_jobs
      result.ticket
    end
  end

  def reply_at(at, turn)
    travel_to(at, with_usec: true) do
      AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)
    end
  end

  # Turno 1 aberto e publicado aos 1,5 s; o agente não responde (mock mudo).
  def silent_turn
    stub_broker({ status: 200 })
    ticket = ingest_at(t0)
    travel_to(t0 + 1.5.seconds, with_usec: true) do
      scheduler_tick
      drain_jobs
    end
    ticket.ai_turns.sole
  end

  describe "RN-46 / RNF-18: resposta a partir de T com o job de timeout atrasado (scheduler parado)" do
    it "no instante exato de T e um instante depois: rejected prazo_vencido, sem saída, com o turno ainda eligible" do
      turn = silent_turn
      deadline = turn.deadline_at
      expect(deadline).to eq(t0 + 21.5.seconds)

      at_t = reply_at(deadline, turn)
      after_t = reply_at(deadline + 0.001.seconds, turn)

      expect(at_t).to have_attributes(status: :rejected, reason: "prazo_vencido")
      expect(after_t).to have_attributes(status: :rejected, reason: "prazo_vencido")
      # Nenhum job de timeout rodou: a rejeição vem do prazo conferido sob o lock.
      expect(turn.reload.status).to eq("eligible")
      expect(OutboxEvent.where(event_type: "turn.timeout")).to be_empty
      expect(outbound_messages(turn.ticket)).to be_empty

      # O scheduler volta: o caso escala pelo prazo do turno, e uma ação ainda mais tardia continua rejeitada.
      escalated = run_until_escalated(turn.ticket, from: deadline + 3.seconds, to: deadline + 5.seconds)
      expect(escalated).to eq(deadline + 3.seconds)
      expect(handoff_items(turn.ticket).sole.payload).to include("reason" => "prazo_do_turno", "source" => "scheduler")
      expect(reply_at(deadline + 4.seconds, turn)).to have_attributes(status: :rejected, reason: "atribuicao_mudou")
      expect(AuditEvent.where(ticket_id: turn.ticket_id, event_type: "agent_action.applied")).to be_empty
    end

    it "1 ms antes de T a resposta ainda é aplicada e o timeout depois é descartado" do
      turn = silent_turn

      expect(reply_at(turn.deadline_at - 0.001.seconds, turn)).to have_attributes(status: :applied)
      expect(run_until_escalated(turn.ticket, from: turn.deadline_at, to: turn.deadline_at + 1.second)).to be_nil
      expect(turn.reload.status).to eq("applied")
      expect(handoff_items).to be_empty
    end
  end

  describe "RN-46 (exemplo do 06): mock mudo" do
    it "o turno vence aos 20 s e o caso entra na fila humana até 22 s depois da abertura do turno" do
      turn = silent_turn
      opened_at = t0 + 1.5.seconds

      escalated = run_until_escalated(turn.ticket, from: opened_at + tick, to: opened_at + 25.seconds)

      expect(escalated).to be_between(turn.deadline_at, opened_at + 22.seconds)
      expect(escalated - turn.deadline_at).to be <= 2.seconds # RNF-18: T + 2 s
      expect(turn.reload.status).to eq("expired")
      expect(turn.ticket.reload).to have_attributes(state: "aguardando_humano", queue_id: queue.id, assignment_version: 1)
      expect(AuditEvent.where(ticket_id: turn.ticket_id, event_type: "turn.timeout_scheduled").sole.data["delay_ms"])
        .to be <= 250
    end
  end

  describe "RF-36: broker indisponível antes do primeiro envio (RN-43: 503 ou conexão recusada em todas as tentativas)" do
    it "retentativas sem tempo no prazo: publicacao_falhou e fila humana até T + 2 s da falha definitiva" do
      stub_request(:post, BrokerHelpers::BROKER_URL).to_raise(Errno::ECONNREFUSED)
      allow(Outbox::Publish).to receive(:new).and_wrap_original { |m, id, **kw| m.call(id, **kw, jitter: -> { 0.0 }) }
      ticket = ingest_at(t0)

      escalated = run_until_escalated(ticket, from: t0 + 1.5.seconds, to: t0 + 70.seconds)

      turn = ticket.ai_turns.sole
      publication = OutboxEvent.find(turn.event_id)
      failed_at = publication.completed_at # T: a falha definitiva (a 5.ª tentativa, aos 16,5 s)
      expect(publication).to have_attributes(published_at: nil, attempts: 5)
      expect(failed_at).to eq(t0 + 16.5.seconds)
      expect(failed_at).to be < turn.deadline_at
      handoff = handoff_items(ticket).sole
      expect(handoff.payload).to include("reason" => "publicacao_falhou", "source" => "outbox")
      expect(handoff.created_at).to eq(failed_at)
      expect(escalated - failed_at).to be <= 2.seconds
      expect(ticket.reload.state).to eq("aguardando_humano")
      expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.escalated").count).to eq(1)
    end

    it "nenhum turno publicado (worker de publicação parado): o teto do ciclo escala até T + 2 s de ai_deadline_at" do
      stub_broker({ status: 503 })
      ticket = ingest_at(t0)
      ceiling = ticket.reload.ai_deadline_at
      expect(ceiling).to eq(t0 + 60.seconds)

      escalated = run_until_escalated(ticket, from: t0 + 1.5.seconds, to: t0 + 65.seconds,
                                              only: %w[cycle.timeout turn.timeout handoff.requested])

      expect(broker_requests).to be_empty
      expect(escalated).to be_between(ceiling, ceiling + 2.seconds)
      expect(handoff_items(ticket).sole.payload).to include("reason" => "teto_do_ciclo", "turn" => nil)
      expect(ticket.reload).to have_attributes(state: "aguardando_humano", ai_deadline_at: nil, dispatch_due_at: nil)
    end
  end
end
