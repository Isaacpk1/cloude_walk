# Capacidade dos analistas no painel da fila (bloco 13; RF-27, RN-30, RN-31): cada analista humano das equipes da
# marca, com status, vagas usadas e o aviso de "caso esperando e ninguém online". Sem `brand`, todas as marcas.
# Só leitura. Isolamento (invariante 6): o analista entra pela equipe da marca; os casos esperando contam por brand_id.
class AnalystCapacity
  Row = Data.define(:user_id, :name, :status, :active_count, :capacity, :brand_names) do
    def load_text = "#{active_count} / #{capacity}"
  end

  def initialize(brand: nil, brand_ids: nil)
    @brand = brand
    @brand_ids = brand_ids
  end

  def rows
    @rows ||= analysts.map do |user|
      brands = user.teams.map(&:brand).uniq.select { (!@brand || _1.id == @brand.id) && (!@brand_ids || @brand_ids.include?(_1.id)) }
      Row.new(user_id: user.id, name: user.name, status: user.status, active_count: user.active_count,
              capacity: user.capacity, brand_names: brands.map(&:name).sort)
    end
  end

  # Há caso esperando humano (RF-45) e nenhum analista online com vaga na marca: o supervisor precisa agir.
  def unattended?
    waiting = Ticket.where(state: HumanQueue::STATE)
    waiting = waiting.where(brand_id: @brand.id) if @brand
    waiting = waiting.where(brand_id: @brand_ids) if @brand_ids
    waiting.exists? && rows.none? { _1.status == "online" && _1.active_count < _1.capacity }
  end

  private

  def analysts
    scope = User.where(kind: "human", role: "analyst").includes(teams: :brand)
    scope = scope.where(id: TeamMembership.joins(:team).where(teams: { brand_id: @brand.id }).select(:user_id)) if @brand
    scope = scope.where(id: TeamMembership.joins(:team).where(teams: { brand_id: @brand_ids }).select(:user_id)) if @brand_ids
    scope.order(:name, :id).to_a
  end
end
