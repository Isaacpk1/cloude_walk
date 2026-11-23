# Conexão do ActionCable (bloco 14; ADR-024, RNF-24): só com a sessão do painel válida, a mesma regra do
# PanelController (humano com senha, dentro das 8 h). Os streams do Turbo são assinados e cada página só entrega os
# das marcas do usuário; aqui fica a barreira de quem não tem sessão.
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_user || reject_unauthorized_connection
    end

    private

    def find_user
      session = request.session
      seen_at = session[:seen_at]
      return unless session[:user_id] && seen_at && Time.zone.at(seen_at) > PanelController::SESSION_TTL.ago

      user = User.find_by(id: session[:user_id])
      user if user&.can_sign_in?
    end
  end
end
