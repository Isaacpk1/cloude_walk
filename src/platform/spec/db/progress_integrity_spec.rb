require "rails_helper"

# Invariante 8 e RN-57: um aviso de progresso por ciclo também no banco, não só pela chave do outbox e pelo lock.
RSpec.describe "RN-57: um aviso de progresso por ciclo (restrição de banco)" do
  let(:infinitepay) { create(:brand, :infinitepay) }
  let(:customer) { create(:customer, brand: infinitepay) }
  let(:ticket) { Ticket.create!(brand: infinitepay, customer:, channel: "chat") }

  def notice(seq:, cycle:, kind: "progress", status: "pending")
    message = Message.create!(brand: infinitepay, ticket:, direction: "outbound", author_type: "bot", body: "aguarde",
                              seq:, channel: "chat", provider_account: "acc", trace_id: "a" * 32, received_at: Time.current)
    Delivery.create!(brand: infinitepay, ticket:, message:, seq:, channel: "chat", provider_account: "acc", kind:, status:,
                     ai_assignment_version: 0, ai_first_pending_seq: cycle, trace_id: "a" * 32)
  end

  it "recusa um segundo aviso do mesmo ciclo, mesmo com o primeiro cancelado" do
    notice(seq: 2, cycle: 1, status: "cancelled")

    expect { notice(seq: 3, cycle: 1) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "aceita o aviso de outro ciclo e saídas de outros tipos" do
    notice(seq: 2, cycle: 1)

    expect { notice(seq: 3, cycle: 4) }.not_to raise_error
    expect { notice(seq: 4, cycle: 1, kind: "reply") }.not_to raise_error
  end
end
