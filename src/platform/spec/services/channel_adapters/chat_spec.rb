require "rails_helper"

RSpec.describe ChannelAdapters::Chat do
  let(:account) { create(:provider_account, brand: create(:brand, :infinitepay), slug: "infinitepay-chat-mock") }
  let(:webhook) do
    { "message_id" => "chat_msg_000123", "account_id" => "acc_infinitepay_000021", "customer_ref" => "cus_ref_000021",
      "text" => "Minha maquininha parou", "sent_at" => "2026-11-17T13:40:00.000Z" }
  end
  let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }
  let(:received_at) { Time.utc(2026, 11, 17, 13, 40, 0.12r) }

  describe "RF-01 / RF-05: webhook do chat vira a mensagem normalizada" do
    subject(:normalized) { described_class.normalize(webhook.to_json, account:, trace_id:, received_at:) }

    it "passa no contrato helpdesk.normalized_message.v1 (invariante 10)" do
      expect(HelpdeskContracts.errors(:normalized_message, normalized)).to be_empty
    end

    it "tira marca e conta da configuração da conta, não do corpo (07, seção 5.0)" do
      expect(normalized).to include("brand" => "infinitepay", "provider_account" => "infinitepay-chat-mock", "channel" => "chat")
    end

    it "RF-07: identifica o cliente pela conta do app" do
      expect(normalized.dig("sender", "channel_identity")).to eq("acc_infinitepay_000021")
    end

    it "usa o ID do provedor como external_id e guarda texto, horário e trace" do
      expect(normalized).to include(
        "external_id" => "chat_msg_000123", "content" => { "type" => "text", "text" => "Minha maquininha parou" },
        "received_at" => "2026-11-17T13:40:00.120Z", "trace_id" => trace_id
      )
    end
  end

  describe "RN-44: payload fora do contrato do chat" do
    it "é recusado com o campo que falta" do
      expect { described_class.normalize(webhook.except("customer_ref").to_json, account:, trace_id:, received_at:) }
        .to raise_error(HelpdeskContracts::InvalidPayload) { expect(_1.violations.map(&:pointer)).to eq([ "/customer_ref" ]) }
    end

    it "é recusado quando o corpo não é JSON" do
      expect { described_class.normalize("{", account:, trace_id:, received_at:) }
        .to raise_error(HelpdeskContracts::InvalidPayload)
    end
  end
end
