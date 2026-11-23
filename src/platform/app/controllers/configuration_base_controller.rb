# Base das telas de configuração (bloco 12; RN-53, RNF-24): só supervisor, e sempre dentro de uma marca do escopo dele.
# A marca vem de ?marca=<slug> ou do campo `marca` do formulário; sem ela, a primeira marca do escopo. Marca fora do
# escopo responde 404, como uma marca que não existe.
class ConfigurationBaseController < PanelController
  before_action :require_supervisor
  before_action :find_brand

  private

  attr_reader :brand

  def find_brand
    brands = Brand.where(id: scope_brand_ids).order(:name)
    @brand = params[:marca].present? ? brands.find_by(slug: params[:marca].to_s) : brands.first
    render "panel/not_found", status: :not_found unless @brand
  end

  # Resultado de um service: aviso de sucesso ou os erros em texto, e de volta para a tela da marca.
  def respond_with(result, success)
    if result.ok
      flash[:notice] = success.respond_to?(:call) ? success.call(result) : success
    else
      flash[:alert] = result.errors.join(" · ")
    end
    redirect_to configuration_path(marca: brand.slug), status: :see_other
  end
end
