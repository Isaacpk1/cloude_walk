require "rails_helper"

# Invariante 1: corridas da ingestão com o Postgres de verdade, fora da transação de teste.
RSpec.describe "Ingestão concorrente", :concurrency do
  let!(:brand) { create(:brand, :infinitepay) }

  def normalized(external_id:, text: "oi", identity: "acc_corrida")
    {
      "schema" => "helpdesk.normalized_message.v1", "channel" => "chat", "brand" => "infinitepay",
      "provider_account" => "infinitepay-chat-mock", "external_id" => external_id,
      "sender" => { "channel_identity" => identity }, "content" => { "type" => "text", "text" => text },
      "received_at" => "2026-11-18T21:00:00.000Z", "trace_id" => SecureRandom.hex(16)
    }
  end

  describe "RNF-15: o provedor entrega o mesmo webhook duas vezes ao mesmo tempo" do
    it "grava uma mensagem só e responde a outra como duplicada" do
      results = run_concurrently(threads: 4) do
        Ingestion::Receive.call(normalized(external_id: "chat_msg_dup"), provider_payload: {})
      end

      expect(results).to all(be_a(Ingestion::Receive::Result))
      expect(results.count(&:created?)).to eq(1)
      expect([ Message.count, Customer.count, Ticket.count, OutboxEvent.count ]).to eq([ 1, 1, 1, 1 ])
      expect(AuditEvent.where(event_type: "message.received").count).to eq(1)
    end
  end

  describe "RN-02 / RN-03: duas mensagens diferentes do mesmo cliente novo ao mesmo tempo" do
    it "um cliente, um atendimento e seq 1 e 2, sem buraco nem repetição" do
      results = run_concurrently(threads: 2) do |i|
        Ingestion::Receive.call(normalized(external_id: "chat_msg_#{i}", text: "mensagem #{i}"), provider_payload: {})
      end

      expect(results).to all(be_created)
      expect([ Customer.count, CustomerIdentity.count, Ticket.count ]).to eq([ 1, 1, 1 ])
      expect(Message.order(:seq).pluck(:seq)).to eq([ 1, 2 ])
      expect(Ticket.sole.latest_customer_seq).to eq(2)
      expect(AuditEvent.where(event_type: "ticket.created").count).to eq(1)
    end
  end

  describe "RN-03: cliente conhecido, sem atendimento aberto, com duas mensagens ao mesmo tempo" do
    it "o índice do atendimento aberto deixa só um ser criado" do
      customer = create(:customer, brand:)
      create(:customer_identity, customer:, channel: "chat", external_id: "acc_corrida")

      results = run_concurrently(threads: 3) do |i|
        Ingestion::Receive.call(normalized(external_id: "chat_msg_#{i}"), provider_payload: {})
      end

      expect(results).to all(be_created)
      expect(Ticket.count).to eq(1)
      expect(Message.order(:seq).pluck(:seq)).to eq([ 1, 2, 3 ])
    end
  end
end
