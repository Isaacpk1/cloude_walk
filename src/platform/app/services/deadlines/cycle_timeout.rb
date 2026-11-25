# Teto do ciclo vencido (RN-46, ADR-020; 07, seção 3.4, "Regras de tempo"; interface combinada, item 2).
#
# Atendimento com a IA, com ciclo pendente e `ai_deadline_at <= now`, vira um item `cycle.timeout` com a chave
# `timeout:cycle:<ticket_id>:<first_pending_seq>`. Vale mesmo sem nenhum turno publicado (broker fora do ar,
# turno não aberto, worker parado) ou com o cliente ainda escrevendo. O worker (Deadlines::Expire) revalida sob
# o lock e pede o handoff.
module Deadlines
  class CycleTimeout < Registration
    EVENT_TYPE = "cycle.timeout".freeze
    AUDIT_EVENT = "cycle.timeout_scheduled".freeze
    KEY_SQL = "'timeout:cycle:' || tickets.id || ':' || tickets.first_pending_seq".freeze

    def self.dedup_key(ticket) = "timeout:cycle:#{ticket.id}:#{ticket.first_pending_seq}"

    private

    # Os estados humanos saem na consulta; o responsável humano fora desses estados, no worker (with_ai?).
    def due
      tickets = scoped(Ticket.where(ai_deadline_at: ..now).where.not(first_pending_seq: nil)
                             .where.not(state: Ticket::HUMAN_STATES))
                .where("NOT EXISTS (SELECT 1 FROM outbox_events o WHERE o.dedup_key = #{KEY_SQL})")
                .order(:ai_deadline_at, :id).limit(limit).lock("#{Ticket::ROW_LOCK} SKIP LOCKED").to_a
      return [] if tickets.empty?

      traces = trace_ids(tickets)
      # O turno eligible do ciclo, se houver (o painel liga o prazo ao turno); null sem turno publicado.
      turns = AiTurn.eligible.joins(:ticket).where(ticket_id: tickets.map(&:id)).where("ai_turns.brand_id = tickets.brand_id")
                    .group(:ticket_id).maximum(:turn)
      tickets.map do |ticket|
        Due.new(ticket:, dedup_key: self.class.dedup_key(ticket), payload: payload(ticket),
                trace_id: traces[ticket.id] || SecureRandom.hex(16), deadline_at: ticket.ai_deadline_at,
                audit: { turn: turns[ticket.id], first_pending_seq: ticket.first_pending_seq,
                        assignment_version: ticket.assignment_version })
      end
    end

    # trace_id da primeira mensagem pendente do ciclo, da mesma marca.
    def trace_ids(tickets)
      Message.joins(:ticket).where(ticket_id: tickets.map(&:id))
             .where("messages.seq = tickets.first_pending_seq AND messages.brand_id = tickets.brand_id")
             .pluck(:ticket_id, :trace_id).to_h
    end

    def payload(ticket)
      { "ticket_id" => ticket.id, "first_pending_seq" => ticket.first_pending_seq,
        "assignment_version" => ticket.assignment_version, "ai_deadline_at" => iso(ticket.ai_deadline_at) }
    end
  end
end
