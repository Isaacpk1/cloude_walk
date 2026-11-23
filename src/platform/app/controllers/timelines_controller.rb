class TimelinesController < PanelController
  def index
    @conversations = visible_conversations
  end

  def show
    @conversation = find_visible_conversation(params[:id])
    @timeline = ConversationReader.timeline(params[:id])
    # ROADMAP 03: o evento escolhido (1, 2, ...) mostra a origem do erro, quando houver.
    index = params[:evento].to_s
    @selected = @timeline&.events&.[](index.to_i - 1) if index.match?(/\A[1-9]\d{0,3}\z/)
  end
end
