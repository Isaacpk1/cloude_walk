require "rails_helper"

# Invariantes 6 e 8, RN-15: um atendimento nunca fica em fila de outra marca, garantido pelo banco (achado I1 da
# revisão de arquitetura do bloco 11). O Ruby da triagem já confere; o banco cobre todo outro caminho.
RSpec.describe "RN-15: fila do atendimento é da mesma marca (restrição de banco)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let!(:ours) { triage_setup(infinitepay) }
  let!(:theirs) { triage_setup(jim) }

  it "recusa gravar um caso da InfinitePay numa fila da JIM" do
    ticket = ingest("meu repasse não caiu").ticket

    expect { ticket.update_columns(queue_id: theirs[:default].id) }.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "aceita a fila da própria marca e caso sem fila" do
    ticket = ingest("meu repasse não caiu").ticket

    expect { ticket.update_columns(queue_id: ours[:default].id) }.not_to raise_error
    expect { ticket.update_columns(queue_id: nil) }.not_to raise_error
  end
end
