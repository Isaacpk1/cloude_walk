require "rails_helper"

# Bloco 11, "pronto quando" (ROADMAP): ao variar os dados sintéticos do ticket, o caso segue a primeira regra aplicável
# ou cai na fila padrão, e a decisão aparece na auditoria (RF-15, RF-18 + RF-54, RN-16, RN-20). Tudo real: regras
# publicadas pelo RoutingRuleset.publish!, webhook, OutboxJob (message.received) → Triage::Run → Routing::Evaluate,
# e o painel do atendimento.
RSpec.describe "RF-12, RF-15, RF-18, RF-24, RF-54: pronto quando do bloco 11" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let!(:config) { triage_setup(infinitepay) }
  let(:supervisor) { create(:user) }
  let!(:credit) { routing_queue_for(infinitepay, name: "Crédito", ai_first: false) }
  let!(:card_reader) { routing_queue_for(infinitepay, name: "Maquininha", ai_first: true) }
  let(:rules) do
    { "schema_version" => 1, "rules" => [
      { "name" => "Crédito com prioridade alta ou crítica", "queue_id" => credit.id,
        "any" => [ { "all" => [ { "field" => "category", "op" => "eq", "value" => "credito" },
                                { "field" => "priority", "op" => "in", "value" => %w[alta critica] } ] } ] },
      { "name" => "Maquininha ou urgente", "queue_id" => card_reader.id,
        "any" => [ { "all" => [ { "field" => "category", "op" => "eq", "value" => "maquininha" } ] },
                   { "all" => [ { "field" => "tags", "op" => "contains", "value" => "urgente" } ] } ] }
    ] }
  end

  before do
    # `travel` descarta os microssegundos: sem partir de um segundo exato, "2 s depois" pode cair antes do fim da janela.
    freeze_time
    RoutingRuleset.publish!(brand: infinitepay, rules:, default_queue: config[:default], created_by: supervisor)
    stub_broker
    stub_channels(*Array.new(4) { { status: 200, message_id: "chat_out_#{SecureRandom.hex(3)}" } })
    allow(DatabaseClock).to receive(:now) { Time.current }
  end

  def post_chat(text, customer:)
    raw = { message_id: SecureRandom.uuid, account_id: "acc_infinitepay_#{customer}", customer_ref: "cus_ref_#{customer}",
            text:, sent_at: Time.current.utc.iso8601(3) }.to_json
    perform_enqueued_jobs do
      post "/webhooks/chat/infinitepay-chat-mock", params: raw, headers: {
        "CONTENT_TYPE" => "application/json",
        HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret: account.secret)
      }
    end
    expect(response).to have_http_status(:accepted)
    # RN-55: a triagem espera a janela de agrupamento; no fim dela, o scheduler e o Turns::Open triam o caso.
    travel 2.seconds
    perform_enqueued_jobs { Deadlines::DispatchDue.call(now: Time.current, limit: 10).each { OutboxJob.perform_later(_1) } }
    Ticket.order(:id).last
  end

  def decided(ticket) = AuditEvent.where(ticket_id: ticket.id, event_type: "routing.decided").sole

  it "a primeira regra que casa decide (E dentro do grupo, OU entre grupos); sem regra, a fila padrão; tudo auditado" do
    cases = {
      "000101" => [ "meu limite de credito esta bloqueado e nao consigo vender", credit, 0, 0, "aguardando_humano" ],
      "000102" => [ "minha maquininha nao liga", card_reader, 1, 0, "com_ia" ],
      "000103" => [ "duvida sobre o pix, e urgente", card_reader, 1, 1, "com_ia" ],
      "000104" => [ "oi", config[:default], nil, nil, "com_ia" ]
    }

    cases.each do |customer, (text, queue, rule_index, group_index, state)|
      ticket = post_chat(text, customer:)

      expect(ticket).to have_attributes(queue_id: queue.id, state:, ruleset_version: 1), text
      audit = decided(ticket)
      expect(audit.ruleset_version).to eq(1)
      expect(audit.data).to include("rule_index" => rule_index, "group_index" => group_index,
                                    "default" => rule_index.nil?, "queue_name" => queue.current_version.name)

      html = get(conversation_path(ticket.id)) && response.body
      expect(html).to include("conjunto de regras versão 1")
      if rule_index
        expect(html).to include("regra #{rule_index + 1}", "fila #{queue.current_version.name}")
      else
        expect(html).to include("nenhuma regra casou: fila padrão Geral")
      end
    end
  end

  it "RN-18, RN-20: uma versão nova vale para o roteamento seguinte; o caso anterior fica onde estava" do
    first = post_chat("minha maquininha nao liga", customer: "000201")
    RoutingRuleset.publish!(brand: infinitepay, rules: { "schema_version" => 1, "rules" => [] },
                            default_queue: config[:default], created_by: supervisor)

    second = post_chat("minha maquininha nao liga", customer: "000202")

    expect(first.reload).to have_attributes(queue_id: card_reader.id, ruleset_version: 1)
    expect(second).to have_attributes(queue_id: config[:default].id, ruleset_version: 2)
    expect(decided(second).data).to include("default" => true, "ruleset_version" => 2)
  end
end
