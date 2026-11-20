require "rails_helper"

RSpec.describe Ingestion::Receive do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }

  def normalized(text: "meu repasse não caiu", external_id: SecureRandom.uuid, identity: "acc_infinitepay_000021",
                 brand: "infinitepay", channel: "chat", provider_account: "#{brand}-#{channel}-mock", trace_id: SecureRandom.hex(16))
    {
      "schema" => "helpdesk.normalized_message.v1", "channel" => channel, "brand" => brand,
      "provider_account" => provider_account, "external_id" => external_id,
      "sender" => { "channel_identity" => identity }, "content" => { "type" => "text", "text" => text },
      "received_at" => "2026-11-18T21:00:00.120Z", "trace_id" => trace_id
    }
  end

  def ingest(message = normalized, provider_payload: { "raw" => true }) = described_class.call(message, provider_payload:)

  describe "RF-08 / RN-03: primeira mensagem de um cliente" do
    it "cria o atendimento em novo com a mensagem seq 1" do
      result = ingest

      expect(result).to be_created
      expect(result.ticket).to have_attributes(state: "novo", channel: "chat", brand: infinitepay, latest_customer_seq: 1)
      expect(result.message).to have_attributes(seq: 1, direction: "inbound", author_type: "customer",
                                                author_id: result.ticket.customer_id, body: "meu repasse não caiu")
    end

    it "guarda conta, ID externo, trace, horário de recebimento e o webhook cru (07, seção 4)" do
      message = normalized(external_id: "chat_msg_1", trace_id: "4bf92f3577b34da6a3ce929d0e0e4736")

      result = ingest(message, provider_payload: { "message_id" => "chat_msg_1" })

      expect(result.message).to have_attributes(
        provider_account: "infinitepay-chat-mock", channel: "chat", external_id: "chat_msg_1",
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", received_at: Time.utc(2026, 11, 18, 21, 0, 0.12r),
        provider_payload: { "message_id" => "chat_msg_1" }
      )
    end
  end

  describe "RF-07 / RN-02 / RN-05: identificação do cliente" do
    it "remetente desconhecido vira cliente não verificado com a identidade do canal" do
      customer = ingest(normalized(identity: "acc_novo_1")).ticket.customer

      expect(customer).to have_attributes(brand: infinitepay, verified: false)
      expect(customer.identities.map { [ _1.channel, _1.external_id ] }).to eq([ [ "chat", "acc_novo_1" ] ])
    end

    it "identificador conhecido usa o cliente existente" do
      known = create(:customer, brand: infinitepay, verified: true, display_name: "Lojista conhecido")
      create(:customer_identity, customer: known, channel: "chat", external_id: "acc_conhecido")

      expect(ingest(normalized(identity: "acc_conhecido")).ticket.customer).to eq(known)
    end

    it "RN-01: o mesmo identificador em outra marca é outro cliente (marca errada)" do
      ip = ingest(normalized(identity: "acc_compartilhada")).ticket.customer
      jim_customer = ingest(normalized(identity: "acc_compartilhada", brand: "jim")).ticket.customer

      expect(jim_customer).not_to eq(ip)
      expect(jim_customer.brand).to eq(jim)
    end
  end

  describe "RF-08 / RN-03: mensagem de cliente com atendimento aberto" do
    it "entra no mesmo atendimento com o próximo seq" do
      first = ingest
      second = ingest(normalized(text: "é o de ontem, R$ 1.200"))

      expect(second.ticket).to eq(first.ticket)
      expect(second.message.seq).to eq(2)
      expect(second.ticket.reload.latest_customer_seq).to eq(2)
    end
  end

  describe "RN-04: atendimento aberto em outro canal" do
    it "abre outro atendimento, vinculado ao aberto" do
      whatsapp = ingest(normalized(channel: "whatsapp", identity: "acc_1")).ticket
      identity = whatsapp.customer.identities.first
      create(:customer_identity, customer: whatsapp.customer, channel: "chat", external_id: "acc_chat_1")

      chat = ingest(normalized(identity: "acc_chat_1")).ticket

      expect(chat).not_to eq(whatsapp)
      expect(chat).to have_attributes(customer_id: identity.customer_id, linked_ticket: whatsapp, latest_customer_seq: 1)
    end
  end

  describe "RN-09: atendimento fechado" do
    it "abre um novo atendimento, vinculado ao anterior" do
      closed = ingest.ticket
      closed.update!(state: "fechado")

      reopened = ingest.ticket

      expect(reopened).not_to eq(closed)
      expect(reopened).to have_attributes(state: "novo", linked_ticket: closed)
      expect(reopened.messages.pluck(:seq)).to eq([ 1 ])
    end
  end

  describe "RNF-15 / RN-47: o provedor reentrega o mesmo webhook (repetição)" do
    it "preserva uma única mensagem, sem nova auditoria nem novo outbox" do
      first = ingest(normalized(external_id: "chat_msg_1"))

      expect { @again = ingest(normalized(external_id: "chat_msg_1", text: "outro texto")) }
        .not_to(change { [ Message.count, AuditEvent.count, OutboxEvent.count, Ticket.count ] })
      expect(@again).to be_duplicate
      expect(@again.message).to eq(first.message)
      expect(first.ticket.reload.latest_customer_seq).to eq(1)
    end

    it "aceita o mesmo external_id vindo de outra conta do provedor" do
      ingest(normalized(external_id: "chat_msg_1"))

      expect(ingest(normalized(external_id: "chat_msg_1", provider_account: "infinitepay-chat-app-2"))).to be_created
    end

    it "aceita o mesmo external_id vindo de outra marca (marca errada)" do
      ingest(normalized(external_id: "chat_msg_1"))

      result = ingest(normalized(external_id: "chat_msg_1", brand: "jim"))

      expect(result).to be_created
      expect(result.message.brand).to eq(jim)
    end
  end

  describe "RF-54 / RN-54: auditoria da ingestão" do
    it "registra a criação do atendimento e o recebimento da mensagem com o trace" do
      result = ingest(normalized(trace_id: "4bf92f3577b34da6a3ce929d0e0e4736"))

      expect(result.ticket.audit_events.map(&:event_type)).to eq(%w[ticket.created message.received])
      expect(result.ticket.audit_events).to all(have_attributes(
        brand_id: infinitepay.id, actor_type: "customer", actor_id: result.ticket.customer_id,
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736"
      ))
      expect(result.ticket.audit_events.last.data).to include(
        "message_id" => result.message.id, "seq" => 1, "channel" => "chat", "provider_account" => "infinitepay-chat-mock"
      )
    end

    it "mensagem em atendimento aberto só registra o recebimento" do
      ticket = ingest.ticket

      expect { ingest }.to change { ticket.audit_events.count }.by(1)
      expect(ticket.audit_events.last.event_type).to eq("message.received")
    end
  end

  describe "RNF-14 / invariante 2: outbox na mesma transação" do
    it "grava um item aberto com o event_id para o worker" do
      result = ingest(normalized(trace_id: "4bf92f3577b34da6a3ce929d0e0e4736"))

      item = OutboxEvent.sole
      expect(item).to have_attributes(
        brand_id: infinitepay.id, ticket_id: result.ticket.id, event_type: "message.received",
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", published_at: nil, completed_at: nil
      )
      expect(item.id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(item.payload).to eq("ticket_id" => result.ticket.id, "message_id" => result.message.id, "seq" => 1)
      expect(item.next_attempt_at).to be <= Time.current
    end

    it "falha no outbox desfaz cliente, atendimento, mensagem e auditoria (falha)" do
      allow(OutboxEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "outbox fora do ar")

      expect { ingest }.to raise_error(ActiveRecord::StatementInvalid)
      expect([ Customer.count, Ticket.count, Message.count, AuditEvent.count ]).to eq([ 0, 0, 0, 0 ])
    end
  end

  describe "invariante 10: a entrada precisa estar no contrato" do
    it "recusa mensagem normalizada inválida sem gravar nada" do
      expect { ingest(normalized.except("trace_id")) }.to raise_error(HelpdeskContracts::InvalidPayload)
      expect(Message.count).to eq(0)
    end
  end
end
