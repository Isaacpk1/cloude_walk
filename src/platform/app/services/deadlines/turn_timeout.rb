# Prazo do turno vencido (RN-46, ADR-020; 07, seção 3.4, "Regras de tempo"; interface combinada, item 2).
#
# Turno `eligible` com `deadline_at <= now` (o menor entre a abertura + 20 s e o teto do ciclo) vira um item
# `turn.timeout` com a chave `timeout:turn:<ticket_id>:<turn>`. O worker (Deadlines::Expire) revalida sob o
# lock, expira o turno e pede o handoff.
#
# Turno vencido com o ciclo ainda dentro do teto: escala do mesmo jeito. A RN-46 diz "a partir do vencimento
# do turno ou do teto, a plataforma rejeita ações da IA e escala o caso"; não há segundo turno nem nova
# tentativa do mesmo turno (ADR-020, alternativa recusada "Retentar o turno uma vez antes de escalar").
module Deadlines
  class TurnTimeout < Registration
    EVENT_TYPE = "turn.timeout".freeze
    AUDIT_EVENT = "turn.timeout_scheduled".freeze
    KEY_SQL = "'timeout:turn:' || ai_turns.ticket_id || ':' || ai_turns.turn".freeze

    def self.dedup_key(turn) = "timeout:turn:#{turn.ticket_id}:#{turn.turn}"

    private

    def due
      turns = scoped(AiTurn.eligible.where(deadline_at: ..now), ticket_column: :ticket_id)
              .where("NOT EXISTS (SELECT 1 FROM outbox_events o WHERE o.dedup_key = #{KEY_SQL})")
              .order(:deadline_at, :id).limit(limit).to_a
      return [] if turns.empty?

      tickets = Ticket.where(id: turns.map(&:ticket_id)).lock("FOR UPDATE SKIP LOCKED").index_by(&:id)
      traces = OutboxEvent.where(id: turns.map(&:event_id)).pluck(:id, :trace_id).to_h
      turns.filter_map do |turn|
        ticket = tickets[turn.ticket_id]
        next unless ticket && ticket.brand_id == turn.brand_id

        turn.reload # sob o lock do atendimento
        next unless turn.eligible? && turn.deadline_at <= now

        Due.new(ticket:, dedup_key: self.class.dedup_key(turn), payload: payload(ticket, turn),
                trace_id: traces[turn.event_id] || SecureRandom.hex(16), deadline_at: turn.deadline_at,
                audit: { turn: turn.turn, first_pending_seq: ticket.first_pending_seq, event_id: turn.event_id,
                        assignment_version: turn.assignment_version })
      end
    end

    def payload(ticket, turn)
      { "ticket_id" => ticket.id, "turn" => turn.turn, "event_id" => turn.event_id,
        "assignment_version" => turn.assignment_version, "first_pending_seq" => ticket.first_pending_seq,
        "deadline_at" => iso(turn.deadline_at) }
    end
  end
end
