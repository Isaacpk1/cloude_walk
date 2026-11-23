# Aba de evals (ADR-023): lê só pelo EvalPanel. ?marca=<slug> restringe à marca.
class EvalsController < PanelController
  before_action :require_supervisor

  rescue_from EvalPanel::NotFound do
    render "evals/not_found", status: :not_found
  end

  def index
    @scenarios = panel.scenarios
  end

  def show
    @run = panel.find(params[:id])
    @title = panel.title_for(@run.scenario)
  end

  private

  def panel = @panel ||= EvalPanel.new(brand_slug: params[:marca], brand_ids: scope_brand_ids)
end
