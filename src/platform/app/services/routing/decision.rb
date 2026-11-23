# Decisão de roteamento (interface do bloco 11; RN-16, RN-20). Explica o caminho: qual regra e grupo casaram, em
# qual versão do conjunto, e as regras puladas por fila inativa ou fora da marca (RN-15).
#
# - queue: a fila escolhida (HelpdeskQueue) ou nil, se a marca não tem fila padrão ativa
# - queue_version: número da versão corrente da fila
# - ruleset_version: versão do conjunto aplicada; nil sem conjunto na marca
# - rule_index (0-based), rule_name, group_index e conditions (condições do grupo que casou): nil/[] na padrão
# - default: true quando nenhuma regra decidiu
# - skipped_rules: [{ "rule_index", "rule_name", "queue_id", "reason" }], reason em fila_inativa | fila_fora_da_marca
module Routing
  Decision = Data.define(:queue, :queue_version, :ruleset_version, :rule_index, :rule_name, :group_index, :conditions,
                         :default, :skipped_rules) do
    def queue_name = queue&.current_version&.name
  end
end
