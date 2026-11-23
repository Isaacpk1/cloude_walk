# Login do painel (bloco 14; ADR-024, RNF-26). Fora do PanelController: a tela de login não exige sessão.
class SessionsController < ApplicationController
  layout "application"

  def new; end

  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)
    # authenticate roda bcrypt também sem usuário, para o tempo não revelar se o e-mail existe.
    valid = (user || User.new).authenticate(params[:password].to_s)
    if user&.can_sign_in? && valid
      reset_session
      session[:user_id] = user.id
      session[:seen_at] = Time.current.to_i
      redirect_to root_path
    else
      flash.now[:alert] = "E-mail ou senha inválidos."
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    reset_session
    redirect_to login_path, status: :see_other
  end
end
