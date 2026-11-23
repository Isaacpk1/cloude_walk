require "rails_helper"

RSpec.describe Sla::Policy, "RN-21, RN-22: política de SLA da fila" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:team) { create(:team, brand:) }

  def version_with(policy)
    queue = create(:queue_record, team:, brand:)
    queue.publish_version!(name: "Fila", created_by: nil, sla_policy: policy)
  end

  it "RN-21: o padrão de assunção após escalação por prioridade (tabela do 06)" do
    policy = described_class.for(nil)

    expect(%w[critica alta media baixa].map { policy.assume_seconds(_1) }).to eq([ 300, 900, 3600, 14_400 ])
  end

  it "o padrão de primeira resposta e de resolução" do
    policy = described_class.for(nil)

    expect(policy.first_response_seconds("alta")).to eq(300)
    expect(policy.resolve_seconds("critica")).to eq(4 * 3600)
    expect(policy.resolve_seconds("baixa")).to eq(5 * 24 * 3600)
  end

  it "RN-13: prioridade nula ou desconhecida vale média" do
    policy = described_class.for(nil)

    expect(policy.assume_seconds(nil)).to eq(3600)
    expect(policy.assume_seconds("urgentissima")).to eq(3600)
  end

  it "a política da fila sobrescreve o padrão, campo a campo" do
    policy = described_class.for(version_with("alta" => { "assume_s" => 120 }))

    expect(policy.assume_seconds("alta")).to eq(120)
    expect(policy.first_response_seconds("alta")).to eq(300)
    expect(policy.assume_seconds("critica")).to eq(300)
  end

  it "valor inválido (zero, negativo, texto) cai no padrão" do
    policy = described_class.for(version_with("alta" => { "assume_s" => 0 }, "media" => { "assume_s" => "x" },
                                              "critica" => { "assume_s" => -5 }))

    expect([ policy.assume_seconds("alta"), policy.assume_seconds("media"), policy.assume_seconds("critica") ])
      .to eq([ 900, 3600, 300 ])
  end

  it "for_ticket lê a versão da fila do caso, na marca dele" do
    version = version_with("media" => { "assume_s" => 60 })
    ticket = ingest("oi", brand: "infinitepay", identity: "acc_p").ticket
    ticket.update_columns(queue_id: version.queue_id, queue_version: version.version)

    expect(described_class.for_ticket(ticket).assume_seconds("media")).to eq(60)
  end

  it "for_ticket sem fila usa o padrão" do
    ticket = ingest("oi", brand: "infinitepay", identity: "acc_q").ticket

    expect(described_class.for_ticket(ticket).assume_seconds("media")).to eq(3600)
  end
end
