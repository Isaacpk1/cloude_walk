require "rails_helper"

# RN-55 / RN-46 com o Postgres de verdade, fora da transação de teste (invariante 1; 07, seção 3.4).
RSpec.describe "Janela de agrupamento com mensagens concorrentes", :concurrency do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }

  def normalized(external_id:)
    {
      "schema" => "helpdesk.normalized_message.v1", "channel" => "chat", "brand" => "infinitepay",
      "provider_account" => "infinitepay-chat-mock", "external_id" => external_id,
      "sender" => { "channel_identity" => "acc_janela" }, "content" => { "type" => "text", "text" => "oi" },
      "received_at" => "2026-11-18T21:00:00.000Z", "trace_id" => SecureRandom.hex(16)
    }
  end

  describe "RN-55: mensagens simultâneas do mesmo cliente" do
    it "o ciclo começa na primeira gravada e o fim da janela fica consistente" do
      travel_to(t0) do
        results = run_concurrently(threads: 4) do |i|
          Ingestion::Receive.call(normalized(external_id: "chat_msg_#{i}"), provider_payload: {})
        end
        expect(results).to all(be_created)
      end

      ticket = Ticket.sole
      expect(ticket).to have_attributes(
        latest_customer_seq: 4, first_pending_seq: 1, first_pending_at: t0, dispatch_due_at: t0 + 1.5.seconds,
        ai_deadline_at: t0 + 60.seconds
      )
    end

    it "com o ciclo aberto, rajada concorrente aos 3 s mantém o início e respeita o teto de 4 s" do
      travel_to(t0) { Ingestion::Receive.call(normalized(external_id: "chat_msg_0"), provider_payload: {}) }

      travel_to(t0 + 3.seconds) do
        results = run_concurrently(threads: 3) do |i|
          Ingestion::Receive.call(normalized(external_id: "chat_msg_#{i + 1}"), provider_payload: {})
        end
        expect(results).to all(be_created)
      end

      expect(Ticket.sole).to have_attributes(
        latest_customer_seq: 4, first_pending_seq: 1, first_pending_at: t0, dispatch_due_at: t0 + 4.seconds
      )
    end
  end
end
