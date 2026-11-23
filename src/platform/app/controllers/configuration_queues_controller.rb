# Filas pelo supervisor (bloco 12; RF-13, RF-17, RF-18): criar, editar (versão nova), desativar, reativar e excluir.
class ConfigurationQueuesController < ConfigurationBaseController
  def create
    result = Configuration::Queues.create(brand:, team_id: params[:team_id], name: params[:name], ai_first: ai_first?,
                                          sla_policy: sla_policy, created_by: current_user)
    respond_with(result, "Fila criada.")
  end

  def update
    result = Configuration::Queues.update(brand:, queue_id: params[:id], name: params[:name], ai_first: ai_first?,
                                          sla_policy: sla_policy, created_by: current_user)
    respond_with(result, ->(r) { "Fila salva: versão #{r.record.current_version.version}." })
  end

  def activate = respond_with(Configuration::Queues.set_active(brand:, queue_id: params[:id], active: true, created_by: current_user), "Fila reativada.")

  def deactivate = respond_with(Configuration::Queues.set_active(brand:, queue_id: params[:id], active: false, created_by: current_user), "Fila desativada.")

  def destroy = respond_with(Configuration::Queues.destroy(brand:, queue_id: params[:id], created_by: current_user), "Fila excluída.")

  private

  def ai_first? = params[:ai_first] == "1"

  # SLA de assunção por prioridade, em segundos; vazio usa o padrão. Texto que não é número vai como está, para o
  # service recusar com o motivo.
  def sla_policy
    Handoff::Policy::PRIORITIES.each_with_object({}) do |priority, policy|
      value = params.dig(:sla, priority).to_s.strip
      policy[priority] = { "assume_s" => Integer(value, exception: false) || value } unless value.empty?
    end
  end
end
