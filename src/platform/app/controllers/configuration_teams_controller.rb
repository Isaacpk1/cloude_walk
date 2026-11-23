# Equipes pelo supervisor (bloco 12; RF-58).
class ConfigurationTeamsController < ConfigurationBaseController
  def create = respond_with(Configuration::Teams.create(brand:, name: params[:name], created_by: current_user), "Equipe criada.")
end
