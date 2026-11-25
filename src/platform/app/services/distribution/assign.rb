# Atribuição automática de um atendimento da fila humana a um analista (RF-25, RN-30; 07, seção 3.5).
#
#   Distribution::Assign.call(ticket_id:, brand_id:, trace_id: nil, now: Time.current)
#   # => Result(status: :assigned | :waiting | :not_waiting, assignee_id:, reason:)
#
# Numa transação, trava o atendimento (FOR NO KEY UPDATE, ADR-031, na marca dele: invariante 6) e só age se ele ainda está em
# `aguardando_humano`, sem responsável e com fila. Os candidatos são analistas humanos online da equipe da fila,
# abaixo da capacidade, do menor `active_count` e, em empate, de quem está há mais tempo sem receber caso (nulo
# primeiro, depois o menor id). A vaga é reservada por `Distribution::Slot.claim!` (atualização condicional):
# quem perde a corrida tenta o próximo candidato, e dois casos nunca ocupam a mesma última vaga. Com a vaga, o
# caso vai a `com_analista`, `assignment_version` sobe 1 (invalida resposta tardia da IA, 07 seção 3.4) e
# `ticket.assigned` vai para a auditoria. Sem candidato, o caso espera sob a fila (RN-27), sem escrever nada.
# O SLA não é tocado (RN-23, RN-32). Ordem dos locks: atendimento, depois usuário. Nada externo na transação.
module Distribution
  class Assign
    EVENT_TYPE = "ticket.assigned".freeze
    REASON = "distribuicao_automatica".freeze
    Result = Data.define(:status, :assignee_id, :reason)

    def self.call(...) = new(...).call

    def initialize(ticket_id:, brand_id:, trace_id: nil, now: Time.current)
      @ticket_id = ticket_id
      @brand_id = brand_id
      @trace_id = trace_id
      @now = now
    end

    def call
      ActiveRecord::Base.transaction do
        ticket = Ticket.lock(Ticket::ROW_LOCK).find_by(id: @ticket_id, brand_id: @brand_id)
        if ticket.nil? || !waiting?(ticket) then Result.new(:not_waiting, nil, ticket.nil? ? "inexistente" : ticket.state)
        else attempt(ticket)
        end
      end
    end

    private

    def waiting?(ticket) = ticket.state == "aguardando_humano" && ticket.assignee_id.nil? && ticket.queue_id.present?

    def attempt(ticket)
      assignee_id = candidate_ids(ticket).find { Distribution::Slot.claim!(user_id: _1, now: @now) }
      return Result.new(:waiting, nil, "sem_analista_disponivel") unless assignee_id

      from = ticket.assignment_version
      ticket.update_columns(state: "com_analista", assignee_id:, assignment_version: from + 1, updated_at: @now)
      audit(ticket, assignee_id, from + 1)
      Result.new(:assigned, assignee_id, nil)
    end

    # A fila e a equipe são da marca do atendimento (invariante 6). A ordem é a da RN-30.
    def candidate_ids(ticket)
      queue = HelpdeskQueue.find_by(id: ticket.queue_id, brand_id: ticket.brand_id)
      return [] unless queue

      User.joins(:team_memberships)
          .where(team_memberships: { team_id: queue.team_id }, kind: "human", role: "analyst", status: "online")
          .where("users.active_count < users.capacity")
          .order(Arel.sql("users.active_count, users.last_assigned_at ASC NULLS FIRST, users.id"))
          .pluck(:id)
    end

    def audit(ticket, assignee_id, version)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type: EVENT_TYPE,
                         trace_id: @trace_id || SecureRandom.hex(16),
                         data: { to: "analista", reason: REASON, assignee_id:, queue_id: ticket.queue_id,
                                 state_from: "aguardando_humano", state_to: "com_analista", assignment_version: version })
    end
  end
end
