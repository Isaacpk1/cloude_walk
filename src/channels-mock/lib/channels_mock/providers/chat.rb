require "securerandom"
require "time"

module ChannelsMock
  module Providers
    # Chat do app: formato próprio da CloudWalk (07, seção 5.0; ADR-018).
    module Chat
      ACCOUNTS = %w[infinitepay-chat-mock jim-chat-mock].freeze

      module_function

      def webhook(account_id:, customer_ref:, text:, message_id: nil, sent_at: Time.now)
        payload = {
          "message_id" => message_id.to_s.empty? ? "chat_msg_#{SecureRandom.hex(6)}" : message_id,
          "account_id" => account_id, "customer_ref" => customer_ref, "text" => text,
          "sent_at" => sent_at.utc.iso8601(3)
        }
        HelpdeskContracts.validate!(:chat_webhook, payload)
      end
    end
  end
end
