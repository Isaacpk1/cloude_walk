# Atendimento (RF-08, RF-10). Um aberto por cliente e canal (RN-03), garantido pelo banco.
class Ticket < ApplicationRecord
  STATES = %w[novo em_triagem com_ia aguardando_humano com_analista aguardando_cliente resolvido fechado].freeze
  CHANNELS = CustomerIdentity::CHANNELS
  # 07, seção 3.3: mensagens nesses estados não vão para a IA.
  HUMAN_STATES = %w[aguardando_humano com_analista resolvido fechado].freeze

  belongs_to :brand
  belongs_to :customer
  belongs_to :queue, class_name: "HelpdeskQueue", optional: true
  belongs_to :assignee, class_name: "User", optional: true
  belongs_to :linked_ticket, class_name: "Ticket", optional: true
  has_many :messages, -> { order(:seq) }, dependent: :restrict_with_exception, inverse_of: :ticket
  has_many :ai_turns, -> { order(:turn) }, dependent: :restrict_with_exception, inverse_of: :ticket
  has_many :deliveries, -> { order(:seq) }, dependent: :restrict_with_exception, inverse_of: :ticket
  has_many :audit_events, -> { order(:occurred_at, :id) }, dependent: :restrict_with_exception, inverse_of: :ticket

  validates :channel, inclusion: { in: CHANNELS }
  validates :state, inclusion: { in: STATES }

  scope :open, -> { where.not(state: "fechado") }

  # O caso está com a IA: fora dos estados humanos e sem responsável ou com o bot. A atribuição ao bot
  # entra com a triagem (bloco 11): até lá, todo caso que não está com um humano vai para a IA.
  def with_ai?
    return false if HUMAN_STATES.include?(state)

    assignee.nil? || assignee.kind == "bot"
  end
end
