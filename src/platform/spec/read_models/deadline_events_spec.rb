require "rails_helper"

# Linha do tempo do bloco 08 (ROADMAP 08 Frontend; RN-46, RN-57, RF-36, RF-56, RNF-18): registro do prazo pelo scheduler,
# turno expirado, pedido de handoff, escalado para humano e aviso de progresso, com duração, turno, seq, trace e causa.
RSpec.describe "RN-46, RN-57, RF-36, RF-56, RNF-18: prazos e handoff na linha do tempo (DeadlineEvents)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 21, 13, 40, 0) }
  let!(:ticket) { at(t0) { ingest("meu repasse não caiu").ticket.tap { record_progress_due(_1) } } }

  before { default_queue_for(infinitepay, name: "Suporte InfinitePay") }

  def at(time, &) = travel_to(time, with_usec: true, &)
  def events = DeadlineEvents.new(ticket.reload).events
  def of(kind) = events.select { _1.kind == kind }

  # Ciclo inteiro: turno aos 1,5 s, aviso aos 15 s, prazo do turno aos 21,5 s, handoff e fila humana.
  def timeout_of_turn
    turn = at(t0 + 1.5.seconds) { record_turn_06(ticket) }
    at(t0 + 15.2.seconds) { record_progress_scheduled(ticket) }
    at(t0 + 15.4.seconds) { record_progress_sent(ticket) }
    request = at(t0 + 21.7.seconds) do
      record_timeout_scheduled(ticket, scope: :turn, turn:)
      record_turn_expired(turn)
      record_handoff_requested(ticket, reason: "prazo_do_turno", source: "scheduler", turn:)
    end
    at(t0 + 22.seconds) { record_escalated(ticket, request) }
    [ turn, request ]
  end

  it "RN-46: registro do prazo do turno com o atraso do scheduler, ligado ao turno, ao seq e ao trace" do
    turn, = timeout_of_turn
    event = of(:timeout_scheduled).sole

    expect(event).to have_attributes(turn: 1, seq: 1, duration_ms: 200, started_at: turn.deadline_at)
    expect(event.detail).to include("Prazo do turno 1 vencido às 21/11/2026 10:40:21.500", "turn.timeout no outbox 200 ms depois")
    expect(event.cause).to have_attributes(origin: "scheduler", reason: "prazo_do_turno")
    expect(event.cause.origin_label).to eq("Scheduler: prazo vencido no Postgres (ADR-016)")
  end

  it "RN-46: turno expirado do prazo à expiração; pedido de handoff do pedido ao desfecho" do
    _, request = timeout_of_turn

    expect(of(:turn_expired).sole).to have_attributes(turn: 1, seq: 1, duration_ms: 200)
    handoff = of(:handoff_requested).sole
    expect(handoff).to have_attributes(turn: 1, trace_id: request.trace_id, duration_ms: 300)
    expect(handoff.detail).to include("Prazo do turno vencido (20 s desde a abertura, RN-46)", "gatilho Scheduler")
    expect(handoff.cause.outcome).to eq("Escalado para humano em 300 ms")
  end

  it "RNF-18: escalado para humano com a duração desde a primeira mensagem pendente e a fila" do
    timeout_of_turn
    event = of(:escalated).sole

    expect(event).to have_attributes(label: "Escalado para humano", seq: 1, turn: 1, duration_ms: 22_000, started_at: t0)
    expect(event.detail).to include("fila Suporte InfinitePay", "assignment_version 0 → 1",
                                    "22000 ms desde a primeira mensagem pendente (RNF-18)")
    expect(event.cause.outcome).to eq("Na fila humana: Suporte InfinitePay")
  end

  it "RN-57: aviso agendado (atraso do scheduler) e enviado (do registro à saída), com a seq da saída" do
    timeout_of_turn

    expect(of(:progress_scheduled).sole).to have_attributes(seq: 1, duration_ms: 200, started_at: t0 + 15.seconds)
    sent = of(:progress_sent).sole
    expect(sent).to have_attributes(seq: 2, turn: nil, duration_ms: 200)
    expect(sent.detail).to include("saída seq 2", "kind progress")
  end

  it "RN-57: aviso descartado com o motivo" do
    at(t0 + 15.2.seconds) { record_progress_scheduled(ticket) }
    at(t0 + 15.3.seconds) { record_progress_discarded(ticket, reason: "resposta_aplicada") }

    event = of(:progress_discarded).sole
    expect(event).to have_attributes(seq: 1, duration_ms: 100)
    expect(event.cause).to have_attributes(reason: "resposta_aplicada", outcome: "Nenhuma saída gravada")
    expect(event.detail).to include("a resposta da IA foi aplicada antes do envio do aviso")
  end

  it "RN-46: teto do ciclo sem turno e publicação falhou pelo outbox" do
    at(t0 + 60.1.seconds) do
      record_timeout_scheduled(ticket, scope: :cycle)
      record_handoff_requested(ticket, reason: "teto_do_ciclo", source: "scheduler")
    end

    expect(of(:timeout_scheduled).sole).to have_attributes(turn: nil, seq: 1, duration_ms: 100)
    expect(of(:timeout_scheduled).sole.detail).to include("Teto do ciclo (primeira pendente seq 1) vencido às 21/11/2026 10:41:00.000")
    expect(of(:handoff_requested).sole.cause.outcome).to eq("Aguardando o worker do outbox (Handoff::Escalate)")
  end

  it "handoff descartado: o pedido mostra o desfecho e o descarte tem o motivo" do
    request = at(t0 + 2.seconds) { record_handoff_requested(ticket, reason: "publicacao_falhou", source: "outbox") }
    at(t0 + 2.1.seconds) { record_handoff_discarded(ticket, request, reason: "atribuicao_mudou") }

    expect(of(:handoff_requested).sole.cause.outcome).to eq("Descartado: o atendimento mudou de responsável desde o pedido")
    discarded = of(:handoff_discarded).sole
    expect(discarded.detail).to eq("Pedido de handoff (Publicação do turno falhou de forma definitiva (RN-46)) descartado: " \
                                   "o atendimento mudou de responsável desde o pedido")
    expect(discarded.cause.origin_label).to eq("Worker: ação do outbox revalidada sob o lock")
  end

  it "RN-46: timeout do turno descartado pelo worker aparece com o turno e o motivo" do
    turn = at(t0 + 1.5.seconds) { record_turn_06(ticket) }
    at(t0 + 21.6.seconds) { record_timeout_scheduled(ticket, scope: :turn, turn:) }
    at(t0 + 21.7.seconds) { record_timeout_discarded(ticket, scope: :turn, turn:, reason: "turno_applied") }

    event = of(:timeout_discarded).sole
    expect(event).to have_attributes(turn: 1, seq: 1, duration_ms: 100)
    expect(event.detail).to eq("Prazo do turno 1 descartado: a resposta da IA já tinha sido aplicada")
    expect(event.cause).to have_attributes(origin: "worker", reason: "turno_applied", outcome: "Sem handoff: o caso continua como estava")
  end

  it "07, seção 6: teto de um ciclo anterior descartado com ciclo_mudou" do
    at(t0 + 60.1.seconds) { record_timeout_scheduled(ticket, scope: :cycle) }
    at(t0 + 60.2.seconds) { record_timeout_discarded(ticket, scope: :cycle, reason: "ciclo_mudou") }

    event = of(:timeout_discarded).sole
    expect(event).to have_attributes(turn: nil, seq: 1)
    expect(event.detail).to eq("Teto do ciclo (primeira pendente seq 1) descartado: outro ciclo começou depois do registro")
  end

  it "RN-57: todo motivo de descarte do aviso gravado pelo serviço tem rótulo" do
    %w[fora_da_ia resposta_aplicada ciclo_encerrado ciclo_novo handoff_pedido prazo_vencido].each do |reason|
      expect(ConversationView::ProgressNotice::REASONS).to have_key(reason)
    end
  end

  it "RN-57: descarte do aviso pelo scheduler mostra a origem scheduler" do
    at(t0 + 15.2.seconds) do
      audit(ticket.reload, "progress.notice_discarded", SecureRandom.hex(16),
            "reason" => "handoff_pedido", "source" => "scheduler", "first_pending_seq" => 1)
    end

    event = of(:progress_discarded).sole
    expect(event.cause).to have_attributes(origin: "scheduler", reason: "handoff_pedido")
    expect(event.detail).to eq("Aviso de progresso descartado: já havia um pedido de handoff para a atribuição atual")
  end

  it "invariante 6: os registros de um atendimento de outra marca não entram" do
    other = at(t0) { ingest("oi da JIM", brand: "jim", identity: "acc_jim_000021").ticket }
    at(t0 + 60.1.seconds) do
      record_timeout_scheduled(other, scope: :cycle)
      record_handoff_requested(other, reason: "teto_do_ciclo", source: "scheduler")
    end

    expect(events).to be_empty
  end
end
