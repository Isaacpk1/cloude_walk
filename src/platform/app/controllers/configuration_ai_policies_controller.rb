class ConfigurationAiPoliciesController < ConfigurationBaseController
  def update
    result = Configuration::AiPolicies.publish(brand:, attributes: params.require(:policy).permit(*Configuration::AiPolicies::FIELDS).to_h,
                                               created_by: current_user)
    respond_with(result, "Nova versão dos tempos da IA publicada. Vale para ciclos novos.")
  end
end
