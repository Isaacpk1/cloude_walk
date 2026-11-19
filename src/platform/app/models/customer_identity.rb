# Telefone, e-mail ou conta do app ligado a um cliente (RN-02).
# A unicidade por (brand_id, channel, external_id) é garantida pelo banco.
class CustomerIdentity < ApplicationRecord
  CHANNELS = %w[chat whatsapp email].freeze

  belongs_to :brand
  belongs_to :customer

  validates :channel, inclusion: { in: CHANNELS }
  validates :external_id, presence: true
  validate :same_brand_as_customer

  private

  def same_brand_as_customer
    return if customer.nil? || customer.brand_id == brand_id

    errors.add(:brand, "deve ser a mesma do cliente")
  end
end
