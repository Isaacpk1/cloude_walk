require "rails_helper"

# Bloco 12 (RF-22, RF-58, RN-53, RN-54, invariantes 6 e 7): equipes e atendentes cadastrados pelo supervisor.
RSpec.describe "RF-22, RF-58: equipes e atendentes" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:setup) { distribution_setup(infinitepay) }
  let!(:boss) { analyst_in(setup[:team], role: "supervisor") }

  describe Configuration::Teams do
    it "cria equipe na marca e audita" do
      result = described_class.create(brand: infinitepay, name: "Crédito", created_by: boss)

      expect(result.ok).to be(true)
      expect(result.record).to have_attributes(brand_id: infinitepay.id, name: "Crédito")
      expect(AuditEvent.where(event_type: "team.created").sole.data).to include("team_id" => result.record.id, "name" => "Crédito")
    end

    it "recusa nome em branco e repetido na marca, mas aceita o mesmo nome em outra marca" do
      described_class.create(brand: infinitepay, name: "Crédito", created_by: boss)

      expect(described_class.create(brand: infinitepay, name: " ", created_by: boss).errors).to include("o nome é obrigatório")
      expect(described_class.create(brand: infinitepay, name: "crédito", created_by: boss).errors).to include("já existe uma equipe com esse nome na marca")
      expect(described_class.create(brand: jim, name: "Crédito", created_by: boss).ok).to be(true)
    end
  end

  describe Configuration::Analysts do
    def create_analyst(**over)
      described_class.create(brand: infinitepay, team_id: setup[:team].id, name: "Bia", email: "Bia@IP.test", role: "analyst",
                             password: "senha-forte-123", capacity: 4, created_by: boss, **over)
    end

    it "cadastra o analista na equipe, com senha e capacidade, e audita sem a senha" do
      result = create_analyst

      expect(result.ok).to be(true)
      user = result.record
      expect(user).to have_attributes(email: "bia@ip.test", kind: "human", role: "analyst", status: "offline", capacity: 4)
      expect(user.authenticate("senha-forte-123")).to be_truthy
      expect(user.teams).to eq([ setup[:team] ])
      audit = AuditEvent.where(event_type: "analyst.created").sole
      expect(audit.data).to include("user_id" => user.id, "role" => "analyst", "team_id" => setup[:team].id)
      expect(audit.data.to_s).not_to include("senha-forte-123")
    end

    it "valida e-mail, senha curta, perfil e capacidade, com o motivo em texto" do
      expect(create_analyst(email: "sem-arroba").errors).to include("e-mail inválido")
      expect(create_analyst(password: "curta").errors).to include("a senha precisa de pelo menos 10 caracteres")
      expect(create_analyst(role: "agent").errors).to include("perfil inválido")
      expect(create_analyst(capacity: 0).errors).to include("a capacidade deve ser um inteiro entre 1 e 50")
    end

    it "e-mail repetido é recusado (único no sistema)" do
      create_analyst

      expect(create_analyst(name: "Outra").errors).to include("já existe um usuário com esse e-mail")
    end

    it "marca errada: equipe de outra marca é recusada e nada é criado" do
      other = distribution_setup(jim)[:team]

      result = create_analyst(team_id: other.id)

      expect(result.errors).to include("a equipe não existe nesta marca")
      expect(User.where(email: "bia@ip.test")).to be_empty
    end
  end
end
