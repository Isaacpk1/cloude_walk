module AgentMock
  module Tools
    # Status do repasse de uma data (07, seção 5.3: { date } → { status, amount }).
    class GetSettlementStatus < Base
      STATUSES = %w[pago pendente em_processamento].freeze

      # "Meu repasse de ontem": sem data no texto, consulta o dia anterior ao evento.
      def self.args_for(event, _text)
        date = Date.iso8601(event.fetch("occurred_at")[0, 10]) - 1
        { "customer_id" => event.dig("customer", "id"), "date" => date.iso8601 }
      end

      private

      def result_for(args)
        date = Date.iso8601(args.fetch("date"))
        { "status" => pick(args, "status", STATUSES), "amount" => cents(args, "amount", 10_000..500_000),
          "date" => date.iso8601, "expected_at" => (date + 2).iso8601 }
      end
    end
  end
end
