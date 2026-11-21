module ChannelsMock
  # Falhas simuláveis do provedor do chat (blocos 05 e 09; 07, seção 6). Em memória, thread-safe.
  #
  #   lose_ack    aceita e grava o efeito, mas responde 504 (a confirmação se perde no caminho).
  #               A retentativa com a mesma chave recebe a confirmação gravada.
  #   unavailable 503 antes de qualquer efeito (transitório).
  #   reject      422 antes de qualquer efeito (recusa definitiva).
  #
  # Cada falha vale para os próximos `times` envios que chegariam a ela e depois volta a `none`.
  module Faults
    KINDS = %i[none lose_ack unavailable reject].freeze

    @lock = Mutex.new
    @current = :none
    @remaining = 0

    class << self
      def set(kind, times: 1)
        kind = kind.to_s.to_sym
        times = Integer(times)
        raise ArgumentError, "falha desconhecida: #{kind}" unless KINDS.include?(kind)
        raise ArgumentError, "times precisa ser positivo" unless times.positive?

        @lock.synchronize do
          @current = kind
          @remaining = kind == :none ? 0 : times
        end
        state
      end

      def clear = set(:none)
      def current = @lock.synchronize { @current }
      def remaining = @lock.synchronize { @remaining }
      def state = @lock.synchronize { { "fault" => @current.to_s, "remaining" => @remaining } }

      # Consome uma ocorrência quando a falha ativa é `kind`. Atômico: duas requisições não gastam a mesma.
      def take(kind)
        @lock.synchronize do
          next false unless @current == kind && @remaining.positive?

          @remaining -= 1
          @current = :none if @remaining.zero?
          true
        end
      end

      def configure_from(env)
        kind = env.fetch("CHAT_PROVIDER_FAULT", "none")
        set(kind, times: env.fetch("CHAT_PROVIDER_FAULT_TIMES", "1"))
      end
    end
  end
end
