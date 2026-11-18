# Marca (InfinitePay, JIM). Tudo de negócio pertence a uma marca (RF-58, ADR-014).
class Brand < ApplicationRecord
  has_many :teams, dependent: :restrict_with_exception
  has_many :customers, dependent: :restrict_with_exception
  has_many :queues, class_name: "HelpdeskQueue", dependent: :restrict_with_exception

  validates :slug, :name, presence: true
  validates :slug, uniqueness: true
end
