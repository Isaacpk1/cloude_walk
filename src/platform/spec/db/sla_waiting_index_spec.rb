require "rails_helper"

# ADR-029: o índice que tira as consultas de SLA do scheduler da leitura da tabela inteira (migration 20261124064000).
RSpec.describe "RNF-10: índice dos casos aguardando humano sem analista" do
  let(:index) { ActiveRecord::Base.connection.indexes(:tickets).find { _1.name == "index_tickets_sla_waiting" } }

  it "existe, na ordem do vencimento do SLA" do
    expect(index).to be_present
    expect(index.columns).to eq(%w[sla_due_at id])
  end

  it "cobre só os casos da fila humana, sem analista e com o SLA ainda não estourado" do
    expect(index.where).to include("aguardando_humano").and include("assignee_id IS NULL").and include("sla_breached = false")
  end
end
