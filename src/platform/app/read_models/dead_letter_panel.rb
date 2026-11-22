# Leitura da DLQ para o supervisor (RF-37; RN-45, RN-48; 07, seção 4: dead_letters). Lista e detalhe.
# Marca (invariante 6): como o resto do painel, sem perfil ainda mostra todas as marcas, com a marca em cada
# linha, e também o que ficou sem correlação (brand_id nulo, ADR-014); com `brand_slug`, só aquela marca, e
# o registro de outra marca ou sem correlação é NotFound (404).
# Reprocessar (RF-37 é S) fica para o bloco seguinte: depende da regra da RN-48.
class DeadLetterPanel
  NotFound = Class.new(StandardError)
  LIMIT = 100

  def initialize(brand_slug: nil)
    @brand = brand_slug.presence && (Brand.find_by(slug: brand_slug) || raise(NotFound, "marca #{brand_slug} não encontrada"))
  end

  def all = scope.order(created_at: :desc, id: :desc).limit(LIMIT).map { DeadLetterView.from(_1) }

  def find(id)
    record = id.to_s.match?(/\A\d{1,18}\z/) && scope.find_by(id: id.to_i)
    record ? DeadLetterView.from(record) : raise(NotFound, "registro da DLQ #{id} não encontrado")
  end

  private

  def scope
    records = DeadLetter.includes(:brand)
    @brand ? records.where(brand_id: @brand.id) : records
  end
end
