# Triagem e roteamento do atendimento (ROADMAP 11; RF-10, RF-12, RF-24, RN-11 a RN-13, RN-28). `category`, `priority` e
# `tags` vêm das colunas do ticket (RF-10: o que vale agora); `matched` (as palavras que decidiram), `unclassified`
# (RN-13) e `classified_seq` vêm do último triage.classified. `routing` (ConversationView::Routing): o último
# routing.decided. `assignment` (Assignment): o último ticket.assigned da triagem. `skipped` (Skip): o último
# triage.skipped, só quando o caso nunca foi triado (os pulos depois da triagem ficam só na linha do tempo).
class ConversationView::Triage < Data.define(:category, :priority, :tags, :matched, :unclassified, :classified_seq,
                                             :classified_at, :routing, :assignment, :skipped, :trace_id)
  # A atribuição decidida pela triagem. `queue_name`: a fila do ticket.assigned, lida na marca do caso.
  Assignment = Data.define(:to, :reason, :queue_name, :state_from, :state_to, :assigned_at) do
    def label
      case reason
      when "ia_primeiro" then "IA primeiro: com a IA (RF-24)#{", fila #{queue_name}" if queue_name}"
      when "fila_sem_ia" then "fila sem IA: aguardando humano na fila #{queue_name || 'sem nome'}"
      when "categoria_somente_humana" then "categoria somente humana (RN-28): fila de escalas #{queue_name || 'sem nome'}"
      else "#{to == 'ia' ? 'com a IA' : 'na fila humana'} (#{reason})"
      end
    end
  end

  Skip = Data.define(:reason, :state, :skipped_at) do
    def label
      case reason
      when "handoff_pedido" then "triagem pulada: o cliente pediu um humano antes da triagem (RN-28, RN-34)"
      when "ja_triado" then "triagem pulada: o caso já tinha sido triado"
      when "fora_de_novo" then "triagem pulada: o caso já não estava em novo (estado #{state})"
      else "triagem pulada (#{reason})"
      end
    end
  end

  def initialize(tags: [], matched: [], **rest)
    super(tags: Array(tags).freeze, matched: Array(matched).freeze, **rest)
  end

  def category_label = ConversationView::Category.label(category)
  def priority_label = ConversationView::Priority.label(priority)
  def classified? = !classified_at.nil?

  def unclassified_label
    "não classificado (RN-13): #{category_label || 'outros'}, prioridade #{ConversationView::Priority.short_label(priority)}, " \
      "fila padrão"
  end
end
