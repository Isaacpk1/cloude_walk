require "rails_helper"

RSpec.describe User do
  describe "RF-23: o agente de IA é um usuário do tipo bot" do
    it "cria o bot pelos mesmos fluxos de um humano" do
      bot = create(:user, :bot)

      expect(bot).to be_bot
      expect(bot).not_to be_human
    end

    it "recusa um tipo desconhecido também no banco" do
      expect {
        User.insert_all!([ { name: "x", email: "x@example.test", kind: "robo", role: "agent",
                             status: "online", capacity: 1, created_at: Time.current, updated_at: Time.current } ])
      }.to raise_error(ActiveRecord::StatementInvalid, /check/i)
    end
  end

  describe "RF-22: atendentes associados a equipes" do
    it "liga um analista a equipes de mais de uma marca pela associação" do
      analyst = create(:user)
      ip = create(:team, brand: create(:brand, :infinitepay))
      jim = create(:team, brand: create(:brand, :jim))

      analyst.teams << [ ip, jim ]

      expect(analyst.brands).to contain_exactly(ip.brand, jim.brand)
    end

    it "não duplica a mesma equipe para o mesmo analista (repetição)" do
      analyst = create(:user)
      team = create(:team)
      TeamMembership.create!(user: analyst, team:)

      expect { TeamMembership.new(user: analyst, team:).save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "RN-30: capacidade padrão" do
    it "usa 5 atendimentos simultâneos quando não informada" do
      expect(User.new.capacity).to eq(5)
      expect(User.new.active_count).to eq(0)
    end
  end
end
