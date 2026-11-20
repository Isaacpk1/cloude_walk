module Broker
  # Deduplicação por event_id no broker (07, seção 5.2: X-Helpdesk-Event-Id). Fica em memória,
  # por réplica, com tamanho limitado: o broker não tem banco (docs/10, seção 3.2). A garantia de
  # efeito único continua nos consumidores, por processed_events (invariante 3, RN-47).
  #
  # Um event_id só vira "publicado" depois da confirmação do Kafka. Enquanto a primeira entrega
  # está em andamento, a segunda recebe "em andamento" e a plataforma tenta de novo.
  class Dedup
    LIMIT = 10_000

    def initialize(limit: LIMIT)
      @limit = limit
      @done = {}
      @in_flight = {}
      @lock = Mutex.new
    end

    # :new (pode publicar), :in_flight ou o resultado já confirmado (Hash).
    def claim(event_id)
      @lock.synchronize do
        next @done[event_id] if @done.key?(event_id)
        next :in_flight if @in_flight.key?(event_id)

        @in_flight[event_id] = true
        :new
      end
    end

    def confirm(event_id, result)
      @lock.synchronize do
        @in_flight.delete(event_id)
        @done[event_id] = result
        @done.shift while @done.size > @limit
      end
    end

    def release(event_id) = @lock.synchronize { @in_flight.delete(event_id) }
    def in_flight?(event_id) = @lock.synchronize { @in_flight.key?(event_id) }
  end
end
