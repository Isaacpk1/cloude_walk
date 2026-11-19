require "rails_helper"

RSpec.describe "RN-51: dados do cliente mascarados no log da ingestão" do
  it "não escreve conta, referência nem texto do cliente nos parâmetros" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    body = { "message_id" => "m1", "account_id" => "acc_1", "customer_ref" => "cus_1", "text" => "meu CPF é 000",
             "sent_at" => "2026-11-17T13:40:00Z", "context" => "mantém" }

    filtered = filter.filter(body)

    expect(filtered.values_at("account_id", "customer_ref", "text")).to all(eq("[FILTERED]"))
    expect(filtered.values_at("message_id", "context")).to eq(%w[m1 mantém])
  end
end
