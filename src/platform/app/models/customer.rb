# Cliente de uma única marca (RN-01). `verified` limita o que a IA consulta (RN-05).
class Customer < ApplicationRecord
  belongs_to :brand
  has_many :identities, class_name: "CustomerIdentity", dependent: :destroy

  validates :display_name, presence: true
end
