class ConfigurationBrandsController < PanelController
  before_action :require_supervisor

  def create
    result = Configuration::Brands.create(attributes: params.permit(:name, :slug, :locale, :timezone).to_h, created_by: current_user)
    if result.ok
      flash[:notice] = "Marca criada. Configure as contas dos provedores antes de conectar canais."
      redirect_to configuration_path(marca: result.record.slug), status: :see_other
    else
      flash[:alert] = result.errors.join(" · ")
      redirect_to configuration_path, status: :see_other
    end
  end
end
