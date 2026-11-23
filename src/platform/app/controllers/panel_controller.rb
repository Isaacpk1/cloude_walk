# Base das telas do painel (bloco 14; ADR-024, RF-59, RN-52): exige login e guarda o escopo de marcas do usuário.
class PanelController < ApplicationController
  SESSION_TTL = 8.hours

  before_action :require_login
  helper_method :current_user

  rescue_from ConversationReader::NotFound do
    render "panel/not_found", status: :not_found
  end

  private

  # Sessão com expiração por inatividade: cada uso renova o prazo. Usuário que virou bot ou saiu perde o acesso.
  def current_user
    return @current_user if defined?(@current_user)

    fresh = session[:seen_at] && Time.zone.at(session[:seen_at]) > SESSION_TTL.ago
    user = fresh && session[:user_id] ? User.find_by(id: session[:user_id]) : nil
    @current_user = user if user&.can_sign_in?
  end

  def require_login
    return touch_session if current_user

    reset_session
    redirect_to login_path
  end

  def touch_session = session[:seen_at] = Time.current.to_i

  # Marcas do escopo do usuário (invariante 6). Páginas e consultas partem daqui.
  def scope_brand_ids = @scope_brand_ids ||= current_user.brand_ids_in_scope

  # RN-53: DLQ, evals e (bloco 12) configuração são do supervisor. Para os outros perfis a página "não existe".
  def require_supervisor
    render "panel/not_found", status: :not_found unless current_user.supervisor?
  end

  # RN-52, RNF-24: conversas só das marcas do usuário; as de outra marca respondem como se não existissem. Os exemplos
  # sintéticos (sem marca no banco, DataSource::SYNTHETIC) são só do supervisor.
  def visible_conversations
    ConversationReader.all.select { conversation_visible?(_1, brand_slugs) }
  end

  def find_visible_conversation(id)
    conversation = ConversationReader.find(id)
    return conversation if conversation_visible?(conversation, brand_slugs)

    raise ConversationReader::NotFound, "conversa #{id} não encontrada"
  end

  def brand_slugs = @brand_slugs ||= Brand.where(id: scope_brand_ids).pluck(:slug)

  def conversation_visible?(conversation, slugs)
    slugs.include?(conversation.brand_slug) || (conversation.source == DataSource::SYNTHETIC && current_user.supervisor?)
  end
end
