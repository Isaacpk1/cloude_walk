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
end
