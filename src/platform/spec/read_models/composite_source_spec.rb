require "rails_helper"

RSpec.describe ConversationReader, "ROADMAP 02: registros reais antes dos exemplos" do
  after { described_class.source = nil }

  it "lista os atendimentos gravados e, depois, os exemplos sintéticos" do
    create(:brand, :infinitepay)
    ticket = Ingestion::Receive.call({
      "schema" => "helpdesk.normalized_message.v1", "channel" => "chat", "brand" => "infinitepay",
      "provider_account" => "infinitepay-chat-mock", "external_id" => "m1", "sender" => { "channel_identity" => "acc_1" },
      "content" => { "type" => "text", "text" => "oi" }, "received_at" => "2026-11-18T21:00:00Z", "trace_id" => "a" * 32
    }, provider_payload: {}).ticket

    ids = described_class.all.map(&:id)

    expect(ids.first).to eq(ticket.id.to_s)
    expect(ids).to include("exemplo-repasse")
    expect(described_class.find(ticket.id.to_s).source).to eq(DataSource::SYSTEM)
    expect(described_class.find("exemplo-repasse").source).to eq(DataSource::SYNTHETIC)
  end
end
