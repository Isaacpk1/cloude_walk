# Regras de roteamento pelo supervisor (bloco 12; RF-14, RF-15, RF-17, RF-18): o formulário inteiro vira uma versão nova
# do conjunto de regras da marca (ADR-013). Os campos do formulário chegam indexados (rules[0][groups][0]...).
class ConfigurationRulesController < ConfigurationBaseController
  def update
    result = Configuration::Rules.publish(brand:, rules: rules_param, default_queue_id: params[:default_queue_id], created_by: current_user)
    respond_with(result, ->(r) { "Regras publicadas: versão #{r.record.version}. Vale já para o próximo atendimento." })
  end

  private

  # Só as chaves conhecidas, em ordem de índice: o service ignora o resto.
  def rules_param
    ordered(params[:rules]).map do |rule|
      { "name" => rule["name"], "queue_id" => rule["queue_id"],
        "groups" => ordered(rule["groups"]).map do |group|
          { "conditions" => ordered(group["conditions"]).map { _1.slice("field", "op", "value") } }
        end }
    end
  end

  def ordered(node)
    hash = node.respond_to?(:to_unsafe_h) ? node.to_unsafe_h : node
    return [] unless hash.is_a?(Hash)

    hash.sort_by { |key, _| key.to_s.to_i }.map(&:last).select { _1.is_a?(Hash) }
  end
end
