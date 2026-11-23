# Tela de configuração do supervisor (bloco 12; RF-13 a RF-18, RF-22, RF-58): filas com versões, regras, equipes e
# atendentes de uma marca. Só leitura aqui; as alterações são dos controllers de Configuration* e dos services.
class ConfigurationController < ConfigurationBaseController
  def index
    @brands = Brand.where(id: scope_brand_ids).order(:name)
    @queues = HelpdeskQueue.where(brand_id: brand.id, archived_at: nil).includes(:team, :versions).order(:id)
    @teams = Team.where(brand_id: brand.id).order(:name)
    @analysts = User.where(kind: "human").joins(:team_memberships).where(team_memberships: { team_id: @teams.select(:id) })
                    .includes(team_memberships: :team).distinct.order(:name)
    @ruleset = RoutingRuleset.current_for(brand)
    @rule_rows = RuleForm.rows(@ruleset)
    @categories = Triage::Policy.for(brand).categories
  end
end
