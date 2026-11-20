require "rails_helper"

# Invariante 8: as regras da ingestão vivem no banco (07, seção 4, "Índices e restrições").
# Cada teste grava por SQL (insert_all!/update_all), pulando as validações do model.
RSpec.describe "Invariante 8: restrições da ingestão garantidas pelo banco" do
  let(:infinitepay) { create(:brand, :infinitepay) }
  let(:jim) { create(:brand, :jim) }
  let(:customer) { create(:customer, brand: infinitepay) }
  let(:now) { Time.current }

  def insert_ticket(**attrs)
    row = { brand_id: infinitepay.id, customer_id: customer.id, channel: "chat", state: "novo",
            created_at: now, updated_at: now }.merge(attrs)
    Ticket.insert_all!([ row ], returning: :id).rows.first.first
  end

  def insert_message(ticket_id:, **attrs)
    row = { brand_id: infinitepay.id, ticket_id:, provider_account: "infinitepay-chat-mock", channel: "chat",
            direction: "inbound", author_type: "customer", body: "oi", external_id: SecureRandom.uuid, seq: 1,
            trace_id: SecureRandom.hex(16), received_at: now, created_at: now }.merge(attrs)
    Message.insert_all!([ row ])
  end

  describe "RN-03: no máximo um atendimento aberto por cliente e canal" do
    it "recusa o segundo atendimento aberto no mesmo canal" do
      insert_ticket

      expect { insert_ticket }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "aceita um novo atendimento quando o anterior está fechado (RN-09)" do
      insert_ticket(state: "fechado")

      expect { insert_ticket }.not_to raise_error
    end

    it "aceita atendimentos abertos em canais diferentes (RN-04)" do
      insert_ticket(channel: "chat")

      expect { insert_ticket(channel: "whatsapp") }.not_to raise_error
    end
  end

  describe "RF-09: estado fora do ciclo de vida" do
    it "o banco recusa" do
      expect { insert_ticket(state: "inventado") }.to raise_error(ActiveRecord::StatementInvalid, /tickets_state_check/)
    end
  end

  describe "ADR-014: atendimento de cliente de outra marca (marca errada)" do
    it "o banco recusa" do
      expect { insert_ticket(brand_id: jim.id) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "RNF-15: o mesmo webhook vira uma mensagem só" do
    let(:ticket_id) { insert_ticket }

    it "recusa a mesma (marca, conta, canal, external_id)" do
      insert_message(ticket_id:, external_id: "chat_msg_1", seq: 1)

      expect { insert_message(ticket_id:, external_id: "chat_msg_1", seq: 2) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "aceita o mesmo external_id vindo de outra conta do provedor" do
      insert_message(ticket_id:, external_id: "chat_msg_1", seq: 1)

      expect { insert_message(ticket_id:, external_id: "chat_msg_1", seq: 2, provider_account: "outra-conta") }.not_to raise_error
    end
  end

  describe "07, seção 4: seq único por atendimento" do
    it "recusa duas mensagens com o mesmo seq" do
      ticket_id = insert_ticket
      insert_message(ticket_id:, seq: 1)

      expect { insert_message(ticket_id:, seq: 1) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "ADR-014: mensagem com marca diferente da do atendimento (marca errada)" do
    it "o banco recusa" do
      ticket_id = insert_ticket

      expect { insert_message(ticket_id:, brand_id: jim.id) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "RN-54: auditoria só de inserção" do
    let!(:audit) do
      AuditEvent.create!(brand: infinitepay, event_type: "message.received", actor_type: "customer",
                         trace_id: SecureRandom.hex(16), data: {})
    end

    it "recusa UPDATE por SQL" do
      expect { AuditEvent.where(id: audit.id).update_all(event_type: "editado") }
        .to raise_error(ActiveRecord::StatementInvalid, /imutável/)
    end

    it "recusa DELETE por SQL" do
      expect { AuditEvent.where(id: audit.id).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /imutável/)
    end
  end

  describe "ADR-016: dedup_key do outbox é única quando preenchida" do
    def insert_outbox(dedup_key)
      OutboxEvent.insert_all!([ { id: SecureRandom.uuid, brand_id: infinitepay.id, event_type: "x", dedup_key:,
                                  payload: {}, trace_id: SecureRandom.hex(16), next_attempt_at: now, created_at: now } ])
    end

    it "recusa a mesma chave duas vezes" do
      insert_outbox("turn_open:1:1:1")

      expect { insert_outbox("turn_open:1:1:1") }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "aceita vários itens sem chave" do
      insert_outbox(nil)

      expect { insert_outbox(nil) }.not_to raise_error
    end
  end
end
