# Atendimento (RF-08, RF-10). Um aberto por cliente e canal (RN-03), garantido pelo banco.
class Ticket < ApplicationRecord
  STATES = %w[novo em_triagem com_ia aguardando_humano com_analista aguardando_cliente resolvido fechado].freeze
  CHANNELS = CustomerIdentity::CHANNELS

  belongs_to :brand
  belongs_to :customer
  belongs_to :queue, class_name: "HelpdeskQueue", optional: true
  belongs_to :assignee, class_name: "User", optional: true
  belongs_to :linked_ticket, class_name: "Ticket", optional: true
  has_many :messages, -> { order(:seq) }, dependent: :restrict_with_exception, inverse_of: :ticket
  has_many :ai_turns, -> { order(:turn) }, dependent: :restrict_with_exception, inverse_of: :ticket
  has_many :audit_events, -> { order(:occurred_at, :id) }, dependent: :restrict_with_exception, inverse_of: :ticket

  validates :channel, inclusion: { in: CHANNELS }
  validates :state, inclusion: { in: STATES }

  scope :open, -> { where.not(state: "fechado") }
end
