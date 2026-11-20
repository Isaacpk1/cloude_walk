module ChannelsMock
  # Relógio único do mock. Os testes congelam e avançam o tempo, sem sleep (AGENTS.md, regra 3).
  module Clock
    @frozen = nil
    @lock = Mutex.new

    class << self
      def now = @lock.synchronize { @frozen } || Time.now

      def freeze(at) = @lock.synchronize { @frozen = at }
      def advance(seconds) = @lock.synchronize { @frozen = (@frozen || Time.now) + seconds }
      def unfreeze = @lock.synchronize { @frozen = nil }
    end
  end
end
