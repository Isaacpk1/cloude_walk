require "rails_helper"

RSpec.describe RecordedConversations, "RN-55, RF-56, ADR-016: a linha do tempo mostra a janela que abriu o turno" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }
  let(:source) { described_class.new }

  around { |example| travel_to(start) { example.run } }

  it "a espera intencional vai da primeira mensagem pendente ao fim da janela, antes da publicação do turno" do
    first = ingest("meu repasse não caiu", trace_id: "4bf92f3577b34da6a3ce929d0e0e4736")
    travel_to(start + 1.second)
    ingest("é o de ontem")
    start_cycle(first.ticket, dispatch_due_at: start + 2.5.seconds)
    travel_to(start + 2.5.seconds, with_usec: true)
    open_turn_for(first)

    events = source.timeline(first.ticket.id.to_s).events
    wait = events.find { _1.kind == :intentional_wait }

    expect(wait).to have_attributes(turn: 1, seq: 2, started_at: first.message.created_at, finished_at: start + 2.5.seconds,
                                    duration_ms: 2_500, source: DataSource::SYSTEM)
    expect(wait.detail).to include("Fim da janela de agrupamento", "turn.dispatch", "turno 1", "seq 1 a 2")
    expect(events.index(wait)).to be < events.index { _1.kind == :published }
  end

  it "RNF-03: o atraso do scheduler e do worker depois do fim da janela não conta como espera intencional" do
    received = ingest("oi")
    start_cycle(received.ticket, dispatch_due_at: start + 1.5.seconds)
    travel_to(start + 1.8.seconds, with_usec: true)
    open_turn_for(received)

    wait = source.timeline(received.ticket.id.to_s).events.find { _1.kind == :intentional_wait }

    expect(wait).to have_attributes(finished_at: start + 1.5.seconds, duration_ms: 1_500)
    expect(wait.detail).to include("turno aberto 300 ms depois")
  end

  it "sem turno aberto não há espera intencional" do
    received = ingest("oi")

    expect(source.timeline(received.ticket.id.to_s).events.map(&:kind)).not_to include(:intentional_wait)
  end
end
