# Atendentes humanos pelo supervisor (bloco 12; RF-22).
class ConfigurationAnalystsController < ConfigurationBaseController
  def create
    result = Configuration::Analysts.create(brand:, team_id: params[:team_id], name: params[:name], email: params[:email],
                                            role: params[:role], password: params[:password], capacity: params[:capacity],
                                            created_by: current_user)
    respond_with(result, "Atendente cadastrado.")
  end
end
