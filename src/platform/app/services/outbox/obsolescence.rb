# Quando um item aberto do outbox ficou obsoleto (07, seção 6: "broker volta com backlog", "DLQ de turno
# superado ou timeout de ciclo anterior"; RF-34 + RF-35; RN-38). Um item obsoleto não pode reativar a IA:
# a recuperação o encerra sem nova ação (Outbox::Recover) e a publicação o descarta (Outbox::Publish).
#
#   Outbox::Obsolescence.reason(item, ticket, now:) # => "turno_superseded", ... ou nil (ainda vale)
#
# Lê o atendimento como está; quem decide encerrar deve ter a linha travada (Outbox::Recover).
#
# Por tipo:
# - "agent.event": o turno do evento (event_id = id do item) deixou de ser elegível (turno_superseded,
#   turno_expired, turno_applied), venceu o prazo (prazo_vencido), a atribuição mudou (atribuicao_mudou)
#   ou o caso saiu da IA (fora_da_ia).
# - "turn.dispatch": o caso saiu da IA, a atribuição mudou, ou chegou mensagem nova depois da ação
#   (mensagem_nova: a ingestão regravou a janela e o scheduler emite outra chave) ou a ação é de um ciclo já
#   respondido (ciclo_anterior). Janela aberta e turno já coberto ficam para o Turns::Open, que audita.
# - "delivery.requested" e "message.received": nunca obsoletos aqui. A entrega tem a ordem por seq e a
#   conciliação (Deliveries::Send decide e acorda a próxima); o aviso da ingestão vale para a triagem.
# - "handoff.requested", "turn.timeout", "cycle.timeout" e "progress.notice" (blocos 08 e 09): nunca obsoletos
#   aqui. O worker revalida sob o lock e audita o descarte com o motivo do domínio.
# - Outros tipos: obsoletos se o caso saiu da IA, se o payload traz `assignment_version` diferente da atual ou
#   `first_pending_seq` diferente do ciclo pendente atual (ciclo_anterior).
module Outbox
  module Obsolescence
    AGENT_EVENT = "agent.event".freeze
    DISPATCH = "turn.dispatch".freeze
    # Os tipos revalidados pelo próprio worker sob o lock (blocos 08 e 09) também: o worker decide e audita o descarte
    # com o motivo do domínio (handoff.discarded, *.timeout_discarded, progress.notice_discarded).
    NEVER = %w[delivery.requested message.received handoff.requested turn.timeout cycle.timeout progress.notice].freeze

    module_function

    def reason(item, ticket, now:)
      return if ticket.nil? || NEVER.include?(item.event_type)

      case item.event_type
      when AGENT_EVENT then agent_event_reason(item, ticket, now:)
      when DISPATCH then dispatch_reason(item.payload, ticket)
      else generic_reason(item.payload, ticket)
      end
    end

    # Também usado pelo Outbox::Publish antes de chamar o broker.
    def turn_reason(turn, ticket, now:)
      return "turno_#{turn.status}" unless turn.eligible?
      return "prazo_vencido" if now >= turn.deadline_at
      return "atribuicao_mudou" if ticket.nil? || ticket.assignment_version != turn.assignment_version

      "fora_da_ia" unless ticket.with_ai?
    end

    def agent_event_reason(item, ticket, now:)
      turn = AiTurn.find_by(event_id: item.id, brand_id: item.brand_id)
      turn ? turn_reason(turn, ticket, now:) : generic_reason(item.payload, ticket)
    end

    def dispatch_reason(payload, ticket)
      common = generic_reason(payload, ticket)
      return common if common

      cover = payload["cover_until_seq"].to_i
      return if cover >= ticket.latest_customer_seq.to_i

      ticket.first_pending_seq.nil? || cover < ticket.first_pending_seq ? "ciclo_anterior" : "mensagem_nova"
    end

    def generic_reason(payload, ticket)
      return "fora_da_ia" unless ticket.with_ai?

      version = payload["assignment_version"]
      return "atribuicao_mudou" if !version.nil? && version != ticket.assignment_version

      cycle = payload["first_pending_seq"]
      "ciclo_anterior" if !cycle.nil? && cycle != ticket.first_pending_seq
    end
  end
end
