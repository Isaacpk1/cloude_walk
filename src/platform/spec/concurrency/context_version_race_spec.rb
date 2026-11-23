require "rails_helper"

# Versão do contexto sob concorrência, com o Postgres de verdade e fora da transação de teste (AGENTS.md,
# item 3; 07, seção 3.4, "Estado no atendimento"; RN-55, RF-33; invariantes 1, 4 e 8).
#
# Toda gravação visível (mensagem do cliente ou saída aplicada) passa pela linha travada do atendimento e
# sobe context_version em 1. Então, em qualquer ordem, a versão auditada de cada gravação é igual ao seu seq,
# e a versão final é igual ao número de mensagens visíveis.
RSpec.describe "RN-55, RF-33: versão do contexto com gravações concorrentes", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:t0) { Time.utc(2026, 11, 21, 13, 40, 0) }

  def apply(action) = AgentActions::Apply.call(action, traceparent: AgentActionHelpers::TRACEPARENT)

  # [seq, context_version] de cada gravação auditada no atendimento.
  def audited_versions(ticket)
    AuditEvent.where(ticket_id: ticket.id, event_type: %w[message.received delivery.requested])
              .pluck(Arel.sql("(data->>'seq')::int"), Arel.sql("(data->>'context_version')::int")).sort
  end

  describe "RN-55: duas mensagens simultâneas do mesmo cliente" do
    it "seqs 1 e 2, a versão sobe 2 e um único dispatch_due_at coerente" do
      results = travel_to(t0) do
        run_concurrently(threads: 2) { |i| ingest("mensagem #{i}", identity: "acc_infinitepay_versao") }
      end
      raise results.find { _1.is_a?(Exception) } if results.any?(Exception)

      expect(results).to all(be_created)
      ticket = Ticket.sole
      expect(ticket.messages.pluck(:seq)).to eq([ 1, 2 ])
      expect(ticket).to have_attributes(context_version: 2, latest_customer_seq: 2, first_pending_seq: 1,
                                        first_pending_at: t0, dispatch_due_at: t0 + 1.5.seconds)
      expect(audited_versions(ticket)).to eq([ [ 1, 1 ], [ 2, 2 ] ])
    end

    it "RNF-15: a mesma mensagem entregue duas vezes ao mesmo tempo sobe a versão uma vez só (repetição)" do
      message = normalized_message(identity: "acc_infinitepay_versao_dup", external_id: "chat_msg_dup_concorrente")

      results = run_concurrently(threads: 4) { Ingestion::Receive.call(message, provider_payload: {}) }
      raise results.find { _1.is_a?(Exception) } if results.any?(Exception)

      expect(results.map(&:status).tally).to eq(created: 1, duplicate: 3)
      expect(Ticket.sole.context_version).to eq(1)
    end
  end

  describe "RN-56: ingestão concorrente com a aplicação da ação do agente" do
    it "a versão sobe exatamente uma vez por gravação visível, em qualquer ordem, sem perder incremento" do
      outcomes = Array.new(6) do |round|
        identity = "acc_infinitepay_versao_#{round}"
        turn = opened_turn("meu repasse não caiu", identity:)
        action = agent_action_for(turn)

        results = run_concurrently(threads: 2) { |i| i.zero? ? apply(action) : ingest("é o de ontem", identity:) }
        raise results.find { _1.is_a?(Exception) } if results.any?(Exception)

        ticket = turn.ticket.reload
        visible = Message.where(ticket_id: ticket.id, internal: false).count
        expect(ticket.context_version).to eq(visible)
        expect(audited_versions(ticket)).to eq((1..visible).map { [ _1, _1 ] })
        results.first.status
      end

      # Aplicada antes da ingestão: 3 gravações (1, saída 2, mensagem 3). Rejeitada: 2 (1 e 2).
      expect(outcomes).to all(satisfy { |status| %i[applied rejected].include?(status) })
    end
  end
end
