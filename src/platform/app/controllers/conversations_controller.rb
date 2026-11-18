class ConversationsController < PanelController
  def index
    @conversations = ConversationReader.all
  end

  def show
    @conversation = ConversationReader.find(params[:id])
  end
end
