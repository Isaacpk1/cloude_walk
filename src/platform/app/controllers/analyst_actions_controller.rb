# Ações do analista sobre o atendimento (bloco 14; RF-46, RF-48, RF-49): responder, anotar e resolver. Só chama os
# services de Human::, que travam o atendimento, conferem marca e responsável e auditam. Atendimento fora do escopo de
# marcas do usuário é 404, igual a um inexistente (RN-52, RNF-24).
class AnalystActionsController < PanelController
  MESSAGES = {
    "texto_vazio" => "Escreva um texto antes de enviar.",
    "motivo_invalido" => "Escolha um motivo de resolução da lista.",
    "caso_fora_do_analista" => "O atendimento não está mais com você.",
    "nao_e_o_responsavel" => "Só o analista responsável pode agir neste atendimento."
  }.freeze

  def reply = act(Human::Reply, "Resposta enviada.", text: params[:text])
  def note = act(Human::Note, "Nota interna salva.", text: params[:text])
  def resolve = act(Human::Resolve, "Atendimento resolvido.", reason: params[:reason], text: params[:text])

  private

  def act(service, success, **args)
    ticket = Ticket.find_by(id: params[:conversation_id].to_s.match?(/\A\d{1,18}\z/) ? params[:conversation_id] : 0,
                            brand_id: scope_brand_ids)
    return render("panel/not_found", status: :not_found) unless ticket

    result = service.call(ticket_id: ticket.id, brand_id: ticket.brand_id, user: current_user, **args)
    if result.status == :rejected
      return render("panel/not_found", status: :not_found) if result.reason == "atendimento_inexistente"

      flash[:alert] = MESSAGES.fetch(result.reason, "Não foi possível concluir a ação.")
    else
      flash[:notice] = success
    end
    redirect_to conversation_path(ticket.id)
  end
end
