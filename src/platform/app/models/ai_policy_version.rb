class AiPolicyVersion < ApplicationRecord
  belongs_to :brand
  belongs_to :created_by, class_name: "User", optional: true

  def self.current_for(brand) = where(brand_id: brand.id).order(version: :desc).first
  def readonly? = persisted?
end
