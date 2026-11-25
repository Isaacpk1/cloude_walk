# Worker dos timeouts do turno e do ciclo (RN-46, ADR-016, ADR-020; 07, seção 3.4 e seção 6; interface
# combinada, item 2).
#
#   Deadlines::Expire.call(outbox_event_id) # => Result(status:, reason:, handoff_event_id:, next_attempt_at:)
#
# Chamado pelo OutboxJob para os itens "turn.timeout" e "cycle.timeout". Uma transação, com o atendimento
# travado antes do item (a ordem do resto do sistema) e escopo pela marca do item (invariante 6). Revalida a
# ação com o relógio do banco lido depois do lock (DatabaseClock, como o AgentActions::Apply):
#
# - turn.timeout: o turno ainda `eligible`, da atribuição atual, com o caso na IA e o ciclo pendente.
# - cycle.timeout: o mesmo ciclo (`first_pending_seq`), a mesma atribuição, o caso na IA.
#
# Válida e vencida: os turnos `eligible` viram `expired` (`ai_turn.expired`) e o handoff é pedido na mesma
# transação (Handoff::Request, `prazo_do_turno` ou `teto_do_ciclo`, origem `scheduler`). Se outro gatilho já
# pediu o handoff nesta atribuição, a chave colide e só o turno expira. Obsoleta: descarte auditado
# (`turn.timeout_discarded` / `cycle.timeout_discarded`). Ainda não vencida pelo relógio do banco (relógios
# diferentes entre o scheduler e o Postgres): o item fica aberto, com o despertador no prazo gravado; nunca é
# descartado, senão a chave consumida esconderia o prazo. O item encerra na transação do efeito ou do descarte.
module Deadlines
  class Expire
    Result = Data.define(:status, :reason, :handoff_event_id, :next_attempt_at) do
      def initialize(reason: nil, handoff_event_id: nil, next_attempt_at: nil, **) = super
    end

    def self.call(...) = new(...).call

    def initialize(outbox_event_id)
      @id = outbox_event_id
    end

    def call
      ActiveRecord::Base.transaction do
        @item = OutboxEvent.find_by(id: @id)
        next Result.new(status: :skipped) unless @item

        @ticket = Ticket.lock(Ticket::ROW_LOCK).find_by(id: @item.ticket_id, brand_id: @item.brand_id)
        @item.lock!
        next Result.new(status: :already_done) if @item.completed_at

        @db_now = DatabaseClock.now # depois do lock
        turn_timeout? ? judge_turn : judge_cycle
      end
    end

    private

    attr_reader :item, :ticket

    def payload = item.payload
    def turn_timeout? = item.event_type == TurnTimeout::EVENT_TYPE
    def kind = turn_timeout? ? "turn" : "cycle"

    def judge_turn
      return discard("atendimento_inexistente") unless ticket

      turn = ticket.ai_turns.find_by(brand_id: ticket.brand_id, turn: payload["turn"])
      return discard("turno_inexistente") unless turn
      return discard("turno_#{turn.status}") unless turn.eligible?

      reason = common_reason(turn.assignment_version)
      return discard(reason) if reason
      return not_due(turn.deadline_at) if @db_now < turn.deadline_at

      expire(reason: "prazo_do_turno", turn: turn.turn)
    end

    def judge_cycle
      return discard("atendimento_inexistente") unless ticket
      return discard("ciclo_mudou") if ticket.first_pending_seq != payload["first_pending_seq"]

      reason = common_reason(payload["assignment_version"])
      return discard(reason) if reason
      return discard("ciclo_encerrado") unless ticket.ai_deadline_at
      return not_due(ticket.ai_deadline_at) if @db_now < ticket.ai_deadline_at

      expire(reason: "teto_do_ciclo", turn: ticket.ai_turns.eligible.where(brand_id: ticket.brand_id).maximum(:turn))
    end

    def common_reason(expected_version)
      return "atribuicao_mudou" if expected_version != ticket.assignment_version
      return "fora_da_ia" unless ticket.with_ai?

      "ciclo_encerrado" unless ticket.first_pending_seq
    end

    def expire(reason:, turn:)
      expire_turns(reason)
      handoff = Handoff::Request.call(ticket:, reason:, source: "scheduler", turn:, trace_id: item.trace_id)
      complete
      JsonLog.info("deadline.expired", trace_id: item.trace_id, ticket_id: ticket.id, event_type: item.event_type,
                                       reason:, turn:, handoff_requested: !handoff.nil?)
      Result.new(status: :expired, reason:, handoff_event_id: handoff)
    end

    # 07, seção 3.4: a transição para `expired` parte de `eligible`, por atualização condicional.
    def expire_turns(reason)
      turns = ticket.ai_turns.eligible.where(brand_id: ticket.brand_id).to_a
      expired = AiTurn.where(id: turns.map(&:id), status: "eligible").update_all(status: "expired", updated_at: Time.current)
      return if expired.zero?

      turns.each { audit("ai_turn.expired", turn: _1.turn, deadline_at: _1.deadline_at.utc.iso8601(3), reason:) }
    end

    def not_due(deadline_at)
      item.update!(next_attempt_at: deadline_at, lease_until: nil)
      Result.new(status: :not_due, next_attempt_at: deadline_at)
    end

    def discard(reason)
      complete(last_error: reason)
      audit("#{kind}.timeout_discarded", **discard_facts, reason:)
      JsonLog.info("deadline.discarded", trace_id: item.trace_id, outbox_event_id: item.id, event_type: item.event_type, reason:)
      Result.new(status: :discarded, reason:)
    end

    # O painel liga o descarte ao turno e ao ciclo do item (bloco 08, item 5).
    def discard_facts
      payload = item.payload
      { turn: payload["turn"], first_pending_seq: payload["first_pending_seq"],
        assignment_version: payload["assignment_version"],
        deadline_at: payload["deadline_at"] || payload["ai_deadline_at"] }
    end

    def complete(last_error: nil) = item.update!(completed_at: Time.current, lease_until: nil, last_error:)

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: item.brand_id, ticket_id: ticket&.id, actor_type: "system", event_type:,
                         trace_id: item.trace_id, data: { outbox_event_id: item.id, timeout: item.event_type }.merge(data))
    end
  end
end
