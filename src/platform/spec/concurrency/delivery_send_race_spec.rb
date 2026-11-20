require "rails_helper"

# Envio ao provedor com o Postgres de verdade, fora da transação de teste (AGENTS.md, item 3;
# 07, seção 3.2; invariantes 2, 3 e 8).
RSpec.describe "Envio da saída ao provedor com workers concorrentes", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }

  describe "RNF-15, 07 seção 3.2: dois workers com o mesmo item delivery.requested" do
    it "só uma chamada HTTP é autorizada e a entrega é confirmada uma vez" do
      delivery = requested_delivery(customer_message.ticket)
      stub_channels
      item_id = delivery_item(delivery).id

      results = run_concurrently(threads: 4) { Deliveries::Send.call(item_id) }

      expect(results.map(&:status).tally).to include(delivered: 1)
      # Os outros encontram o item reservado (despertador no fim do lease) ou já encerrado.
      expect(results.map(&:status) - [ :delivered ]).to all(satisfy { %i[not_due in_flight skipped].include?(_1) })
      expect(channel_requests.size).to eq(1)
      expect(delivery.reload).to have_attributes(status: "delivered", attempts: 1)
      expect(AuditEvent.where(event_type: "delivery.delivered").count).to eq(1)
    end

    it "invariante 2: a chamada HTTP acontece sem transação aberta na conexão do worker" do
      delivery = requested_delivery(customer_message.ticket)
      stub_channels

      run_concurrently(threads: 2) { Deliveries::Send.call(delivery_item(delivery).id) }

      expect(transactions_during_http).to eq([ 0 ])
    end
  end

  describe "07, seção 3.2: duas saídas do mesmo atendimento em workers diferentes" do
    it "a segunda nunca é chamada antes da confirmação da primeira" do
      ticket = customer_message.ticket
      first = requested_delivery(ticket)
      second = requested_delivery(ticket, text: "Mais alguma dúvida?")
      stub_channels({ status: 200, message_id: "m1" }, { status: 200, message_id: "m2" })
      ids = [ delivery_item(first).id, delivery_item(second).id ]

      run_concurrently(threads: 2) { |i| Deliveries::Send.call(ids[i]) }
      Deliveries::Send.call(ids[1]) if second.reload.status == "pending"

      expect(channel_requests.map { JSON.parse(_1.body)["text"] }).to eq([ "Seu repasse cai hoje até as 18h.", "Mais alguma dúvida?" ])
      expect([ first.reload.status, second.reload.status ]).to eq(%w[delivered delivered])
    end
  end
end
