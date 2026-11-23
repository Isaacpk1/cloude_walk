require "rails_helper"

RSpec.describe RecordedConversations, "RN-55, RN-49, RF-56: a linha do tempo mostra a janela, o teto e o contexto do turno" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }
  let(:source) { described_class.new }

  around { |example| travel_to(t0) { example.run } }

  def events(ticket) = source.timeline(ticket.id.to_s).events
  def wait(ticket) = events(ticket).find { _1.kind == :intentional_wait }

  it "a espera intencional mostra a janela usada, que o teto não foi atingido e o context_version" do
    first = ingest("meu repasse não caiu")
    travel_to(t0 + 1.second)
    ingest("é o de ontem")
    travel_to(t0 + 2.5.seconds, with_usec: true)
    record_turn_06(first.ticket, context_version: 2)

    expect(wait(first.ticket)).to have_attributes(duration_ms: 2_500, turn: 1)
    expect(wait(first.ticket).detail).to include("janela de 1500 ms no chat", "teto não atingido", "context_version 2")
  end

  it "RN-55, tempo no limite: o teto de 4 s desde a primeira pendente encerra a espera" do
    first = ingest("meu repasse não caiu")
    travel_to(t0 + 1.second)
    ingest("é o de ontem")
    travel_to(t0 + 3.seconds)
    ingest("R$ 1.200")
    travel_to(t0 + 4.seconds)
    record_turn_06(first.ticket, context_version: 3)

    expect(wait(first.ticket)).to have_attributes(duration_ms: 4_000)
    expect(wait(first.ticket).detail).to include("teto de 4 s atingido")
  end

  it "ai_turn.opened mostra pendentes, histórico, tamanhos e o digest abreviado" do
    first = ingest("oi")
    turn1 = record_turn_06(first.ticket, context_version: 1)
    record_outbound(turn1, text: "Olá!")
    travel_to(t0 + 2.seconds)
    ingest("meu repasse")
    travel_to(t0 + 3.seconds)
    ingest("não caiu")
    turn2 = record_turn_06(first.ticket, context_version: 4)

    opened = events(first.ticket).select { _1.kind == :turn_opened }
    detail = opened.find { _1.turn == 2 }.detail

    expect(opened.map(&:turn)).to eq([ 1, 2 ])
    expect(detail).to include("pendentes seq 3, 4", "histórico seq 1, 2", "19 caracteres pendentes",
                              "25 no contexto", "context_version 4",
                              "digest #{turn2.context_digest.delete_prefix('sha256:').first(12)}")
    expect(opened.find { _1.turn == 2 }).to have_attributes(started_at: turn2.created_at, seq: 4)
  end

  it "RN-49: ai_turn.not_opened com contexto_excede_limite aparece com o motivo e os números" do
    received = ingest("x" * 20)
    travel_to(t0 + 1.5.seconds)
    audit = record_context_too_large(received.ticket, pending_chars: 16_800, limit: 16_000)

    event = events(received.ticket).find { _1.kind == :turn_not_opened }

    expect(event).to have_attributes(started_at: audit.occurred_at, trace_id: audit.trace_id, seq: 1, turn: nil)
    expect(event.detail).to include("contexto_excede_limite", "16800 caracteres pendentes", "limite de 16000",
                                    "seq 1", "handoff para humano pendente (bloco 10; RN-49)")
    expect(event.detail).not_to include("o caso vai para humano")
    expect(event.error).to be_nil
  end

  it "outros motivos de ai_turn.not_opened não poluem a linha do tempo" do
    received = ingest("oi")
    open_turn_for(received)
    Turns::Open.call(due_dispatch(received).id)

    expect(events(received.ticket).map(&:kind)).not_to include(:turn_not_opened)
  end

  it "marca errada: a linha do tempo não mostra turnos nem recusas de outra marca" do
    create(:brand, :jim)
    mine = ingest("oi")
    record_turn_06(mine.ticket)
    jim = ingest("mensagem da JIM", brand: "jim", identity: "acc_jim_000021")
    jim_audit = record_context_too_large(jim.ticket, pending_chars: 20_000)

    expect(events(mine.ticket).map(&:trace_id)).not_to include(jim_audit.trace_id)
    expect(events(mine.ticket).map(&:kind)).not_to include(:turn_not_opened)
  end
end
