# Parâmetros da entrega ao canal (07, seções 3.2 e 6; RN-43, RNF-16). Num lugar só, para o envio, a
# recuperação e os testes usarem os mesmos valores.
module Deliveries
  module Policy
    # Reserva de uma tentativa (deliveries.lease_until). Cobre a chamada inteira (abrir + ler) com folga.
    # Vencida, a recuperação retoma a tentativa abandonada (07, seção 3.2).
    LEASE = 15.seconds
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 5
    # RN-43: 5 retentativas depois da primeira tentativa, com 1, 2, 4, 8 e 16 s mais até 25% de jitter.
    MAX_RETRIES = 5
    MAX_ATTEMPTS = MAX_RETRIES + 1
    MAX_JITTER = 0.25
    DEFAULT_JITTER = -> { rand }
    # Despertador de uma saída que espera a anterior. Quem acorda de verdade é a conclusão da anterior;
    # este prazo só cobre um aviso perdido (a recuperação reoferece o item).
    ORDER_RECHECK = 30.seconds

    module_function

    # Espera depois da tentativa `attempt` (1, 2, 4, 8, 16 s), com jitter só para cima.
    def backoff(attempt, jitter: DEFAULT_JITTER)
      (2**(attempt - 1) * (1 + (MAX_JITTER * jitter.call))).seconds
    end
  end
end
