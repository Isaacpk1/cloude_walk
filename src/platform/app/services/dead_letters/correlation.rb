# Correlação de uma mensagem da DLQ com um turno (RN-45; 07, seção 6, "Payload fora do contrato": "A escalação
# exige correlação confiável com um turno ainda válido").
#
#   DeadLetters::Correlation.call(view) # => Found(brand_id:, ticket_id:, turn_id:, turn:) ou Missing(reason:)
#
# `view` é a vista do contrato dead_letter, já validada. Só lê; quem chama trava o atendimento e revalida.
#
# Que corpo cada origem manda (cabeçalhos dlq_source e dlq_reason):
# - evento de turno (`helpdesk.agent_event.v1`): broker (qualquer motivo) e agent-mock com `contrato`. A chave é o
#   `event_id` do corpo, que é o `ai_turns.event_id`; o cabeçalho `event_id`, se vier, tem de ser igual.
# - ação do agente (`helpdesk.agent_action.v1`): agent-mock com `acao_invalida` e plataforma com `contrato`. A
#   chave é o `in_reply_to`.
# - plataforma com `marca_divergente` ou `turno_inexistente`: nunca correlaciona (07, seção 5.3: a DLQ não escala
#   esses eventos, porque não há atendimento verificado).
#
# O corpo pode estar fora do próprio contrato (é por isso que está na DLQ). Por isso só valem os campos de
# correlação com o formato do contrato, e todos os que vierem têm de concordar com o banco: marca (slug),
# `conversation_id` (`tkt_<id>` da mesma marca), a chave (UUID de um turno desse atendimento), e, se presentes,
# `turn` e `assignment_version` iguais aos do turno. Toda leitura filtra por brand_id (invariante 6, ADR-014):
# uma marca no corpo diferente da do turno não acha nada.
module DeadLetters
  class Correlation
    Found = Data.define(:brand_id, :ticket_id, :turn_id, :turn)
    Missing = Data.define(:reason)

    KINDS = {
      [ "broker", "contrato" ] => :event, [ "broker", "traceparent_invalido" ] => :event,
      [ "broker", "event_id_divergente" ] => :event, [ "agent-mock", "contrato" ] => :event,
      [ "agent-mock", "acao_invalida" ] => :action, [ "platform", "contrato" ] => :action
    }.freeze
    SCHEMAS = { event: "helpdesk.agent_event.v1", action: "helpdesk.agent_action.v1" }.freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    CONVERSATION_ID = AgentActions::Apply::CONVERSATION_ID

    def self.call(...) = new(...).call

    def initialize(view)
      @headers = view.fetch("headers")
      @payload = view.fetch("payload")
    end

    def call
      @kind = KINDS[[ @headers["dlq_source"], @headers["dlq_reason"] ]]
      return missing("motivo_sem_correlacao") unless @kind
      return missing("corpo_ilegivel") unless body.is_a?(Hash)
      return missing("schema_divergente") if body.key?("schema") && body["schema"] != SCHEMAS.fetch(@kind)
      return missing("event_id_divergente") if event_id_mismatch?

      find_turn
    end

    private

    def find_turn
      brand_id = Brand.where(slug: string("brand")).pick(:id) or return missing("marca_desconhecida")
      ticket_id = CONVERSATION_ID.match(string("conversation_id").to_s)&.[](:id) or return missing("conversa_invalida")
      key = string(@kind == :event ? "event_id" : "in_reply_to")
      return missing("chave_invalida") unless UUID.match?(key.to_s)

      turn = AiTurn.where(brand_id:, ticket_id:, event_id: key).pick(:id, :turn, :assignment_version)
      return missing("turno_nao_encontrado") unless turn
      return missing("turno_divergente") unless agrees?("turn", turn[1]) && agrees?("assignment_version", turn[2])

      Found.new(brand_id:, ticket_id: Integer(ticket_id), turn_id: turn[0], turn: turn[1])
    end

    # Evento de turno: o cabeçalho event_id é o X-Helpdesk-Event-Id que a plataforma mandou. Divergente do corpo,
    # não se sabe qual dos dois vale.
    def event_id_mismatch?
      header = @headers["event_id"].to_s
      @kind == :event && !header.empty? && header != body["event_id"]
    end

    def agrees?(field, value) = !body.key?(field) || body[field] == value

    def string(field) = body[field].is_a?(String) ? body[field] : nil

    def body
      return @body if defined?(@body)

      @body = begin
        JSON.parse(@payload)
      rescue JSON::ParserError
        nil
      end
    end

    def missing(reason) = Missing.new(reason:)
  end
end
