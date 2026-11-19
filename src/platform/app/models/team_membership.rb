# Liga analistas a equipes; daqui sai o escopo de acesso (RN-52).
class TeamMembership < ApplicationRecord
  belongs_to :user
  belongs_to :team

  validates :team_id, uniqueness: { scope: :user_id }
end
