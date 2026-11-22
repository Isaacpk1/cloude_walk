# Pedido de handoff pelo outbox (interface combinada dos blocos 08 e 09, item 1; 07, seção 3.2; RN-33, RN-46).
#
#   Handoff::Request.call(ticket:, reason:, source:, turn:, trace_id:) # => id do item ou nil
#
# Quem decide escalar chama dentro da própria transação, com o atendimento já travado (invariante 2: o
# efeito fora do banco, o worker, só é acordado depois do commit por quem chamou). Um pedido por atribuição:
# a chave `handoff:<ticket_id>:<assignment_version>` faz o segundo gatilho na mesma atribuição colidir no
# índice único do outbox e não gravar nada (nil). A auditoria `handoff.requested` só sai com o item gravado, e o
# aviso de progresso do ciclo deixa de ser devido (progress_due_at nulo; RN-57). Os turnos eligible da
# atribuição expiram junto (RN-46, RN-56): da gravação do pedido ao Escalate, a IA não responde mais.
module Handoff
  class Request
    EVENT_TYPE = "handoff.requested".freeze
    REASONS = %w[prazo_do_turno teto_do_ciclo publicacao_falhou contexto_excede_limite falha_de_integracao
                 limite_de_trocas].freeze
    SOURCES = %w[scheduler outbox turns dlq].freeze

    def self.call(...) = new(...).call

    def self.dedup_key(ticket) = "handoff:#{ticket.id}:#{ticket.assignment_version}"

    # Há pedido de handoff da atribuição atual, ainda não executado ou já executado: a IA não recebe nem aplica
    # mais nada nesta atribuição (Turns::Open, AgentActions::Apply, Turns::ProgressNotice; RN-46, RN-56).
    def self.pending?(ticket)
      OutboxEvent.exists?(brand_id: ticket.brand_id, dedup_key: dedup_key(ticket))
    end

    def initialize(ticket:, reason:, source:, trace_id:, turn: nil)
      raise ArgumentError, "motivo de handoff desconhecido: #{reason}" unless REASONS.include?(reason)
      raise ArgumentError, "origem de handoff desconhecida: #{source}" unless SOURCES.include?(source)

      @ticket = ticket
      @reason = reason
      @source = source
      @turn = turn
      @trace_id = trace_id
    end

    def call
      now = Time.current
      row = { brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: EVENT_TYPE, dedup_key: self.class.dedup_key(@ticket),
              payload:, trace_id: @trace_id, next_attempt_at: now, created_at: now }
      id = OutboxEvent.insert_all([ row ], unique_by: :index_outbox_events_on_dedup_key, returning: [ :id ],
                                           record_timestamps: false).rows.first&.first
      return unless id

      audit(id)
      expire_turns
      # RN-57: com o handoff pedido, o aviso do ciclo não é mais devido (o worker o descartaria por handoff_pedido).
      # No próprio objeto travado de quem chamou: sem tocar o lock_version, para ele seguir válido no resto da transação.
      @ticket.update_columns(progress_due_at: nil) if @ticket.progress_due_at
      id
    end

    private

    def payload
      { "ticket_id" => @ticket.id, "reason" => @reason, "source" => @source, "turn" => @turn,
        "first_pending_seq" => @ticket.first_pending_seq, "assignment_version" => @ticket.assignment_version }
    end

    # RN-46, RN-56: com o pedido gravado, nenhuma resposta da atribuição é aplicada até o Escalate. Os turnos
    # eligible expiram na mesma transação (quem chamou pode já tê-los expirado, como o Deadlines::Expire).
    def expire_turns
      turns = @ticket.ai_turns.eligible.where(brand_id: @ticket.brand_id, assignment_version: @ticket.assignment_version).to_a
      return if turns.empty?

      AiTurn.where(id: turns.map(&:id), status: "eligible").update_all(status: "expired", updated_at: Time.current)
      turns.each do |turn|
        AuditEvent.create!(brand_id: @ticket.brand_id, ticket_id: @ticket.id, actor_type: "system", event_type: "ai_turn.expired",
                           trace_id: @trace_id, data: { turn: turn.turn, deadline_at: turn.deadline_at.utc.iso8601(3), reason: @reason })
      end
    end

    def audit(id)
      AuditEvent.create!(brand_id: @ticket.brand_id, ticket_id: @ticket.id, actor_type: "system", event_type: EVENT_TYPE,
                         trace_id: @trace_id, data: payload.merge("outbox_event_id" => id))
    end
  end
end
