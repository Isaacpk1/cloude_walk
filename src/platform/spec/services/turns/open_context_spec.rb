require "rails_helper"

RSpec.describe Turns::Open, "RN-49, RF-33, RF-53: contexto do turno completo e verificável (07, seção 3.4)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "pt-BR") }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  def open_for(received) = described_class.call(due_dispatch(received).id)
  def event_payload(turn) = OutboxEvent.find(turn.event_id).payload
  def last_audit(ticket) = ticket.audit_events.reload.last
  def digest(context) = Turns::ContextDigest.call(context)

  # Saída visível ao cliente com o próximo seq, como o AgentActions::Apply grava.
  def bot_reply(ticket, text)
    seq = Message.where(ticket_id: ticket.id).maximum(:seq).to_i + 1
    Message.create!(brand_id: ticket.brand_id, ticket:, direction: "outbound", author_type: "bot", body: text, seq:,
                    channel: ticket.channel, provider_account: "#{ticket.brand.slug}-chat-mock",
                    trace_id: SecureRandom.hex(16), received_at: Time.current)
  end

  # O turno lê a política congelada no atendimento (Policy.for_ticket); `for` cobre quem ainda lê a da marca.
  def policy_with(**limits)
    policy = Turns::Policy::DEFAULT.with(**limits)
    allow(Turns::Policy).to receive(:for).and_return(policy)
    allow(Turns::Policy).to receive(:for_ticket).and_return(policy)
  end

  describe "pronto quando: o turno persistido corresponde ao contexto enviado" do
    it "RN-49: grava context_version do atendimento e o digest do context do evento no outbox" do
      received = ingest("meu repasse não caiu")
      received.ticket.update_columns(context_version: 7)

      turn = open_for(received).turn.reload

      context = event_payload(turn)["context"]
      expect(turn.context_version).to eq(7)
      expect(turn.context).to eq(context)
      expect(turn.context_digest).to eq(digest(context))
      expect(turn.context_digest).to eq(digest(turn.context))
    end

    it "RN-55, RN-49: rajada de 3 mensagens abre um turno com as 3 pendentes, e o digest confere" do
      ingest("meu repasse não caiu")
      travel 0.5.seconds
      ingest("é o de ontem")
      travel 0.5.seconds
      third = ingest("R$ 1.200")

      turn = open_for(third).turn

      context = event_payload(turn)["context"]
      expect(context["pending_messages"]).to eq([ { "seq" => 1, "text" => "meu repasse não caiu" },
                                                  { "seq" => 2, "text" => "é o de ontem" },
                                                  { "seq" => 3, "text" => "R$ 1.200" } ])
      expect(AiTurn.sole.context_digest).to eq(digest(context))
      expect(HelpdeskContracts.errors(:agent_inbound, event_payload(turn))).to be_empty
    end

    it "RF-54: a auditoria ai_turn.opened traz versão, digest, seqs, janela do canal, canal e tamanhos" do
      ingest("meu repasse")
      first_ticket = Ticket.sole
      bot_reply(first_ticket, "Qual repasse?")
      received = ingest("o de ontem")
      received.ticket.reload.update_columns(context_version: 3)

      turn = open_for(received).turn

      audit = received.ticket.audit_events.find_by!(event_type: "ai_turn.opened")
      expect(audit.data).to include("context_version" => 3, "context_digest" => turn.context_digest,
                                    "pending_seqs" => [ 3 ], "history_seqs" => [ 1, 2 ], "window_ms" => 1500,
                                    "channel" => "chat", "pending_chars" => 10, "context_chars" => 10 + 11 + 13)
    end

    it "RN-56, ordem: mensagem gravada depois da abertura supera o turno, e o turno guarda o contexto que saiu" do
      received = ingest("meu repasse não caiu")
      turn = open_for(received).turn
      sent = event_payload(turn)["context"]

      ingest("é o de ontem")

      expect(turn.reload).to have_attributes(status: "superseded", context: sent, context_digest: digest(sent))
      expect(sent["pending_messages"].pluck("seq")).to eq([ 1 ])
    end

    it "repetição: reprocessar a ação não grava outro turno nem muda o digest gravado" do
      item = due_dispatch(ingest)
      turn = described_class.call(item.id).turn

      described_class.call(item.id)

      expect(AiTurn.sole.context_digest).to eq(turn.context_digest)
      expect(OutboxEvent.where(event_type: "agent.event").sole.payload["context"]).to eq(AiTurn.sole.context)
    end
  end

  describe "RN-49: histórico até 20 mensagens e dentro do limite do contexto inteiro" do
    it "sem resumo, histórico + pendentes são contíguos do seq mais antigo incluído até a última mensagem" do
      received = nil
      12.times do |i|
        received = ingest("pergunta #{i}")
        bot_reply(received.ticket, "resposta #{i}")
      end
      ingest("mais uma")
      received = ingest("e outra")

      context = event_payload(open_for(received).turn)["context"]

      history = context["history"].pluck("seq")
      pending = context["pending_messages"].pluck("seq")
      expect(context).not_to have_key("summary")
      expect(history.size).to eq(20)
      expect(pending).to eq([ 25, 26 ])
      expect(history + pending).to eq((history.first..26).to_a)
      expect(history.first).to eq(5)
    end

    it "corta as mais antigas até o contexto inteiro caber; no limite exato a mais antiga fica" do
      policy_with(context_chars_limit: 5 + 10 + 10)
      received = ingest("abcde") # 5, seq 1
      bot_reply(received.ticket, "0123456789") # seq 2
      ingest("0123456789") # seq 3
      bot_reply(received.ticket, "0123456789") # seq 4
      received = ingest("pend!") # 5, seq 5

      context = event_payload(open_for(received).turn)["context"]

      expect(context["history"].pluck("seq")).to eq([ 3, 4 ])
      expect(context["pending_messages"].pluck("seq")).to eq([ 5 ])
      expect(last_audit(received.ticket).data).to include("history_seqs" => [ 3, 4 ], "context_chars" => 25)
    end

    it "um caractere acima do limite derruba a mais antiga do histórico, mantendo a contiguidade" do
      policy_with(context_chars_limit: 5 + 10 + 10 - 1)
      received = ingest("abcde")
      bot_reply(received.ticket, "0123456789")
      ingest("0123456789")
      bot_reply(received.ticket, "0123456789")
      received = ingest("pend!")

      context = event_payload(open_for(received).turn)["context"]

      expect(context["history"].pluck("seq")).to eq([ 4 ])
      expect(context["history"].pluck("seq") + context["pending_messages"].pluck("seq")).to eq([ 4, 5 ])
    end
  end

  describe "RN-49: pendentes acima do limite não abrem o turno (handoff no bloco 10)" do
    it "no limite exato (16 000 caracteres somados) o turno abre com as pendentes por inteiro" do
      ingest("a" * 8_000)
      received = ingest("b" * 8_000)

      result = open_for(received)

      expect(result.status).to eq(:opened)
      expect(event_payload(result.turn).dig("context", "pending_messages").sum { _1["text"].size }).to eq(16_000)
    end

    it "um caractere acima não abre: ai_turn.not_opened com contexto_excede_limite, item concluído, nada sai" do
      ingest("a" * 8_000)
      received = ingest("b" * 8_001)
      item = due_dispatch(received)

      result = described_class.call(item.id)

      expect(result.status).to eq(:context_too_large)
      expect(AiTurn.count).to eq(0)
      expect(OutboxEvent.where(event_type: "agent.event")).to be_empty
      expect(item.reload.completed_at).to eq(Time.current)
      expect(last_audit(received.ticket)).to have_attributes(event_type: "ai_turn.not_opened", trace_id: item.trace_id)
      expect(last_audit(received.ticket).data).to include("reason" => "contexto_excede_limite", "pending_chars" => 16_001,
                                                          "limit" => 16_000, "pending_seqs" => [ 1, 2 ])
    end

    it "recusa terminal: zera dispatch_due_at na mesma transação e mantém o ciclo (handoff e timeout nos blocos 08/10)" do
      ingest("a" * 8_000)
      received = ingest("b" * 8_001)
      ticket = received.ticket.reload
      cycle = ticket.slice(:first_pending_seq, :first_pending_at, :ai_deadline_at)

      expect(described_class.call(due_dispatch(received).id).status).to eq(:context_too_large)

      expect(ticket.reload.dispatch_due_at).to be_nil
      expect(ticket.slice(*cycle.keys)).to eq(cycle)
      expect(Deadlines::DispatchDue.call(now: Time.current + 30.seconds, limit: 10)).to be_empty
    end

    it "mensagem nova do cliente com o handoff já pedido pela recusa: nenhum turno é tentado (handoff_pedido)" do
      ingest("a" * 8_000)
      first_refusal = described_class.call(due_dispatch(ingest("b" * 8_001)).id)
      expect(first_refusal.status).to eq(:context_too_large)

      travel 10.seconds
      received = ingest("alguém?")
      expect(received.ticket.reload.dispatch_due_at).to be_present

      ids = Deadlines::DispatchDue.call(now: Time.current, limit: 10)
      expect(ids.size).to eq(1)
      expect(described_class.call(ids.sole).status).to eq(:handoff_requested)
      expect(received.ticket.reload.dispatch_due_at).to be_nil
      expect(received.ticket.audit_events.where(event_type: "ai_turn.not_opened").order(:id).pluck(Arel.sql("data->>'reason'")))
        .to eq(%w[contexto_excede_limite handoff_pedido])
      expect(received.ticket.ai_turns).to be_empty
    end
  end

  describe "RF-53, RN-49: atendimentos anteriores do mesmo cliente, na mesma marca, nos últimos 90 dias" do
    let(:received) { ingest("de novo o repasse", identity: "acc_compartilhada") }
    let(:customer) { received.ticket.customer }

    def past_ticket(created_at, brand: infinitepay, customer: self.customer, channel: "whatsapp", category: nil)
      Ticket.create!(brand:, customer:, channel:, state: "fechado", category:, created_at:, updated_at: created_at)
    end

    def previous(turn) = event_payload(turn).dig("context", "previous_tickets")

    it "leva os 3 mais recentes, do mais recente ao mais antigo, só com dados gravados" do
      customer
      past = [ 1.day, 10.days, 30.days, 60.days ].map { past_ticket(start - _1, category: "repasses") }
      past_ticket(start - 91.days)
      # Marca errada: a mesma conta do canal na JIM é outro cliente (a FK composta impede cliente de outra marca).
      jim_ticket = ingest("oi", brand: "jim", identity: "acc_compartilhada").ticket
      jim_ticket.update_columns(state: "fechado", created_at: start - 1.hour)
      past_ticket(start - 1.hour, customer: create(:customer, brand: infinitepay))

      turn = open_for(received).turn

      expect(previous(turn).pluck("id")).to eq(past.first(3).map { "tkt_#{_1.id}" })
      expect(previous(turn).first).to eq(
        "id" => "tkt_#{past.first.id}",
        "summary" => "Sem resumo gravado. Canal: whatsapp. Aberto em 2026-11-17. Estado: fechado. Categoria: repasses."
      )
      expect(HelpdeskContracts.errors(:agent_inbound, event_payload(turn))).to be_empty
      expect(turn.context_digest).to eq(digest(event_payload(turn)["context"]))
    end

    it "tempo no limite: exatamente 90 dias entra; um instante depois não" do
      customer
      at_limit = past_ticket(start - 90.days)
      past_ticket(start - 90.days - 1.second, channel: "email")

      turn = open_for(received).turn

      expect(previous(turn).pluck("id")).to eq([ "tkt_#{at_limit.id}" ])
    end

    it "não inclui o próprio atendimento e omite o campo quando não há anterior" do
      turn = open_for(received).turn

      expect(event_payload(turn)["context"]).not_to have_key("previous_tickets")
    end
  end

  describe "concorrência: mensagem nova gravada enquanto o turno abre", :concurrency do
    it "o turno cobre a mensagem ou fica superado; o digest sempre corresponde ao conteúdo gravado" do
      first = ingest("meu repasse não caiu")
      item_id = due_dispatch(first).id

      results = run_concurrently(threads: 2) do |i|
        i.zero? ? described_class.call(item_id) : ingest("é o de ontem")
      end

      expect(results).to all(satisfy { !_1.is_a?(StandardError) })
      turn = AiTurn.sole
      ticket = first.ticket.reload
      context = event_payload(turn)["context"]
      expect(turn.context_digest).to eq(digest(context))
      expect(turn.context).to eq(context)
      stored = Message.where(ticket_id: ticket.id, seq: context["pending_messages"].pluck("seq")).order(:seq)
      expect(context["pending_messages"]).to eq(stored.map { { "seq" => _1.seq, "text" => _1.body } })
      if turn.context_until_seq == ticket.latest_customer_seq
        expect(context["pending_messages"].pluck("seq")).to eq([ 1, 2 ])
        expect(turn.status).to eq("eligible")
      else
        expect(context["pending_messages"].pluck("seq")).to eq([ 1 ])
        expect(turn.status).to eq("superseded")
      end
    end
  end
end
