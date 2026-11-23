# Uma volta da distribuição, chamada pelo `scheduler` (07, seção 3.5; RN-29, RN-30):
#
#   Distribution::Run.call(now: Time.current, limit: 100, brand_id: nil) # => ids dos atendimentos atribuídos
#
# Percorre os casos em `aguardando_humano` sem responsável, na ordem da RN-29 (prioridade, menor `sla_due_at` com o
# nulo por último, entrada mais antiga na fila e id), e chama `Distribution::Assign` para cada um. A consulta só traz
# casos cuja fila tem pelo menos um analista disponível (online, da equipe, abaixo da capacidade): uma fila sem
# ninguém não ocupa o `limit` da volta nem segura as outras. A decisão e o lock são do `Assign`, que revalida o
# caso: duas voltas ao mesmo tempo ou uma volta repetida nunca atribuem duas vezes. Não registra nada no outbox
# porque o efeito é só no Postgres (nada externo); o prazo de negócio da devolução (RN-31) é outro serviço.
module Distribution
  class Run
    PRIORITY_ORDER = <<~SQL.squish.freeze
      CASE tickets.priority WHEN 'critica' THEN 0 WHEN 'alta' THEN 1 WHEN 'baixa' THEN 3 ELSE 2 END
    SQL
    AVAILABLE_ANALYST = <<~SQL.squish.freeze
      EXISTS (
        SELECT 1 FROM queues q
        JOIN team_memberships tm ON tm.team_id = q.team_id
        JOIN users u ON u.id = tm.user_id
        WHERE q.id = tickets.queue_id AND q.brand_id = tickets.brand_id
          AND u.kind = 'human' AND u.role = 'analyst' AND u.status = 'online' AND u.active_count < u.capacity
      )
    SQL

    def self.call(...) = new(...).call

    def initialize(now: Time.current, limit: 100, brand_id: nil)
      @now = now
      @limit = limit
      @brand_id = brand_id
    end

    def call
      waiting.filter_map do |ticket|
        result = Distribution::Assign.call(ticket_id: ticket.id, brand_id: ticket.brand_id, now: @now)
        ticket.id if result.status == :assigned
      end
    end

    private

    def waiting
      scope = Ticket.where(state: "aguardando_humano", assignee_id: nil).where.not(queue_id: nil).where(AVAILABLE_ANALYST)
      scope = scope.where(brand_id: @brand_id) if @brand_id
      scope.order(Arel.sql("#{PRIORITY_ORDER}, tickets.sla_due_at ASC NULLS LAST, COALESCE(tickets.sla_started_at, tickets.updated_at), tickets.id"))
           .limit(@limit).select(:id, :brand_id).to_a
    end
  end
end
