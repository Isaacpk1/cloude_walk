# Conta de um provedor de canal (07, seção 5.0; ADR-019). A URL /webhooks/:channel/:slug aponta
# para uma conta, e a conta define a marca, o escopo da deduplicação (RNF-15) e o segredo que
# autentica o webhook (RNF-23). O segredo fica criptografado no banco e filtrado do inspect.
class ProviderAccount < ApplicationRecord
  NotFound = Class.new(StandardError)
  CHANNELS = CustomerIdentity::CHANNELS

  belongs_to :brand

  encrypts :secret

  validates :channel, inclusion: { in: CHANNELS }
  validates :slug, presence: true, format: { with: /\A[a-z0-9][a-z0-9-]*\z/ }
  validates :secret, presence: true
  validates :phone_number_id, presence: true, if: -> { channel == "whatsapp" }

  scope :active, -> { where(active: true) }

  def self.find!(channel:, slug:)
    active.includes(:brand).find_by(channel: channel.to_s, slug: slug.to_s) ||
      raise(NotFound, "conta #{slug.inspect} não existe ou está inativa no canal #{channel.inspect}")
  end

  def brand_slug = brand.slug
end
