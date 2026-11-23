# Vaga de atendimento do analista (RN-30, RN-31; 07, seção 3.5). Duas operações atômicas, cada uma um UPDATE
# condicional: a restrição `users_capacity_check` é a última barreira, então nem uma corrida entre workers nem
# um erro de código passam da capacidade (invariante 8). Quem chama já travou o atendimento (ordem dos locks:
# atendimento, depois usuário), na mesma transação do efeito, e não faz nenhuma chamada externa.
module Distribution
  module Slot
    module_function

    # Ocupa uma vaga de analista humano online abaixo da capacidade e marca quando ele recebeu o caso (desempate
    # da RN-30). Devolve true se ocupou, false se a vaga já não existia (outro worker ocupou, ficou offline).
    def claim!(user_id:, now: Time.current)
      sql = User.sanitize_sql_array([ <<~SQL.squish, now, user_id ])
        UPDATE users SET active_count = active_count + 1, last_assigned_at = ?
        WHERE id = ? AND kind = 'human' AND role = 'analyst' AND status = 'online' AND active_count < capacity
      SQL
      User.connection.exec_update(sql, "Slot Claim") == 1
    end

    # Libera uma vaga ocupada, sem nunca ficar abaixo de zero. Devolve false se não havia vaga a liberar.
    def release!(user_id:)
      sql = User.sanitize_sql_array([ <<~SQL.squish, user_id ])
        UPDATE users SET active_count = active_count - 1 WHERE id = ? AND active_count > 0
      SQL
      User.connection.exec_update(sql, "Slot Release") == 1
    end
  end
end
