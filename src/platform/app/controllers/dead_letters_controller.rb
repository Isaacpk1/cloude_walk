# DLQ do painel (RF-37): lê só pelo DeadLetterPanel. ?marca=<slug> restringe à marca (invariante 6).
class DeadLettersController < PanelController
  before_action :require_supervisor

  rescue_from DeadLetterPanel::NotFound do
    render "dead_letters/not_found", status: :not_found
  end

  def index
    @dead_letters = panel.all
  end

  def show
    @dead_letter = panel.find(params[:id])
  end

  private

  def panel = @panel ||= DeadLetterPanel.new(brand_slug: params[:marca], brand_ids: scope_brand_ids)
end
