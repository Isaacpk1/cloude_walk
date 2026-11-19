require "rails_helper"

RSpec.describe RecordedConversations, "ROADMAP 02: a tela lê a mensagem gravada" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:source) { described_class.new }

  def ingest(text, external_id: SecureRandom.uuid, trace_id: SecureRandom.hex(16))
    Ingestion::Receive.call({
      "schema" => "helpdesk.normalized_message.v1", "channel" => "chat", "brand" => "infinitepay",
      "provider_account" => "infinitepay-chat-mock", "external_id" => external_id,
      "sender" => { "channel_identity" => "acc_infinitepay_000021" }, "content" => { "type" => "text", "text" => text },
      "received_at" => Time.current.utc.iso8601(3), "trace_id" => trace_id
    }, provider_payload: {})
  end

  describe "#all e #find" do
    it "monta a conversa do atendimento gravado, marcada como registro do sistema" do
      ticket = ingest("meu repasse não caiu").ticket
      ingest("é o de ontem")

      conversation = source.find(ticket.id.to_s)

      expect(conversation).to have_attributes(
        id: ticket.id.to_s, brand_slug: "infinitepay", channel: "chat", state: "novo", latest_customer_seq: 2,
        source: DataSource::SYSTEM, turns: [], escalations: []
      )
      expect(conversation.messages.map { [ _1.seq, _1.author_type, _1.body ] })
        .to eq([ [ 1, "customer", "meu repasse não caiu" ], [ 2, "customer", "é o de ontem" ] ])
      expect(conversation.assignee).to have_attributes(kind: "queue")
      expect(source.all.map(&:id)).to eq([ ticket.id.to_s ])
    end

    it "não encontra o que não é um atendimento" do
      expect(source.find("exemplo-repasse")).to be_nil
      expect(source.find("999999")).to be_nil
    end
  end

  describe "#timeline" do
    it "liga recebimento e gravação à mensagem pelo seq e pelo trace_id" do
      ticket = ingest("meu repasse não caiu", trace_id: "4bf92f3577b34da6a3ce929d0e0e4736").ticket

      timeline = source.timeline(ticket.id.to_s)

      expect(timeline.events.map(&:kind)).to eq(%i[received persisted])
      expect(timeline.events).to all(have_attributes(seq: 1, trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
                                                     ticket_id: ticket.id.to_s, source: DataSource::SYSTEM))
      expect(timeline.events.map(&:duration_ms)).to all(be >= 0)
    end
  end

  describe "#timeline: publicação no broker (ROADMAP 03)" do
    let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }
    let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }

    around { |example| travel_to(start) { example.run } }

    def open_and_publish(*responses)
      received = ingest("meu repasse não caiu", trace_id:)
      event_id = Turns::Open.call(received_item(received).id).turn.event_id
      stub_broker(*responses)
      responses.size.times do
        Outbox::Publish.call(event_id, jitter: -> { 0.0 })
        travel 1.second
      end
      received.ticket
    end

    it "mostra a publicação do turno, da abertura à confirmação do Kafka, com tópico, partição e offset" do
      ticket = open_and_publish({ status: 200 })

      event = source.timeline(ticket.id.to_s).events.find { _1.kind == :published }

      # O fim é o horário da auditoria (relógio do banco, clock_timestamp()).
      confirmed_at = AuditEvent.find_by!(event_type: "agent_event.published").occurred_at
      expect(event).to have_attributes(turn: 1, seq: 1, trace_id:, ticket_id: ticket.id.to_s, error: nil,
                                       started_at: start, finished_at: confirmed_at, source: DataSource::SYSTEM)
      expect(event.detail).to include("helpdesk.agent.inbound.v1", "partição 7", "offset 42", "tentativa 1")
    end

    it "mostra cada tentativa que falhou com a origem do erro, e a publicação que deu certo depois" do
      ticket = open_and_publish({ status: 503 }, { status: 200 })

      events = source.timeline(ticket.id.to_s).events
      failed = events.find { _1.kind == :publish_failed }

      expect(failed.error).to have_attributes(origin: "kafka", http_status: 503, attempt: 1, retry: true)
      expect(failed.error.origin_label).to include("Kafka")
      expect(failed).to have_attributes(turn: 1, trace_id:)
      confirmed_at = AuditEvent.find_by!(event_type: "agent_event.published").occurred_at
      expect(events.find { _1.kind == :published }).to have_attributes(started_at: start, finished_at: confirmed_at)
      expect(events.find { _1.kind == :published }.detail).to include("tentativa 2")
    end

    it "publicação recusada pelo broker fica sem fim e com a origem (assinatura)" do
      ticket = open_and_publish({ status: 401 })

      events = source.timeline(ticket.id.to_s).events

      expect(events.find { _1.kind == :published }.finished_at).to be_nil
      expect(events.find { _1.kind == :publish_failed }.error)
        .to have_attributes(origin: "assinatura", http_status: 401, retry: false)
    end
  end
end
