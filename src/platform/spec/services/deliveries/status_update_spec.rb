require "rails_helper"

RSpec.describe Deliveries::StatusUpdate, "RNF-15, RN-47: callback de status que chega antes da confirmação gravada" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let(:ticket) { customer_message(external_id: "chat_msg_000123").ticket }
  let(:jitter) { -> { 0.0 } }

  def callback(status) = { "message_id" => "chat_out_x1", "status" => status, "timestamp" => Time.current.utc.iso8601(3) }

  # O channels-mock enfileira o callback antes de responder 200: ele pode chegar enquanto a plataforma
  # ainda não gravou provider_message_id (transação 2 do Deliveries::Send).
  def send_with_early_callback(delivery, status)
    early = nil
    payload = callback(status)
    stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT).to_return do
      early = described_class.call(account:, payload:)
      { status: 200, body: { message_id: "chat_out_x1", status: "accepted" }.to_json, headers: { "Content-Type" => "application/json" } }
    end
    Deliveries::Send.call(delivery_item(delivery).id, jitter:)
    [ early, payload ]
  end

  %w[delivered failed].each do |status|
    it "#{status} antes da transação 2: unknown sem gravar nada; repetido depois do Send, tem efeito" do
      delivery = requested_delivery(ticket)

      early, payload = send_with_early_callback(delivery, status)

      expect(early.status).to eq(:unknown)
      expect(ProcessedEvent.where(consumer: described_class::CONSUMER)).to be_empty
      expect(delivery.reload.status).to eq("delivered")

      expect(described_class.call(account:, payload:).status).to eq(:accepted)
      expect(AuditEvent.where(event_type: "delivery.status_received").sole.data).to include("status" => status)
      expect(delivery.reload.status).to eq(status == "failed" ? "failed" : "delivered")
    end
  end
end
