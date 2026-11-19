class Team < ApplicationRecord
  belongs_to :brand
  has_many :team_memberships, dependent: :destroy
  has_many :users, through: :team_memberships
  has_many :queues, class_name: "HelpdeskQueue", dependent: :restrict_with_exception

  validates :name, presence: true
end
