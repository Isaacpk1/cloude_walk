# Atendente humano ou o agente de IA como usuário do tipo bot (RF-22, RF-23, P4).
class User < ApplicationRecord
  KINDS = %w[human bot].freeze
  ROLES = %w[supervisor analyst agent].freeze
  STATUSES = %w[online pausa offline].freeze

  # Bloco 14 (ADR-024): senha com bcrypt; o bot não tem senha. Sem validação automática de presença.
  has_secure_password validations: false

  has_many :team_memberships, dependent: :destroy
  has_many :teams, through: :team_memberships
  has_many :brands, -> { distinct }, through: :teams

  validates :name, :email, presence: true
  validates :email, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
  validates :capacity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  validates :password, length: { minimum: 10 }, allow_nil: true

  # Quem pode entrar no painel: humano com senha cadastrada.
  def can_sign_in? = human? && password_digest.present?
  def supervisor? = role == "supervisor"
  # Marcas do escopo do usuário: as das equipes dele (RN-52).
  def brand_ids_in_scope = teams.distinct.pluck(:brand_id)

  def bot? = kind == "bot"
  def human? = kind == "human"
end
