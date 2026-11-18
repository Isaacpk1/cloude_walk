require "rails_helper"

RSpec.describe TimelineView do
  let(:t0) { Time.utc(2026, 11, 16, 13, 0, 0) }

  def event(kind, from_ms, to_ms, seq: 1, turn: nil)
    TimelineView::Event.new(
      kind:, started_at: t0 + (from_ms / 1000.0), finished_at: to_ms && t0 + (to_ms / 1000.0),
      ticket_id: "sint-0001", seq:, turn:, trace_id: "abc", detail: nil, source: DataSource::SYNTHETIC
    )
  end

  def build(events)
    described_class.new(conversation_id: "exemplo", ticket_id: "sint-0001", events:, source: DataSource::SYNTHETIC)
  end

  describe "RNF-03: duração calculada a partir dos tempos" do
    it "calcula a duração de cada evento em milissegundos" do
      expect(event(:agent_run, 1_650, 3_650).duration_ms).to eq(2_000)
    end

    it "não arredonda para segundos inteiros" do
      expect(event(:persisted, 5, 38).duration_ms).to eq(33)
    end

    it "não inventa duração para um evento sem fim registrado" do
      expect(event(:published, 1_540, nil).duration_ms).to be_nil
    end

    it "recusa um evento que termina antes de começar" do
      expect { event(:delivered, 3_900, 3_720) }.to raise_error(ArgumentError, /finished_at/)
    end

    it "recusa um tipo de evento desconhecido" do
      expect { event(:teleporte, 0, 1) }.to raise_error(ArgumentError, /kind/)
    end
  end

  describe "RF-56: linha do tempo" do
    let(:view) do
      build([
        event(:delivered, 3_720, 3_900, seq: 2),
        event(:received, 0, 45),
        event(:intentional_wait, 38, 1_538, turn: 1),
        event(:agent_run, 1_650, 3_650, turn: 1)
      ])
    end

    it "ordena os eventos pelo início" do
      expect(view.events.map(&:kind)).to eq(%i[received intentional_wait agent_run delivered])
    end

    it "calcula a duração total do primeiro início ao último fim" do
      expect(view.total_duration_ms).to eq(3_900)
    end

    it "mede a espera intencional à parte (RNF-03)" do
      expect(view.duration_ms_of(:intentional_wait)).to eq(1_500)
      expect(view.duration_ms_of(:agent_run)).to eq(2_000)
    end

    it "dá o deslocamento de cada evento em relação ao primeiro" do
      expect(view.offset_ms(view.events.last)).to eq(3_720)
    end

    it "agrupa eventos por turno" do
      expect(view.events_for_turn(1).map(&:kind)).to eq(%i[intentional_wait agent_run])
    end
  end
end
