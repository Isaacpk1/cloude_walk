# Mensagem de um atendimento (07, seção 4). `seq` ordena mensagens e entregas.
class Message < ApplicationRecord
  AUTHOR_TYPES = %w[customer bot analyst system].freeze
  DIRECTIONS = %w[inbound outbound].freeze

  belongs_to :brand
  belongs_to :ticket, inverse_of: :messages
  has_one :delivery, dependent: :restrict_with_exception

  validates :author_type, inclusion: { in: AUTHOR_TYPES }
  validates :direction, inclusion: { in: DIRECTIONS }
end
