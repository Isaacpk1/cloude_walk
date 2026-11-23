# Disponibilidade do analista pelo painel (bloco 13; RF-27, RN-30, RN-31). Só chama Availability::Set, que trava,
# grava e audita. ?marca=<slug> exige que o analista seja de uma equipe da marca (invariante 6).
class AnalystAvailabilitiesController < PanelController
  def update
    user = find_analyst
    return render plain: "Analista não encontrado", status: :not_found unless user

    unless User::STATUSES.include?(params[:status].to_s)
      return render plain: "Disponibilidade inválida", status: :unprocessable_content
    end

    Availability::Set.call(user:, status: params[:status])
    redirect_to human_queue_path(marca: params[:marca].presence), status: :see_other
  end

  private

  def find_analyst
    scope = User.where(kind: "human", role: "analyst")
    if params[:marca].present?
      brand = Brand.find_by(slug: params[:marca])
      return unless brand

      scope = scope.where(id: TeamMembership.joins(:team).where(teams: { brand_id: brand.id }).select(:user_id))
    end
    scope.find_by(id: params[:id])
  end
end
