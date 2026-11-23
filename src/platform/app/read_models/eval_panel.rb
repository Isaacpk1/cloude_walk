# Leitura da aba de evals (ADR-023; ROADMAP, "O que o painel precisa conseguir mostrar" → Evals): cada cenário
# de Evals::Catalog com a última execução e um histórico curto, e o detalhe de uma execução.
# Marca (invariante 6): como o resto do painel, sem perfil ainda (bloco 08) mostra todas as marcas, com a marca
# em cada execução; com `brand_slug`, lista e detalhe ficam só nessa marca.
class EvalPanel
  NotFound = Class.new(StandardError)
  HISTORY = 5
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  Scenario = Data.define(:name, :title, :description, :runs) do
    def latest = runs.first
    def never_run? = runs.empty?
  end

  def initialize(brand_slug: nil)
    @brand = brand_slug.presence && (Brand.find_by(slug: brand_slug) || raise(NotFound, "marca #{brand_slug} não encontrada"))
  end

  def scenarios
    Evals::Catalog.scenarios.map do |item|
      runs = scope.where(scenario: item[:name]).order(started_at: :desc, created_at: :desc).limit(HISTORY)
      Scenario.new(name: item[:name], title: item[:title], description: item[:description], runs: runs.map { EvalView.from(_1) })
    end
  end

  def find(id)
    run = id.to_s.match?(UUID) && scope.find_by(id:)
    run ? EvalView.from(run) : raise(NotFound, "execução #{id} não encontrada")
  end

  def title_for(name) = Evals::Catalog.scenarios.find { _1[:name] == name }&.dig(:title)

  private

  def scope
    runs = EvalRun.includes(:brand)
    @brand ? runs.where(brand_id: @brand.id) : runs
  end
end
