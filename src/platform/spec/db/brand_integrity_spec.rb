require "rails_helper"

# Invariante 8: a regra crítica vive no banco, não só no Ruby.
# Cada teste grava por SQL (insert_all!/update_all), pulando as validações do model.
RSpec.describe "Invariante 8 / ADR-014: integridade de marca garantida pelo banco" do
  let(:infinitepay) { create(:brand, :infinitepay) }
  let(:jim) { create(:brand, :jim) }
  let(:now) { Time.current }

  describe "RN-01: identidade ligada a cliente de outra marca (marca errada)" do
    it "o banco recusa" do
      customer_jim = create(:customer, brand: jim)

      expect {
        CustomerIdentity.insert_all!([ { brand_id: infinitepay.id, customer_id: customer_jim.id, channel: "whatsapp",
                                         external_id: "+5500900000001", created_at: now, updated_at: now } ])
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "RF-58: fila ligada a equipe de outra marca (marca errada)" do
    it "o banco recusa" do
      team_jim = create(:team, brand: jim)

      expect {
        HelpdeskQueue.insert_all!([ { brand_id: infinitepay.id, team_id: team_jim.id, created_at: now, updated_at: now } ])
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "RN-20: a versão atual de uma fila é sempre uma versão dela" do
    it "o banco recusa apontar para a versão de outra fila" do
      author = create(:user)
      queue_a = create(:queue_record)
      queue_b = create(:queue_record)
      queue_a.publish_version!(name: "A", created_by: author)
      version_b = queue_b.publish_version!(name: "B", created_by: author)

      expect { HelpdeskQueue.where(id: queue_a.id).update_all(current_version_id: version_b.id) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "RN-20 / invariante 9: versão publicada é imutável no banco" do
    let(:version) { create(:queue_record).publish_version!(name: "Repasses", created_by: create(:user)) }

    it "recusa UPDATE por SQL" do
      expect { QueueVersion.where(id: version.id).update_all(name: "Editada") }
        .to raise_error(ActiveRecord::StatementInvalid, /imutável/)
    end

    it "recusa DELETE por SQL" do
      expect { QueueVersion.where(id: version.id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /imutável/)
    end
  end
end
