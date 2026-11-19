RSpec.describe ChannelsMock::Providers::Chat do
  describe "RF-01 / ADR-018: webhook no formato do app" do
    it "monta um webhook que passa no contrato chat_webhook" do
      payload = described_class.webhook(account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021", text: "oi")

      expect(HelpdeskContracts.errors(:chat_webhook, payload)).to be_empty
      expect(payload).to include("account_id" => "acc_infinitepay_000021", "customer_ref" => "cus_ref_000021", "text" => "oi")
      expect(payload["message_id"]).to start_with("chat_msg_")
    end

    it "usa o message_id informado, para reenviar o mesmo ID externo" do
      payload = described_class.webhook(account_id: "a", customer_ref: "c", text: "oi", message_id: "chat_msg_fixo")

      expect(payload["message_id"]).to eq("chat_msg_fixo")
    end

    it "recusa texto vazio antes de enviar (RN-44)" do
      expect { described_class.webhook(account_id: "a", customer_ref: "c", text: "") }
        .to raise_error(HelpdeskContracts::InvalidPayload)
    end
  end
end
