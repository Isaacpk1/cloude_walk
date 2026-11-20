require "rails_helper"

# Restrições de banco da entrega (07, seções 3.2 e 4; invariante 8; RNF-15).
RSpec.describe Delivery do
  let(:brand) { create(:brand, :infinitepay) }
  let(:customer) { create(:customer, brand:) }
  let(:ticket) { Ticket.create!(brand:, customer:, channel: "chat") }

  def message(seq)
    ticket.messages.create!(brand:, provider_account: "app-infinitepay", channel: "chat", direction: "outbound",
                            author_type: "bot", body: "Resposta #{seq}", seq:, trace_id: "a" * 32, received_at: Time.current)
  end

  def delivery(seq: 1, **attrs)
    msg = message(seq)
    described_class.create!(brand:, ticket:, message: msg, seq:, channel: "chat", provider_account: "app-infinitepay",
                            kind: "reply", trace_id: "a" * 32, **attrs)
  end

  it "RF-06: nasce pendente, com delivery_id gerado no banco e ligada ao atendimento e à mensagem" do
    created = delivery

    expect(created.reload).to have_attributes(status: "pending", attempts: 0)
    expect(created.delivery_id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    expect(ticket.deliveries).to eq([ created ])
    expect(created.message.delivery).to eq(created)
  end

  it "RNF-15: delivery_id é único" do
    first = delivery(seq: 1)

    expect { delivery(seq: 2, delivery_id: first.delivery_id) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "07, seção 3.2: uma saída por seq no atendimento" do
    delivery(seq: 1)

    expect {
      described_class.create!(brand:, ticket:, message: message(2), seq: 1, channel: "chat",
                              provider_account: "app-infinitepay", kind: "reply", trace_id: "a" * 32)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "ROADMAP 05: entregue sempre guarda a confirmação do provedor" do
    created = delivery

    savepoint = ->(&block) { ActiveRecord::Base.transaction(requires_new: true, &block) }
    expect { savepoint.call { created.update_columns(status: "delivered", delivered_at: Time.current) } }
      .to raise_error(ActiveRecord::StatementInvalid, /deliveries_delivered_confirmation_check/)
    expect { savepoint.call { created.update_columns(status: "delivered", provider_message_id: "chat_out_1") } }
      .to raise_error(ActiveRecord::StatementInvalid, /deliveries_delivered_at_check/)
  end

  it "ADR-014: a marca da entrega é a do atendimento" do
    other = create(:brand, :jim)

    expect {
      described_class.create!(brand: other, ticket:, message: message(1), seq: 1, channel: "chat",
                              provider_account: "app-infinitepay", kind: "reply", trace_id: "a" * 32)
    }.to raise_error(ActiveRecord::InvalidForeignKey, /fk_deliveries_ticket_same_brand/)
  end
end
