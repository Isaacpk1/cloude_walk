require "rails_helper"

RSpec.describe ConversationView do
  let(:t0) { Time.utc(2026, 11, 16, 13, 0, 0) }

  def message(seq, author_type: "customer", at: t0 + seq, delivery_status: nil)
    ConversationView::Message.new(
      seq:, author_type:, author_name: "Autor #{seq}", body: "mensagem #{seq}",
      direction: author_type == "customer" ? "inbound" : "outbound", internal: false,
      occurred_at: at, trace_id: "trace-#{seq}", delivery_status:, delivery_id: nil
    )
  end

  def turn(number, covered_seqs:, status:)
    ConversationView::Turn.new(
      number:, status:, covered_seqs:, context_until_seq: covered_seqs.max,
      assignment_version: 1, event_id: "evt-#{number}", action: "reply", note: nil
    )
  end

  def build(messages:, turns: [], escalations: [])
    described_class.new(
      id: "exemplo", ticket_id: "sint-0001", brand_slug: "infinitepay", brand_name: "InfinitePay",
      customer_name: "Cliente sintético", channel: "whatsapp", state: "com_ia",
      title: "Repasse", assignee: ConversationView::Participant.new(name: "Agente de IA", kind: "bot"),
      assignment_version: 1, latest_customer_seq: 2, messages:, turns:, escalations:,
      source: DataSource::SYNTHETIC
    )
  end

  describe "RNF-13: mensagens na ordem do seq" do
    it "ordena as mensagens pelo seq, não pela ordem em que chegaram ao read model" do
      view = build(messages: [ message(3, author_type: "bot"), message(1), message(2) ])

      expect(view.messages.map(&:seq)).to eq([ 1, 2, 3 ])
    end

    it "ordena pelo seq mesmo quando o relógio do canal está fora de ordem" do
      view = build(messages: [ message(2, at: t0), message(1, at: t0 + 10) ])

      expect(view.messages.map(&:seq)).to eq([ 1, 2 ])
    end

    it "não permite que o consumidor da tela altere a lista" do
      view = build(messages: [ message(1) ])

      expect { view.messages << message(2) }.to raise_error(FrozenError)
    end
  end

  describe "RN-55: um turno pode cobrir mais de uma mensagem" do
    it "lista as mensagens que entraram em cada turno" do
      view = build(
        messages: [ message(1), message(2), message(3, author_type: "bot") ],
        turns: [ turn(2, covered_seqs: [ 1, 2 ], status: "applied"), turn(1, covered_seqs: [ 1 ], status: "superseded") ]
      )

      expect(view.turns.map(&:number)).to eq([ 1, 2 ])
      expect(view.messages_in(view.turns.last).map(&:seq)).to eq([ 1, 2 ])
      expect(view.messages_in(view.turns.first).map(&:seq)).to eq([ 1 ])
    end

    it "diz em quais turnos uma mensagem entrou" do
      view = build(
        messages: [ message(1), message(2) ],
        turns: [ turn(1, covered_seqs: [ 1 ], status: "superseded"), turn(2, covered_seqs: [ 1, 2 ], status: "applied") ]
      )

      expect(view.turns_covering(1).map(&:number)).to eq([ 1, 2 ])
      expect(view.turns_covering(2).map(&:number)).to eq([ 2 ])
    end
  end

  describe "RN-56: turno superado" do
    it "separa os turnos superados e diz que não cobrem a última mensagem do cliente" do
      superseded = turn(1, covered_seqs: [ 1 ], status: "superseded")
      applied = turn(2, covered_seqs: [ 1, 2 ], status: "applied")
      view = build(messages: [ message(1), message(2) ], turns: [ superseded, applied ])

      expect(view.superseded_turns).to eq([ superseded ])
      expect(superseded).to be_superseded
      expect(view.covers_latest_customer_seq?(superseded)).to be(false)
      expect(view.covers_latest_customer_seq?(applied)).to be(true)
    end

    it "recusa um status de turno fora do 07, seção 3.4" do
      expect { turn(1, covered_seqs: [ 1 ], status: "sent") }.to raise_error(ArgumentError, /status/)
    end
  end

  describe "ROADMAP 01: autor e entrega" do
    it "rotula os quatro tipos de autor do 07, seção 4" do
      labels = %w[customer bot analyst system].map { |type| message(1, author_type: type).author_label }

      expect(labels).to eq(%w[Cliente Bot Analista Sistema])
    end

    it "recusa um tipo de autor desconhecido" do
      expect { message(1, author_type: "robo") }.to raise_error(ArgumentError, /author_type/)
    end

    it "recusa um status de entrega fora do 07, seção 4" do
      expect { message(2, author_type: "bot", delivery_status: "lida") }.to raise_error(ArgumentError, /delivery_status/)
    end
  end
end
