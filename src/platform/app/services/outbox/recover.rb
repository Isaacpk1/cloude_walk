# Recuperação do outbox (07, seção 6: "o web cai depois do commit"; ADR-016). Reoferece ao worker os
# itens abertos e vencidos cujo aviso se perdeu: job nunca enfileirado, Redis que perdeu o job ou
# worker que caiu com a reserva. A carência evita reenfileirar o que o despertador normal ainda vai
# pegar. Reoferecer duas vezes é seguro: a reserva do item decide quem trabalha (Outbox::Publish).
module Outbox
  class Recover
    GRACE = 5.seconds
    BATCH = 100

    def self.call(limit: BATCH)
      now = Time.current
      ids = OutboxEvent.where(completed_at: nil).where(next_attempt_at: ..(now - GRACE))
                       .where("lease_until IS NULL OR lease_until < ?", now)
                       .order(:next_attempt_at).limit(limit).pluck(:id)
      ids.each { OutboxJob.perform_later(_1) }
      JsonLog.info("outbox.recovered", count: ids.size) if ids.any?
      ids
    rescue RedisClient::Error => e
      JsonLog.warn("outbox.recover_failed", error: e.class.name)
      []
    end
  end
end
