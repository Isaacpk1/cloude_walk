require "rails_helper"

# Prazos do ciclo pendente gravados na ingestão (07, seção 3.4; ADR-016; invariante 1).
RSpec.describe Ingestion::Receive do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }

  def normalized(external_id: SecureRandom.uuid, identity: "acc_ciclo_1", brand: "infinitepay", channel: "chat", text: "oi")
    {
      "schema" => "helpdesk.normalized_message.v1", "channel" => channel, "brand" => brand,
      "provider_account" => "#{brand}-#{channel}-mock", "external_id" => external_id,
      "sender" => { "channel_identity" => identity }, "content" => { "type" => "text", "text" => text },
      "received_at" => "2026-11-18T21:00:00.000Z", "trace_id" => SecureRandom.hex(16)
    }
  end

  def ingest(message = normalized) = described_class.call(message, provider_payload: {})

  def ingest_at(time, message = normalized)
    travel_to(time) { ingest(message) }
  end

  describe "RN-55 / RN-46: a primeira mensagem abre o ciclo pendente" do
    it "grava first_pending_*, o fim da janela do chat e o prazo da IA" do
      ticket = ingest_at(t0).ticket.reload

      expect(ticket).to have_attributes(
        first_pending_seq: 1, first_pending_at: t0, dispatch_due_at: t0 + 1.5.seconds, ai_deadline_at: t0 + 60.seconds
      )
    end

    it "continua gravando o message.received no outbox" do
      result = ingest_at(t0)

      expect(OutboxEvent.where(ticket: result.ticket).pluck(:event_type)).to eq([ "message.received" ])
    end
  end

  describe "Invariante 7: a decisão da janela fica na auditoria" do
    it "RN-55: o message.received auditado traz o ciclo, o fim da janela e o prazo da IA" do
      result = ingest_at(t0)
      ingest_at(t0 + 1.second)

      data = AuditEvent.where(ticket: result.ticket, event_type: "message.received").order(:id).last.data
      expect(data).to include("first_pending_seq" => 1, "dispatch_due_at" => (t0 + 2.5.seconds).iso8601(3),
                              "ai_deadline_at" => (t0 + 60.seconds).iso8601(3))
    end
  end

  describe "RN-55: janela de agrupamento com a primeira mensagem ainda pendente" do
    it "mensagem aos 1 s empurra o fim da janela para 2,5 s, sem mexer no início do ciclo" do
      ingest_at(t0)
      ticket = ingest_at(t0 + 1.second).ticket.reload

      expect(ticket).to have_attributes(
        first_pending_seq: 1, first_pending_at: t0, dispatch_due_at: t0 + 2.5.seconds, ai_deadline_at: t0 + 60.seconds,
        latest_customer_seq: 2
      )
    end

    it "mensagem aos 3 s: o próximo turno fica elegível aos 4 s (teto, tempo no limite)" do
      ingest_at(t0)
      ticket = ingest_at(t0 + 3.seconds).ticket.reload

      expect(ticket.dispatch_due_at).to eq(t0 + 4.seconds)
    end

    it "RN-46: o prazo da IA não reinicia com mensagens novas (ordem)" do
      ingest_at(t0)
      ingest_at(t0 + 3.seconds)
      ticket = ingest_at(t0 + 20.seconds).ticket.reload

      expect(ticket).to have_attributes(first_pending_seq: 1, ai_deadline_at: t0 + 60.seconds, dispatch_due_at: t0 + 20.seconds)
    end

    it "depois de o turno sair (dispatch_due_at zerado), a mensagem seguinte reagenda no mesmo ciclo" do
      ingest_at(t0)
      Ticket.sole.update_columns(dispatch_due_at: nil)

      ticket = ingest_at(t0 + 2.seconds).ticket.reload

      expect(ticket).to have_attributes(first_pending_seq: 1, first_pending_at: t0, dispatch_due_at: t0 + 3.5.seconds)
    end
  end

  describe "RN-55: e-mail tem janela 0" do
    it "dispatch_due_at é o próprio horário da gravação" do
      ticket = ingest_at(t0, normalized(channel: "email", identity: "cliente@example.test")).ticket.reload

      expect(ticket).to have_attributes(first_pending_at: t0, dispatch_due_at: t0, ai_deadline_at: t0 + 60.seconds)
    end
  end

  describe "07, seção 3.3: caso fora da IA não ganha prazos da IA" do
    it "com analista humano, a mensagem não abre ciclo" do
      first = ingest_at(t0)
      first.ticket.update_columns(state: "com_analista", assignee_id: create(:user).id, first_pending_seq: nil,
                                  first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil, progress_due_at: nil)

      ticket = ingest_at(t0 + 1.second).ticket.reload

      expect(ticket).to have_attributes(latest_customer_seq: 2, first_pending_seq: nil, first_pending_at: nil,
                                        dispatch_due_at: nil, ai_deadline_at: nil)
    end

    it "aguardando humano não reagenda a abertura de turno" do
      first = ingest_at(t0)
      first.ticket.update_columns(state: "aguardando_humano", dispatch_due_at: nil)

      ticket = ingest_at(t0 + 1.second).ticket.reload

      expect(ticket.dispatch_due_at).to be_nil
    end

    it "com o bot como responsável, segue com a IA" do
      first = ingest_at(t0)
      first.ticket.update_columns(state: "com_ia", assignee_id: create(:user, :bot).id)

      expect(ingest_at(t0 + 1.second).ticket.reload.dispatch_due_at).to eq(t0 + 2.5.seconds)
    end
  end

  describe "RNF-15: a duplicata não mexe nos prazos (repetição)" do
    it "o mesmo external_id reentregue depois não move dispatch_due_at" do
      message = normalized(external_id: "chat_msg_dup")
      ingest_at(t0, message)

      result = ingest_at(t0 + 1.second, message)

      expect(result).to be_duplicate
      expect(result.ticket.reload).to have_attributes(dispatch_due_at: t0 + 1.5.seconds, first_pending_at: t0)
    end
  end

  describe "RN-01, invariante 6: prazos de uma marca não tocam a outra (marca errada)" do
    it "a mensagem da JIM não move os prazos do atendimento da InfinitePay" do
      ip = ingest_at(t0, normalized(identity: "acc_compartilhada")).ticket
      jim_ticket = ingest_at(t0 + 1.second, normalized(identity: "acc_compartilhada", brand: "jim")).ticket

      expect(ip.reload).to have_attributes(brand: infinitepay, dispatch_due_at: t0 + 1.5.seconds, latest_customer_seq: 1)
      expect(jim_ticket.reload).to have_attributes(brand: jim, first_pending_at: t0 + 1.second,
                                                   dispatch_due_at: t0 + 2.5.seconds)
    end
  end

  describe "invariante 1: prazos na mesma transação da mensagem (falha de dependência)" do
    it "falha no outbox desfaz também os prazos" do
      ingest_at(t0)
      allow(OutboxEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "outbox fora do ar")

      expect { ingest_at(t0 + 1.second) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(Ticket.sole).to have_attributes(latest_customer_seq: 1, dispatch_due_at: t0 + 1.5.seconds)
    end
  end

  describe "RN-55, RF-33: versão do contexto na ingestão (07, seção 3.4)" do
    it "cada mensagem do cliente sobe context_version em 1, na mesma transação" do
      ingest_at(t0)
      expect(Ticket.sole.context_version).to eq(1)

      ingest_at(t0 + 1.second)
      expect(Ticket.sole.context_version).to eq(2)
    end

    it "RNF-15: a duplicata não sobe a versão (repetição)" do
      message = normalized(external_id: "chat_msg_dup_versao")
      ingest_at(t0, message)
      ingest_at(t0 + 1.second, message)

      expect(Ticket.sole.context_version).to eq(1)
    end

    it "caso fora da IA também sobe: a mensagem muda o que a IA veria quando o caso voltar" do
      first = ingest_at(t0)
      first.ticket.update_columns(state: "com_analista", assignee_id: create(:user).id)

      expect(ingest_at(t0 + 1.second).ticket.reload.context_version).to eq(2)
    end

    it "invariante 1: falha no outbox desfaz também a versão (falha de dependência)" do
      ingest_at(t0)
      allow(OutboxEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "outbox fora do ar")

      expect { ingest_at(t0 + 1.second) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(Ticket.sole.context_version).to eq(1)
    end

    it "invariante 6: a mensagem de uma marca não sobe a versão do atendimento da outra (marca errada)" do
      ip = ingest_at(t0, normalized(identity: "acc_versao")).ticket
      ingest_at(t0 + 1.second, normalized(identity: "acc_versao", brand: "jim"))

      expect(ip.reload.context_version).to eq(1)
      expect(Ticket.find_by!(brand: jim).context_version).to eq(1)
    end
  end

  describe "Invariante 7: message.received traz a janela usada, o teto e a versão do contexto" do
    def received_audit(result) = AuditEvent.where(ticket: result.ticket, event_type: "message.received").order(:id).last.data

    it "RN-55: chat registra window_ms 1500, ceiling_at = first_pending_at + 4 s e a versão depois do incremento" do
      ingest_at(t0)
      data = received_audit(ingest_at(t0 + 1.second))

      expect(data).to include("window_ms" => 1500, "ceiling_at" => (t0 + 4.seconds).iso8601(3), "context_version" => 2,
                              "dispatch_due_at" => (t0 + 2.5.seconds).iso8601(3))
    end

    it "RN-55: e-mail registra window_ms 0" do
      data = received_audit(ingest_at(t0, normalized(channel: "email", identity: "cliente@example.test")))

      expect(data).to include("window_ms" => 0, "ceiling_at" => (t0 + 4.seconds).iso8601(3), "context_version" => 1,
                              "dispatch_due_at" => t0.iso8601(3))
    end

    it "07, seção 3.3: caso fora da IA não usa janela; a versão continua registrada" do
      first = ingest_at(t0)
      first.ticket.update_columns(state: "com_analista", assignee_id: create(:user).id, first_pending_seq: nil,
                                  first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil, progress_due_at: nil)

      data = received_audit(ingest_at(t0 + 1.second))

      expect(data).to include("window_ms" => nil, "ceiling_at" => nil, "dispatch_due_at" => nil, "context_version" => 2)
    end
  end
end
