class TimelinesController < PanelController
  def index
    @conversations = ConversationReader.all
  end

  def show
    @conversation = ConversationReader.find(params[:id])
    @timeline = ConversationReader.timeline(params[:id])
  end
end
