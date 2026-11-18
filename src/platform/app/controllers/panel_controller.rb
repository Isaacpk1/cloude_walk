# Base das telas do painel. Lê só pelo ConversationReader, nunca direto da fonte de dados.
class PanelController < ApplicationController
  rescue_from ConversationReader::NotFound do
    render "panel/not_found", status: :not_found
  end
end
