require "securerandom"
require_relative "clock"
require_relative "faults"

module ChannelsMock
  # O que o provedor do chat aceitou da plataforma (07, seção 3.2; RNF-15). Em memória, como o Inbox,
  # mas é o "banco" do provedor: o efeito (a mensagem que o cliente vê) e a confirmação devolvida
  # são gravados juntos, sob o mesmo lock, para que a mesma Idempotency-Key devolva a mesma resposta.
  module ChatDeliveries
    Record = Data.define(:message_id, :key, :account, :conversation_id, :seq, :customer_ref, :text, :reply_to,
                         :trace_id, :received_at, :body, :replays, :statuses) do
      def response = { "message_id" => message_id, "status" => "accepted" }
      def last_status = statuses.last&.fetch("status") || "accepted"
    end

    # outcome: :accepted, :ack_lost (gravado, confirmação perdida), :replayed, :stale (seq anterior),
    # :seq_taken (outra chave na mesma seq), :rejected (falha simulada), :key_reused (mesma chave, outro corpo).
    Result = Data.define(:outcome, :record, :last_seq)

    LIMIT = 1_000
    @lock = Mutex.new

    class << self
      def clear
        @lock.synchronize do
          @by_key = {}
          @last_seq = {}
        end
      end

      def accept(account:, key:, conversation_id:, seq:, payload:, body:, trace_id:)
        @lock.synchronize do
          if (existing = @by_key[[ account, key ]])
            next Result.new(outcome: :key_reused, record: existing, last_seq: nil) if existing.body != body

            next Result.new(outcome: :replayed, record: replay!(existing), last_seq: nil)
          end

          last = @last_seq[[ account, conversation_id ]]
          next Result.new(outcome: :stale, record: nil, last_seq: last) if last && seq < last
          next Result.new(outcome: :seq_taken, record: nil, last_seq: last) if last && seq == last
          next Result.new(outcome: :rejected, record: nil, last_seq: last) if Faults.take(:reject)

          record = store!(account:, key:, conversation_id:, seq:, payload:, body:, trace_id:)
          Result.new(outcome: Faults.take(:lose_ack) ? :ack_lost : :accepted, record:, last_seq: seq)
        end
      end

      # Histórico de status enviado à plataforma (callback, interface do bloco 05, seção 3).
      def record_status(message_id, entry)
        @lock.synchronize do
          pair = @by_key.find { |_, record| record.message_id == message_id } or next nil
          @by_key[pair.first] = pair.last.with(statuses: pair.last.statuses + [ entry ])
        end
      end

      def all = @lock.synchronize { @by_key.values.reverse }
      def find(message_id) = all.find { _1.message_id == message_id }

      private

      def replay!(record) = @by_key[[ record.account, record.key ]] = record.with(replays: record.replays + 1)

      def store!(account:, key:, conversation_id:, seq:, payload:, body:, trace_id:)
        record = Record.new(message_id: "chatmsg_#{SecureRandom.hex(8)}", key:, account:, conversation_id:, seq:,
                            customer_ref: payload["customer_ref"], text: payload["text"], reply_to: payload["reply_to"],
                            trace_id:, received_at: Clock.now, body:, replays: 0, statuses: [])
        @by_key[[ account, key ]] = record
        @last_seq[[ account, conversation_id ]] = seq
        @by_key.delete(@by_key.each_key.first) while @by_key.size > LIMIT
        record
      end
    end

    clear
  end
end
