# Uma entrega em conciliação (07, seções 3.2 e 6; ROADMAP 09): o resultado do provedor ficou incerto depois
# de todas as tentativas, a entrega segue em `sending` e a ordem de saída do atendimento para até a
# conciliação. `waiting_seqs` são as saídas seguintes que aguardam.
class ConversationView::Reconciliation < Data.define(:delivery_id, :seq, :turn, :attempts, :last_error, :since, :waiting_seqs)
  def waiting? = waiting_seqs.any?
end
