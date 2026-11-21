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

  describe "formato e casos sem janela (pelo scheduler real)" do
    def tick_at(at)
      travel_to(at, with_usec: true)
      Deadlines::DispatchDue.call(now: Time.current, limit: 10).map { Turns::Open.call(_1) }
    end

    def waits(ticket) = source.timeline(ticket.id.to_s).events.select { _1.kind == :intentional_wait }

    it "RF-56: horários no mesmo fuso e formato do resto do painel, sem UTC misturado" do
      first = ingest("meu repasse não caiu")
      travel_to(start + 1.second)
      ingest("é o de ontem")
      travel_to(start + 3.seconds)
      ingest("R$ 1.200")
      tick_at(start + 4.seconds)

      detail = waits(first.ticket).sole.detail

      expect(detail).to include("às 18/11/2026 18:00:04.000", "teto de 4 s atingido às 18/11/2026 18:00:04.000")
      expect(detail).not_to include("UTC", "21:00:04")
    end

    it "RF-56: com uma mensagem só, escreve seq 1 (e não seq 1 a 1)" do
      received = ingest("oi")
      tick_at(start + 1.5.seconds)

      detail = waits(received.ticket).sole.detail

      expect(detail).to include("com a mensagem seq 1 ")
      expect(detail).not_to include("seq 1 a 1")
    end

    it "RN-55: depois do teto, o turno seguinte não teve janela: sem janela, teto já vencido, duração 0" do
      first = ingest("oi")
      [ 0.9, 1.8, 2.7, 3.6 ].each do |s|
        travel_to(start + s.seconds, with_usec: true)
        ingest("msg #{s}")
      end
      tick_at(start + 4.seconds)
      travel_to(start + 4.5.seconds, with_usec: true)
      ingest("alguém pode ver?")
      tick_at(start + 4.75.seconds)

      turn1, turn2 = waits(first.ticket).sort_by(&:turn)

      expect(turn1).to have_attributes(duration_ms: 4_000)
      expect(turn1.detail).to include("Fim da janela de agrupamento", "seq 1 a 5")
      expect(turn2).to have_attributes(turn: 2, started_at: start + 4.5.seconds, duration_ms: 0)
      expect(turn2.detail).to include("sem janela: teto de 4 s já vencido, saiu na volta seguinte do scheduler",
                                      "seq 1 a 6", "turno aberto 250 ms depois")
      expect(turn2.detail).not_to include("Fim da janela de agrupamento")
    end

    it "RN-55: e-mail tem janela 0: sem espera intencional, saiu na volta seguinte do scheduler" do
      received = ingest_on("email", "Assunto: repasse")
      tick_at(start + 0.25.seconds)

      wait = waits(received.ticket).sole

      expect(wait).to have_attributes(started_at: start, duration_ms: 0)
      expect(wait.detail).to include("janela 0 (e-mail)", "saiu na volta seguinte do scheduler", "turno aberto 250 ms depois")
      expect(wait.detail).not_to include("Fim da janela de agrupamento")
    end
  end
end
