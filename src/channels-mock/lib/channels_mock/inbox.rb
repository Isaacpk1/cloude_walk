module ChannelsMock
  # Histórico do simulador, só em memória (docs/10, seção 3.4). Não é fonte da verdade.
  module Inbox
    Entry = Data.define(:id, :channel, :account, :payload, :response, :error, :sent_at, :tampered) do
      def outcome
        return "Contrato" if error
        return "Plataforma indisponível" if response.status.nil?

        { 202 => "Confirmada", 200 => "Duplicada", 401 => "Recusada" }.fetch(response.status, "Erro #{response.status}")
      end

      def ticket_id = response&.body&.dig("ticket_id")
      def reason = response&.body&.dig("reason")
    end

    LIMIT = 50
    @entries = []
    @lock = Mutex.new

    class << self
      def add(**attrs)
        @lock.synchronize do
          entry = Entry.new(id: (@entries.first&.id || 0) + 1, sent_at: Time.now, tampered: false, **attrs)
          @entries.unshift(entry)
          @entries.pop while @entries.size > LIMIT
          entry
        end
      end

      def all = @lock.synchronize { @entries.dup }
      def find(id) = all.find { _1.id == id }
      def clear = @lock.synchronize { @entries.clear }
    end
  end
end
