class ConversationsController < PanelController
  def index
    @conversations = visible_conversations
  end

  def show
    @conversation = find_visible_conversation(params[:id])
  end
end
