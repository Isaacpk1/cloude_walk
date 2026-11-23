class ConversationsController < PanelController
  def index
    @conversations = visible_conversations
  end

  def show
    @conversation = find_visible_conversation(params[:id])
    # Bloco 14: só o analista responsável, com o caso em com_analista, vê as ações (a conferência de verdade é do Human::Action).
    @history = @conversation.source.synthetic? ? [] : CustomerHistory.for(@conversation.ticket_id, scope_brand_ids)
    @can_act = !@conversation.source.synthetic? && @conversation.state == "com_analista" &&
               Ticket.exists?(id: @conversation.ticket_id, brand_id: scope_brand_ids, assignee_id: current_user.id)
  end
end
