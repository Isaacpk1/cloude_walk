require "rails_helper"

# Bloco 06: a janela de agrupamento por canal, ponta a ponta com as peças reais (RN-55, RN-56, RN-46;
# 06, parâmetros, "Janela de agrupamento de mensagens"; 07, seção 3.4, "Regras de tempo"; ADR-016, ADR-020).
#
# Ingestion::Receive grava a mensagem normalizada (contrato normalized_message, como os adaptadores de
# WhatsApp e e-mail do bloco 15 vão entregar), Deadlines::DispatchDue faz a volta do scheduler e
# Turns::Open abre o turno pelo item do outbox. O relógio anda com travel_to(with_usec: true): o
# travel_to comum corta os microssegundos e esconderia o "um instante antes".
RSpec.describe "RN-55: janela de agrupamento por canal, da ingestão ao turno" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 21, 13, 40, 0) }
  let(:instant) { Rational(1, 1_000_000) } # 1 µs, a precisão do Postgres

  # Identidades no formato de cada canal (fixtures válidas de normalized_message).
  let(:identities) do
    { "chat" => "acc_infinitepay_000021", "whatsapp" => "+5511900000021", "email" => "loja.exemplo@example.com" }
  end

  def normalized(channel, text, brand: "infinitepay")
    {
      "schema" => "helpdesk.normalized_message.v1", "channel" => channel, "brand" => brand,
      "provider_account" => "#{brand}-#{channel}-mock", "external_id" => "#{channel}-#{SecureRandom.uuid}",
      "sender" => { "channel_identity" => identities.fetch(channel) },
      "content" => { "type" => "text", "text" => text },
      "received_at" => Time.current.utc.iso8601(3), "trace_id" => SecureRandom.hex(16)
    }
  end

  def ingest_at(at, channel, text = "mensagem", **)
    travel_to(at, with_usec: true) { Ingestion::Receive.call(normalized(channel, text, **), provider_payload: {}) }
  end

  # Uma volta do scheduler e o worker abrindo os turnos registrados, no mesmo instante.
  def tick_at(at)
    travel_to(at, with_usec: true) do
      ids = Deadlines::DispatchDue.call(now: Time.current, limit: 100)
      ids.map { Turns::Open.call(_1) }
    end
  end

  def pending_seqs(turn) = turn.context.fetch("pending_messages").map { _1["seq"] }

  %w[chat whatsapp].each do |channel|
    describe "RN-55: #{channel} (janela de 1,5 s, teto de 4 s)" do
      it "uma mensagem: o turno sai aos 1,5 s, não um instante antes (tempo no limite)" do
        ticket = ingest_at(t0, channel).ticket
        expect(ticket.reload.dispatch_due_at).to eq(t0 + 1.5.seconds)

        expect(tick_at(t0 + 1.5.seconds - instant)).to be_empty
        opened = tick_at(t0 + 1.5.seconds)

        expect(opened.map(&:status)).to eq([ :opened ])
        turn = opened.sole.turn
        expect(turn).to have_attributes(turn: 1, context_until_seq: 1, status: "eligible")
        expect(pending_seqs(turn)).to eq([ 1 ])
        expect(ticket.reload.dispatch_due_at).to be_nil
        expect(AuditEvent.find_by!(event_type: "turn.dispatch_scheduled").data["delay_ms"]).to eq(0)
      end

      it "rajada que reinicia a janela: mensagens aos 0 s e 1 s saem juntas aos 2,5 s (ordem)" do
        ingest_at(t0, channel, "meu repasse não caiu")
        ticket = ingest_at(t0 + 1.second, channel, "é o de ontem").ticket
        expect(ticket.reload.dispatch_due_at).to eq(t0 + 2.5.seconds)

        expect(tick_at(t0 + 1.5.seconds)).to be_empty # o fim da janela da 1ª mensagem já não vale
        expect(tick_at(t0 + 2.5.seconds - instant)).to be_empty
        turn = tick_at(t0 + 2.5.seconds).sole.turn

        expect(turn.context_until_seq).to eq(2)
        expect(turn.context["pending_messages"]).to eq([ { "seq" => 1, "text" => "meu repasse não caiu" },
                                                        { "seq" => 2, "text" => "é o de ontem" } ])
        expect(AiTurn.count).to eq(1)
      end

      it "rajada longa: o teto de 4 s desde a primeira pendente vence a janela da última" do
        [ 0, 1, 2, 3 ].each { |s| ingest_at(t0 + s.seconds, channel, "msg #{s}") }
        expect(Ticket.sole.dispatch_due_at).to eq(t0 + 4.seconds) # sem o teto seria 4,5 s

        expect(tick_at(t0 + 4.seconds - instant)).to be_empty
        turn = tick_at(t0 + 4.seconds).sole.turn

        expect(turn.context_until_seq).to eq(4)
        expect(pending_seqs(turn)).to eq([ 1, 2, 3, 4 ])
      end

      it "o exemplo da RN-55: a mensagem 2 aos 3 s com a 1 pendente deixa o turno elegível aos 4 s" do
        ingest_at(t0, channel)
        ingest_at(t0 + 3.seconds, channel) # sem volta do scheduler no meio (a corrida com o turno 1 está abaixo)

        expect(Ticket.sole.dispatch_due_at).to eq(t0 + 4.seconds)
        expect(tick_at(t0 + 4.seconds - instant)).to be_empty
        expect(pending_seqs(tick_at(t0 + 4.seconds).sole.turn)).to eq([ 1, 2 ])
      end

      it "RN-56: a corrida — turno 1 aos 1,5 s, mensagem 2 aos 3 s supera o turno 1, turno 2 aos 4 s com [1, 2]" do
        ticket = ingest_at(t0, channel, "meu repasse não caiu").ticket
        turn1 = tick_at(t0 + 1.5.seconds).sole.turn
        expect(turn1).to have_attributes(turn: 1, context_until_seq: 1, status: "eligible")

        ingest_at(t0 + 3.seconds, channel, "é o de ontem, R$ 1.200")

        expect(turn1.reload.status).to eq("superseded")
        expect(AuditEvent.find_by!(event_type: "ai_turn.superseded").data).to include("turns" => [ 1 ], "by_seq" => 2)
        expect(ticket.reload).to have_attributes(first_pending_seq: 1, first_pending_at: t0, dispatch_due_at: t0 + 4.seconds,
                                                 context_version: 2)

        expect(tick_at(t0 + 4.seconds - instant)).to be_empty
        turn2 = tick_at(t0 + 4.seconds).sole.turn

        expect(turn2).to have_attributes(turn: 2, context_until_seq: 2, status: "eligible")
        expect(pending_seqs(turn2)).to eq([ 1, 2 ])
      end
    end
  end

  describe "RN-55: e-mail (janela 0)" do
    it "dispatch_due_at é a hora da gravação e o turno sai na volta seguinte do scheduler (até 250 ms)" do
      result = ingest_at(t0, "email")
      expect(result.ticket.reload.dispatch_due_at).to eq(t0)
      expect(AuditEvent.find_by!(event_type: "message.received").data).to include("window_ms" => 0)

      expect(tick_at(t0 - instant)).to be_empty
      emitted = travel_to(t0 + Deadlines::Loop::DEFAULT_INTERVAL.seconds, with_usec: true) { Deadlines::Loop.new.tick }
      expect(emitted).to eq(1)

      item = OutboxEvent.find_by!(event_type: Deadlines::DispatchDue::EVENT_TYPE)
      turn = travel_to(t0 + 0.25.seconds, with_usec: true) { Turns::Open.call(item.id) }.turn
      expect(turn).to have_attributes(context_until_seq: 1)
      expect(AuditEvent.find_by!(event_type: "turn.dispatch_scheduled").data["delay_ms"]).to eq(250)
    end

    it "no limite exato: a volta no instante da gravação já registra a abertura" do
      ingest_at(t0, "email")

      expect(pending_seqs(tick_at(t0).sole.turn)).to eq([ 1 ])
    end

    it "mensagens gravadas antes da mesma volta saem juntas num turno só" do
      ingest_at(t0, "email", "Assunto: repasse")
      ingest_at(t0 + 0.1.seconds, "email", "Esqueci: é o de ontem")

      turn = tick_at(t0 + 0.25.seconds).sole.turn

      expect(turn.context_until_seq).to eq(2)
      expect(pending_seqs(turn)).to eq([ 1, 2 ])
    end

    it "RN-56: e-mail depois do turno aberto supera o turno e o seguinte sai na volta seguinte com [1, 2]" do
      ingest_at(t0, "email")
      turn1 = tick_at(t0 + 0.25.seconds).sole.turn

      ingest_at(t0 + 3.seconds, "email")
      expect(turn1.reload.status).to eq("superseded")
      expect(Ticket.sole.dispatch_due_at).to eq(t0 + 3.seconds)

      turn2 = tick_at(t0 + 3.25.seconds).sole.turn
      expect(turn2).to have_attributes(turn: 2, context_until_seq: 2)
      expect(pending_seqs(turn2)).to eq([ 1, 2 ])
    end

    it "o teto de 4 s não atrasa nem adianta: depois dele o turno sai na hora da gravação (nunca antes)" do
      ingest_at(t0, "email")
      tick_at(t0) # turno 1
      ingest_at(t0 + 5.seconds, "email")

      expect(Ticket.sole.dispatch_due_at).to eq(t0 + 5.seconds)
      expect(tick_at(t0 + 5.seconds - instant)).to be_empty
      expect(pending_seqs(tick_at(t0 + 5.seconds).sole.turn)).to eq([ 1, 2 ])
    end
  end

  describe "ADR-020: a janela vem da Turns::Policy da marca" do
    def policy_for_jim(policy)
      allow(Turns::Policy).to receive(:for).and_wrap_original do |original, brand|
        brand.slug == "jim" ? policy : original.call(brand)
      end
    end

    it "uma marca com janela própria não muda a da outra (marca errada)" do
      policy_for_jim(Turns::Policy::DEFAULT.with(windows: Turns::Policy::DEFAULT.windows.merge("chat" => 3.seconds),
                                                 ceiling: 5.seconds))

      ip = ingest_at(t0, "chat").ticket
      jim_ticket = ingest_at(t0, "chat", brand: "jim").ticket

      expect(ip.reload.dispatch_due_at).to eq(t0 + 1.5.seconds)
      expect(jim_ticket.reload.dispatch_due_at).to eq(t0 + 3.seconds)
      expect(AuditEvent.where(ticket: jim_ticket, event_type: "message.received").sole.data)
        .to include("window_ms" => 3000, "ceiling_at" => (t0 + 5.seconds).iso8601(3))

      expect(tick_at(t0 + 1.5.seconds).map { _1.turn.ticket_id }).to eq([ ip.id ])
      expect(tick_at(t0 + 3.seconds).map { _1.turn.ticket_id }).to eq([ jim_ticket.id ])
    end

    it "canal sem janela na política é erro explícito e nada é gravado (falha de dependência)" do
      policy_for_jim(Turns::Policy::DEFAULT.with(windows: Turns::Policy::DEFAULT.windows.except("whatsapp")))

      expect { ingest_at(t0, "whatsapp", brand: "jim") }.to raise_error(KeyError, /whatsapp/)
      expect([ Ticket.count, Message.count, OutboxEvent.count, AuditEvent.count ]).to eq([ 0, 0, 0, 0 ])
    end
  end

  describe "RN-55, RF-33: a versão do contexto do turno acompanha as gravações (07, seção 3.4)" do
    # A ação do agente é julgada pelo relógio do banco, que não anda com o travel_to: o cenário começa agora.
    let(:t0) { Time.current.utc.change(usec: 0) }

    def apply(turn, text)
      AgentActions::Apply.call(agent_action_for(turn, reply: { "text" => text }), traceparent: AgentActionHelpers::TRACEPARENT)
    end

    it "mensagem, turno, mensagem que supera, turno, saída aplicada e nova mensagem: cada turno leva a versão vigente" do
      ticket = ingest_at(t0, "chat", "meu repasse não caiu").ticket                      # v1
      turn1 = tick_at(t0 + 1.5.seconds).sole.turn
      expect(turn1).to have_attributes(context_version: 1, context_until_seq: 1)

      ingest_at(t0 + 3.seconds, "chat", "é o de ontem, R$ 1.200")                          # v2
      expect(turn1.reload.status).to eq("superseded")
      turn2 = tick_at(t0 + 4.seconds).sole.turn
      expect(turn2).to have_attributes(context_version: 2, context_until_seq: 2)

      expect(apply(turn1, "Qual repasse?").reason).to eq("turno_superado")                 # rejeição: não sobe
      expect(ticket.reload.context_version).to eq(2)
      expect(apply(turn2, "O de ontem cai hoje.").status).to eq(:applied)                   # saída seq 3: v3
      expect(AuditEvent.find_by!(event_type: "delivery.requested").data).to include("seq" => 3, "context_version" => 3)

      ingest_at(t0 + 10.seconds, "chat", "e o de hoje?")                                    # v4
      turn3 = tick_at(t0 + 11.5.seconds).sole.turn

      expect(turn3).to have_attributes(context_version: 4, context_until_seq: 4)
      expect(ticket.reload.context_version).to eq(4)
      expect(pending_seqs(turn3)).to eq([ 4 ])
      expect(turn3.context.fetch("history").map { _1["seq"] }).to eq([ 1, 2, 3 ])
      expect(turn3.context_digest).to eq(Turns::ContextDigest.call(turn3.context))
      expect(AuditEvent.where(event_type: "message.received").order(:id).map { _1.data.values_at("seq", "context_version") })
        .to eq([ [ 1, 1 ], [ 2, 2 ], [ 4, 4 ] ])
    end
  end
end
