# Atendente humano ou o agente de IA como usuário do tipo bot (RF-22, RF-23, P4).
class User < ApplicationRecord
  KINDS = %w[human bot].freeze
  ROLES = %w[supervisor analyst agent].freeze
  STATUSES = %w[online pausa offline].freeze

  has_many :team_memberships, dependent: :destroy
  has_many :teams, through: :team_memberships
  has_many :brands, -> { distinct }, through: :teams

  validates :name, :email, presence: true
  validates :email, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
  validates :capacity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def bot? = kind == "bot"
  def human? = kind == "human"
end
