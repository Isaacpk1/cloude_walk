# Política única de retentativa das saídas do outbox (RN-43, RNF-16; 07, seção 6). Vale para a publicação
# no broker (Outbox::Publish) e para a entrega ao canal (Deliveries::Policy, Deliveries::Send): 5
# retentativas depois da primeira tentativa, esperando 1, 2, 4, 8 e 16 s, mais um jitter de até 25%
# (só para cima, para nunca encurtar a espera).
#
# Uma tentativa abandonada (o worker caiu depois da reserva) conta como tentativa: a recuperação retoma
# o item, mas uma reserva além de MAX_ATTEMPTS encerra a saída pelo desfecho terminal do tipo
# (publicação: publish_failed retentativas_esgotadas; entrega: failed ou conciliação).
module Outbox
  module RetryPolicy
    MAX_RETRIES = 5
    MAX_ATTEMPTS = MAX_RETRIES + 1
    MAX_JITTER = 0.25
    DEFAULT_JITTER = -> { rand }

    module_function

    # Espera depois da tentativa `attempt` (1, 2, 4, 8, 16 s), com jitter só para cima.
    def backoff(attempt, jitter: DEFAULT_JITTER)
      (2**(attempt - 1) * (1 + (MAX_JITTER * jitter.call))).seconds
    end

    # Tentativa `attempt` já passou do limite (a reserva que a abriu não devia ter chamado ninguém).
    def exceeded?(attempt) = attempt > MAX_ATTEMPTS
  end
end
