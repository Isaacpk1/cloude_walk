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
  validates :email_address, presence: true, if: -> { channel == "email" }

  scope :active, -> { where(active: true) }

  # Conta de eval da marca no canal (ADR-023, item 5): `<marca>-<canal>-eval`, inativa (nenhum webhook entra
  # por ela). O atendimento aberto por uma mensagem dela nasce marcado como eval (tickets.evaluation). Criada
  # pelo seed ou, se faltar, pelo próprio eval. Uma conta com o mesmo slug que não seja de eval da marca é erro.
  def self.evaluation_for!(brand, channel)
    slug = "#{brand.slug}-#{channel}-eval"
    account = find_by(slug:) || create_evaluation(brand, channel, slug)
    unless account.evaluation && account.brand_id == brand.id && account.channel == channel
      raise ArgumentError, "a conta #{slug} existe e não é a conta de eval da marca #{brand.slug} no canal #{channel}"
    end

    account
  end

  def self.create_evaluation(brand, channel, slug)
    transaction(requires_new: true) do
      create!(brand:, channel:, slug:, evaluation: true, active: false, secret: SecureRandom.hex(32),
              phone_number_id: ("eval-#{brand.slug}" if channel == "whatsapp"),
              email_address: ("eval@#{brand.slug}.example" if channel == "email"))
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(slug:)
  end
  private_class_method :create_evaluation

  def self.find!(channel:, slug:)
    active.includes(:brand).find_by(channel: channel.to_s, slug: slug.to_s) ||
      raise(NotFound, "conta #{slug.inspect} não existe ou está inativa no canal #{channel.inspect}")
  end

  def brand_slug = brand.slug
end
