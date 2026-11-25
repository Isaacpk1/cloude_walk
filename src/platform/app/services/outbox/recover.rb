# Recuperação do outbox (07, seção 6: "o web cai depois do commit", "scheduler cai após registrar a ação",
# "broker volta com backlog"; ADR-016; RF-34 + RF-35; RNF-14, RNF-17). Varre os itens abertos e vencidos
# cujo aviso se perdeu: job nunca enfileirado, Redis que perdeu o job ou worker que caiu com a reserva.
# A carência evita reenfileirar o que o despertador normal ainda vai pegar. Vale para qualquer tipo de
# OutboxJob::HANDLED, inclusive as ações do scheduler.
#
# Cada item é decidido numa transação curta, com a linha do atendimento travada (FOR UPDATE SKIP LOCKED:
# atendimento ocupado fica para a próxima volta, sem bloquear a varredura) e depois o item, a mesma
# ordem do resto do sistema:
#
# - obsoleto (Outbox::Obsolescence): encerra o item sem nova ação, com `last_error` "obsoleto: <motivo>" e a
#   auditoria `outbox.closed_obsolete` (`event_type`, `reason`, `attempts`). Nada vai ao worker, ao broker
#   ou à IA; mensagens, auditoria e `seq` ficam como estão.
# - ainda vale: põe o despertador no agora (`next_attempt_at`), audita `outbox.recovered` (`event_type`,
#   `attempts`) e, depois do commit, acorda o worker (invariante 2). O despertador no agora faz a carência
#   valer de novo: outra réplica da varredura não reoferece o mesmo item na mesma volta, e um item cujo job
#   se perde de novo volta a cada GRACE, não a cada volta.
#
# Limite da recuperação: não há um teto de reofertas por item. Quem encerra é o próprio tipo, pelo seu
# limite, sempre com o histórico preservado e um desfecho auditado:
# - publicação: 5 retentativas, contando as abandonadas (Outbox::RetryPolicy) → publish_failed terminal;
# - entrega: 6 tentativas → failed ou conciliação (a entrega fica em `sending`, Deliveries::Send);
# - abertura de turno: o teto do ciclo (ai_deadline_at) → ai_turn.not_opened prazo_vencido (Turns::Open);
# - itens de turno e de ciclo: o prazo do turno ou o fim do ciclo os tornam obsoletos aqui.
# Um item reoferecido para sempre só acontece com um defeito no worker (exceção a cada tentativa): o log
# `outbox.recovered` com o mesmo id repetido é o sinal.
module Outbox
  class Recover
    GRACE = 5.seconds
    BATCH = 100
    RECOVERED = "outbox.recovered".freeze
    CLOSED_OBSOLETE = "outbox.closed_obsolete".freeze

    def self.call(limit: BATCH) = new(limit:).call

    def initialize(limit:)
      @limit = limit
    end

    def call
      @now = Time.current
      woken = []
      candidates.each do |id|
        recovered = decide(id)
        next unless recovered
        break unless wake(recovered)

        woken << recovered
      end
      JsonLog.info("outbox.recover_done", count: woken.size) if woken.any?
      woken
    end

    private

    attr_reader :now

    def candidates
      due(OutboxEvent.where(event_type: OutboxJob::HANDLED)).order(:next_attempt_at).limit(@limit).pluck(:id)
    end

    def due(scope)
      scope.where(completed_at: nil).where(next_attempt_at: ..(now - GRACE)).where("lease_until IS NULL OR lease_until < ?", now)
    end

    # Devolve o id se o item foi reoferecido.
    def decide(id)
      ActiveRecord::Base.transaction do
        item = OutboxEvent.find_by(id:)
        next unless item

        ticket = item.ticket_id && Ticket.lock("#{Ticket::ROW_LOCK} SKIP LOCKED").find_by(id: item.ticket_id, brand_id: item.brand_id)
        next if item.ticket_id && ticket.nil? # ocupado por outro processo: fica para a próxima volta

        item = due(OutboxEvent.where(id:)).lock.first
        next unless item

        reason = Obsolescence.reason(item, ticket, now:)
        reason ? close_obsolete(item, ticket, reason) : recover(item)
      end
    end

    def close_obsolete(item, ticket, reason)
      item.update!(completed_at: now, lease_until: nil, last_error: "obsoleto: #{reason}")
      # Como o Turns::Open no mesmo caso: sem a IA, nenhuma volta do scheduler abre turno até uma gravação nova.
      ticket.update_columns(dispatch_due_at: nil) if item.event_type == Obsolescence::DISPATCH && reason == "fora_da_ia"
      audit(item, CLOSED_OBSOLETE, reason:)
      JsonLog.info(CLOSED_OBSOLETE, trace_id: item.trace_id, outbox_event_id: item.id, ticket_id: item.ticket_id,
                                    event_type: item.event_type, reason:)
      nil
    end

    def recover(item)
      item.update!(next_attempt_at: now)
      audit(item, RECOVERED)
      JsonLog.info(RECOVERED, trace_id: item.trace_id, outbox_event_id: item.id, ticket_id: item.ticket_id,
                              event_type: item.event_type, attempts: item.attempts)
      item.id
    end

    def audit(item, event_type, **data)
      AuditEvent.create!(brand_id: item.brand_id, ticket_id: item.ticket_id, actor_type: "system", event_type:,
                         trace_id: item.trace_id,
                         data: { outbox_event_id: item.id, event_type: item.event_type, attempts: item.attempts }.merge(data))
    end

    # Depois do commit de cada item (invariante 2). Redis fora: para na primeira falha; o item segue aberto e
    # volta depois da carência, e os seguintes nem são auditados nesta volta.
    def wake(id)
      OutboxJob.perform_later(id)
      true
    rescue StandardError => e
      JsonLog.warn("outbox.recover_failed", outbox_event_id: id, error: e.class.name)
      false
    end
  end
end
