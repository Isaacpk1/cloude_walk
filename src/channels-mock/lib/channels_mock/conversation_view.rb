require "time"

module ChannelsMock
  # Liga cada envio do cliente às respostas que o provedor recebeu da plataforma, pelo reply_to
  # (= message_id do webhook do cliente), e calcula o tempo total percebido (RNF-05):
  # momento em que a resposta chegou ao provedor − momento em que o cliente enviou (sent_at).
  module ConversationView
    Reply = Data.define(:record, :total_seconds) do
      def total_label = "#{format('%.1f', total_seconds.round(1)).tr('.', ',')} s"
      def total_ms = (total_seconds * 1000).round
    end
    Item = Data.define(:entry, :replies, :resend_of)

    module_function

    # entries e records vêm do mais novo para o mais antigo, como o Inbox e o ChatDeliveries guardam.
    def build(entries:, records:)
      first_entry = {}
      entries.reverse_each { |entry| first_entry[[ entry.account, message_id(entry) ]] ||= entry }
      linked = records.group_by { [ _1.account, _1.reply_to ] }

      items = entries.map do |entry|
        owner = first_entry[[ entry.account, message_id(entry) ]]
        next Item.new(entry:, replies: [], resend_of: owner.id) unless owner.equal?(entry)

        replies = (linked[[ entry.account, message_id(entry) ]] || []).sort_by(&:received_at)
        Item.new(entry:, replies: replies.map { Reply.new(record: _1, total_seconds: elapsed(entry, _1)) }, resend_of: nil)
      end
      orphans = records.reject { first_entry.key?([ _1.account, _1.reply_to ]) }
      [ items, orphans ]
    end

    def message_id(entry) = entry.payload["message_id"]

    def elapsed(entry, record)
      sent_at = entry.payload["sent_at"] ? Time.iso8601(entry.payload["sent_at"]) : entry.sent_at
      record.received_at - sent_at
    end
  end
end
