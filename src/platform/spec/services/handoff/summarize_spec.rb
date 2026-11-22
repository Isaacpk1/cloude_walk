require "rails_helper"

# Resumo do handoff montado pela plataforma (RN-39, RN-40, RF-40, RF-41, RNF-06; 07, seção 3.2).
# O item `handoff.summary` é gravado pelo Escalate quando o pedido não trouxe o resumo do agente; aqui o teste
# grava o item no formato combinado: chave `summary:<ticket>:<from_assignment_version>`.
RSpec.describe Handoff::Summarize, "RN-39, RN-40: resumo do handoff pela plataforma" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }

  let(:first_text) { "Meu repasse de R$ 1.200 do dia 28 não caiu. Meu tel é (11) 98765-4321 e o e-mail maria.souza@exemplo.com" }
  let(:last_text) { "Aqui é a maria souza. Já faz dois dias, meu CPF é 123.456.789-09, me liga no +55 11 91234-5678" }

  # Histórico: mensagem 1, reply da IA com consulta, mensagem 3 sem resposta; o caso escala por prazo.
  def escalated_ticket(reason: "prazo_do_turno")
    turn = opened_turn(first_text)
    AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)
    ticket = turn.ticket.reload
    ticket.customer.update_columns(display_name: "Maria Souza")
    ingest(last_text)
    id = request_handoff(ticket, reason:, source: "scheduler")
    Handoff::Escalate.call(id)
    ticket.reload
  end

  def summary_item(ticket, from: 0, reason: "prazo_do_turno", escalated_at: db_now, brand_id: ticket.brand_id)
    # O banco já recusa item com atendimento de outra marca na coluna (fk_outbox_events_ticket_same_brand): o caso de
    # marca errada que sobra é o payload apontar para o atendimento de outra marca.
    # O Escalate (bloco 10) já grava este item; o teste o regrava com o payload que controla.
    OutboxEvent.where(dedup_key: "summary:#{ticket.id}:#{from}").delete_all
    OutboxEvent.create!(brand_id:, ticket_id: (ticket.id if brand_id == ticket.brand_id), event_type: described_class::EVENT_TYPE,
                        dedup_key: "summary:#{ticket.id}:#{from}", trace_id: "d" * 32, next_attempt_at: Time.current,
                        payload: { "ticket_id" => ticket.id, "from_assignment_version" => from, "reason" => reason,
                                   "escalated_at" => escalated_at&.utc&.iso8601(6) })
  end

  def summarize(item) = described_class.call(item.id)
  def summary_audits(ticket) = AuditEvent.where(ticket_id: ticket.id, event_type: %w[handoff.summary_available handoff.summary_missing])

  describe "RN-39: caminho feliz" do
    it "grava os cinco campos (source platform, available), audita e conclui o item na mesma transação" do
      ticket = escalated_ticket
      item = summary_item(ticket)

      result = summarize(item)

      expect(result.status).to eq(:available)
      summary = HandoffSummary.find_by!(ticket_id: ticket.id, from_assignment_version: 0)
      expect(summary).to have_attributes(brand_id: infinitepay.id, source: "platform", status: "available",
                                         missing_reason: nil, trace_id: "d" * 32)
      expect(summary.fields.keys).to match_array(HandoffSummary::FIELDS) # jsonb não guarda a ordem
      expect(summary.fields.values).to all(be_present)
      expect(summary.fields["problema"]).to include("repasse de R$ 1.200 do dia 28")
      expect(summary.fields["acoes_tomadas"]).to include("get_settlement_status")
      expect(summary.fields["acoes_tomadas"]).to include("Seu repasse de R$ 1.200 cai hoje")
      expect(summary.fields["motivo"]).to eq("A IA não respondeu dentro do prazo do turno.")
      expect(summary.fields["pendente"]).to include("Já faz dois dias")
      expect(summary.fields["dados_cliente"]).to include("M*** S***", "não verificado", "chat")
      expect(item.reload.completed_at).to be_present
      audit = summary_audits(ticket).sole
      expect(audit).to have_attributes(event_type: "handoff.summary_available", brand_id: infinitepay.id, trace_id: "d" * 32)
      expect(audit.data).to include("source" => "platform", "from_assignment_version" => 0, "summary_id" => summary.id)
      expect(audit.data["ms_since_escalated"]).to be_a(Integer)
    end

    it "RN-51: sem PII crua: nome mascarado, sem telefone, e-mail nem documento" do
      ticket = escalated_ticket
      summarize(summary_item(ticket))

      text = HandoffSummary.find_by!(ticket_id: ticket.id).fields.values.join("\n")
      expect(text).not_to include("Maria", "Souza", "98765", "4321", "maria.souza", "@exemplo.com", "123.456", "91234", "5678")
      expect(text).not_to match(/maria|souza/i)
      expect(text).to include("[telefone]", "[e-mail]", "[documento]")
    end

    it "motivo em texto legível para cada motivo do handoff" do
      Handoff::Request::REASONS.each do |reason|
        expect(described_class::REASON_TEXTS.fetch(reason)).to be_present
      end
    end
  end

  describe "RN-40: sem resumo, o caso continua escalado" do
    it "historico_vazio: atendimento sem mensagem do cliente grava missing" do
      customer = create(:customer, brand: infinitepay)
      ticket = Ticket.create!(brand: infinitepay, customer:, channel: "chat", state: "aguardando_humano", assignment_version: 1)
      item = summary_item(ticket)

      expect(summarize(item).status).to eq(:missing)

      expect(HandoffSummary.find_by!(ticket_id: ticket.id)).to have_attributes(status: "missing", missing_reason: "historico_vazio",
                                                                              source: "platform", fields: nil)
      expect(summary_audits(ticket).sole).to have_attributes(event_type: "handoff.summary_missing")
      expect(summary_audits(ticket).sole.data).to include("missing_reason" => "historico_vazio", "from_assignment_version" => 0)
      expect(item.reload.completed_at).to be_present
    end

    it "erro_ao_montar: a montagem lança erro, grava missing e não desfaz o handoff" do
      ticket = escalated_ticket
      item = summary_item(ticket)
      allow_any_instance_of(described_class).to receive(:build_fields).and_raise(ActiveRecord::StatementInvalid, "falhou") # rubocop:disable RSpec/AnyInstance

      expect(summarize(item).status).to eq(:missing)

      expect(HandoffSummary.find_by!(ticket_id: ticket.id)).to have_attributes(status: "missing", missing_reason: "erro_ao_montar")
      expect(ticket.reload).to have_attributes(state: "aguardando_humano", assignment_version: 1)
      expect(item.reload.completed_at).to be_present
    end
  end

  describe "repetição e ordem" do
    it "RNF-15 (repetição): o mesmo item processado duas vezes grava um resumo e uma auditoria" do
      ticket = escalated_ticket
      item = summary_item(ticket)

      summarize(item)
      expect(summarize(item).status).to eq(:already_done)

      expect(HandoffSummary.where(ticket_id: ticket.id).count).to eq(1)
      expect(summary_audits(ticket).count).to eq(1)
    end

    it "ordem: o agente já gravou o resumo dele; a plataforma não grava nem audita nada e conclui o item" do
      ticket = escalated_ticket
      agent = HandoffSummary.create!(brand: infinitepay, ticket:, from_assignment_version: 0, source: "agent",
                                     status: "available", fields: HandoffSummary::FIELDS.index_with { "do agente" }, trace_id: "a" * 32)
      item = summary_item(ticket)

      expect(summarize(item).status).to eq(:already_present)

      expect(HandoffSummary.where(ticket_id: ticket.id).sole).to eq(agent)
      expect(summary_audits(ticket)).to be_empty
      expect(item.reload.completed_at).to be_present
    end

    it "resumos de handoffs diferentes do mesmo atendimento não colidem" do
      ticket = escalated_ticket
      HandoffSummary.create!(brand: infinitepay, ticket:, from_assignment_version: 0, source: "agent", status: "missing",
                             missing_reason: "historico_vazio", trace_id: "a" * 32)

      expect(summarize(summary_item(ticket, from: 1)).status).to eq(:available)
      expect(HandoffSummary.where(ticket_id: ticket.id).pluck(:from_assignment_version)).to contain_exactly(0, 1)
    end
  end

  describe "invariante 6: marca errada" do
    it "item da JIM com o atendimento da InfinitePay é descartado sem efeito" do
      ticket = escalated_ticket
      item = summary_item(ticket, brand_id: jim.id)

      expect(summarize(item)).to have_attributes(status: :discarded, reason: "atendimento_inexistente")

      expect(HandoffSummary.count).to eq(0)
      expect(summary_audits(ticket)).to be_empty
      expect(item.reload).to have_attributes(completed_at: be_present, last_error: "atendimento_inexistente")
    end

    it "lê só o histórico da marca do item: mensagens de outro atendimento não entram" do
      ticket = escalated_ticket
      ingest("segredo da JIM", brand: "jim", identity: "acc_jim_000001")
      summarize(summary_item(ticket))

      expect(HandoffSummary.find_by!(ticket_id: ticket.id).fields.values.join).not_to include("segredo da JIM")
    end
  end

  describe "RNF-06: tempo desde a escalação, pelo relógio do banco" do
    it "mede ms_since_escalated com o DatabaseClock, não com o relógio do processo" do
      ticket = escalated_ticket
      item = summary_item(ticket, escalated_at: db_now - 2.seconds)

      travel_to(1.hour.from_now) { summarize(item) }

      ms = summary_audits(ticket).sole.data["ms_since_escalated"]
      expect(ms).to be_between(2000, 2000 + 5000)
    end

    it "escalated_at no futuro (relógios diferentes) não dá número negativo" do
      ticket = escalated_ticket
      summarize(summary_item(ticket, escalated_at: db_now + 10.seconds))

      expect(summary_audits(ticket).sole.data["ms_since_escalated"]).to eq(0)
    end
  end

  describe "falha de dependência: Redis fora" do
    it "o item que ninguém acordou não fica obsoleto: a recuperação o reoferece com o caso já humano" do
      ticket = escalated_ticket
      item = travel_to(1.minute.ago) { summary_item(ticket) }

      woken = Outbox::Recover.call

      expect(woken).to include(item.id)
      expect(item.reload.completed_at).to be_nil
      expect(OutboxJob).to have_been_enqueued.with(item.id)
    end
  end
end
