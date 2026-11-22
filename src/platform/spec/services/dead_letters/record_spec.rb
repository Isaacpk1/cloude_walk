require "rails_helper"

RSpec.describe DeadLetters::Record, "RF-34, RN-45: DLQ da plataforma (07, seções 4 e 6)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:turn) { opened_turn }
  let(:ticket) { turn.ticket }

  def audits(type, ticket_id: ticket.id) = AuditEvent.where(ticket_id:, event_type: type)

  describe "RF-34, RF-37: espelho da mensagem" do
    it "grava topic, partition, offset, origem, motivo, violações, cabeçalhos e o corpo cru" do
      headers = dlq_headers(source: "broker", reason: "contrato", event_id: "e-1")

      result = record_dead_letter("{nao é json", headers:, partition: 7, offset: 42, key: "e-1")

      expect(result).to have_attributes(status: :recorded, outcome: "uncorrelated")
      expect(DeadLetter.find(result.dead_letter_id)).to have_attributes(
        topic: "helpdesk.agent.dlq.v1", partition: 7, offset: 42, source: "broker", reason: "contrato",
        event_id: "e-1", trace_id: AgentActionHelpers::TRACE_ID, payload: "{nao é json", outcome: "uncorrelated",
        brand_id: nil, ticket_id: nil, turn: nil, violations: DeadLetterHelpers::CONTRACT_VIOLATION,
        headers: headers
      )
    end

    it "RN-47: a mesma mensagem (mesmo offset) duas vezes é um registro só, sem efeito novo" do
      first = broker_dead_letter(turn, offset: 5)

      again = broker_dead_letter(turn, offset: 5)

      expect(again).to have_attributes(status: :duplicate, dead_letter_id: first.dead_letter_id)
      expect(DeadLetter.count).to eq(1)
      expect(handoff_items.count).to eq(1)
      expect(audits("dead_letter.recorded").count).to eq(1)
    end

    it "o mesmo offset em outra partição é outra mensagem" do
      record_dead_letter("x", headers: dlq_headers(source: "broker", reason: "contrato", event_id: ""), partition: 0, offset: 1)
      record_dead_letter("x", headers: dlq_headers(source: "broker", reason: "contrato", event_id: ""), partition: 1, offset: 1)

      expect(DeadLetter.count).to eq(2)
    end

    it "07 seção 6: corpo com \\u0000 grava o NUL escapado como o texto literal \\u0000 e marca o saneamento" do
      result = record_dead_letter("{\"a\":\"oi\u0000\"}", headers: dlq_headers(source: "platform", reason: "contrato", event_id: "e-2"))

      dead_letter = DeadLetter.find(result.dead_letter_id)
      expect(dead_letter.payload).to eq('{"a":"oi\\u0000"}')
      expect(dead_letter.headers).to include("payload_sanitized" => "nul")
      expect(dead_letter.error).to include("corpo saneado")
      expect(dead_letter.outcome).to eq("uncorrelated")
    end

    it "07 seção 6: corpo com bytes que não são UTF-8 é gravado com scrub (U+FFFD) e marca o saneamento" do
      result = record_dead_letter("{\"a\":\"oi\"}\xFF\xFE".b,
                                  headers: dlq_headers(source: "broker", reason: "contrato", event_id: "e-3"))

      dead_letter = DeadLetter.find(result.dead_letter_id)
      expect(dead_letter.payload).to eq("{\"a\":\"oi\"}\uFFFD\uFFFD")
      expect(dead_letter.headers).to include("payload_sanitized" => "utf8_invalido")
    end

    it "os dois defeitos no mesmo corpo: grava e marca os dois" do
      result = record_dead_letter("a\u0000b\xFF".b, headers: dlq_headers(source: "broker", reason: "contrato", event_id: "e-5"))

      dead_letter = DeadLetter.find(result.dead_letter_id)
      expect(dead_letter.payload).to eq('a\u0000b' + "�")
      expect(dead_letter.headers).to include("payload_sanitized" => "utf8_invalido,nul")
    end

    it "corpo limpo não leva a marca de saneamento" do
      result = record_dead_letter("{}", headers: dlq_headers(source: "broker", reason: "contrato", event_id: "e-4"))

      expect(DeadLetter.find(result.dead_letter_id).headers).not_to have_key("payload_sanitized")
    end

    it "cabeçalhos com \\u0000 também são saneados para o jsonb" do
      headers = dlq_headers(source: "broker", reason: "contrato", event_id: "e\u0000")

      result = record_dead_letter("x", headers:)

      expect(DeadLetter.find(result.dead_letter_id)).to have_attributes(event_id: 'e\\u0000')
    end

    it "cabeçalhos fora do contrato dead_letter: grava como unknown, sem correlacionar" do
      result = record_dead_letter(turn_event_body(turn), headers: { "event_id" => turn.event_id })

      expect(DeadLetter.find(result.dead_letter_id)).to have_attributes(
        source: "unknown", reason: "desconhecido", outcome: "uncorrelated", ticket_id: nil, violations: []
      )
      expect(DeadLetter.find(result.dead_letter_id).error).to include("/headers/dlq_source")
      expect(handoff_items).to be_empty
    end
  end

  describe "RN-45: evento de turno ainda válido escala o atendimento" do
    it "evento do turno recusado pelo broker: escalated, handoff.requested no outbox e auditorias" do
      result = broker_dead_letter(turn)

      expect(result.outcome).to eq("escalated")
      dead_letter = DeadLetter.find(result.dead_letter_id)
      expect(dead_letter).to have_attributes(brand_id: infinitepay.id, ticket_id: ticket.id, turn: turn.turn,
                                             event_id: turn.event_id, outcome: "escalated")
      item = handoff_items.sole
      payload = { "ticket_id" => ticket.id, "reason" => "falha_de_integracao", "source" => "dlq", "turn" => turn.turn,
                  "first_pending_seq" => ticket.reload.first_pending_seq, "assignment_version" => ticket.assignment_version }
      expect(item).to have_attributes(dedup_key: "handoff:#{ticket.id}:#{ticket.assignment_version}", brand_id: infinitepay.id,
                                      ticket_id: ticket.id, trace_id: AgentActionHelpers::TRACE_ID, payload:, completed_at: nil)
      expect(item.next_attempt_at).to be_within(5.seconds).of(Time.current)
      expect(audits("handoff.requested").sole).to have_attributes(data: payload.merge("outbox_event_id" => item.id), trace_id: AgentActionHelpers::TRACE_ID,
                                                                  brand_id: infinitepay.id)
      expect(audits("dead_letter.recorded").sole.data).to include(
        "dead_letter_id" => dead_letter.id, "source" => "broker", "reason" => "contrato", "outcome" => "escalated"
      )
    end

    it "RN-57: o pedido pela DLQ passa pelo Handoff::Request e encerra o aviso de progresso devido" do
      expect(ticket.reload.progress_due_at).to be_present

      broker_dead_letter(turn)

      expect(ticket.reload.progress_due_at).to be_nil
    end

    it "acorda o worker com o item do handoff depois do commit" do
      result = broker_dead_letter(turn)

      expect(OutboxJob).to have_been_enqueued.with(handoff_items.sole.id)
      expect(result.handoff_event_id).to eq(handoff_items.sole.id)
    end

    it "falha de dependência: Redis fora não desfaz o registro (a recuperação do outbox reoferece o item)" do
      allow(OutboxJob).to receive(:perform_later).and_raise(RedisClient::CannotConnectError, "redis fora do ar")

      expect(broker_dead_letter(turn).outcome).to eq("escalated")
      expect(handoff_items.count).to eq(1)
    end

    it "RF-56: sem traceparent válido, usa o trace do evento do turno" do
      turn_trace = OutboxEvent.find(turn.event_id).trace_id
      headers = dlq_headers(source: "broker", reason: "traceparent_invalido", event_id: turn.event_id, traceparent: "invalido")

      result = record_dead_letter(turn_event_body(turn), headers:)

      expect(result.outcome).to eq("escalated")
      expect(handoff_items.sole.trace_id).to eq(turn_trace)
      expect(DeadLetter.find(result.dead_letter_id).trace_id).to eq(turn_trace)
    end

    it "evento de entrada recusado pelo agent-mock (contrato) escala" do
      headers = dlq_headers(source: "agent-mock", reason: "contrato", event_id: turn.event_id)

      expect(record_dead_letter(turn_event_body(turn), headers:).outcome).to eq("escalated")
    end

    it "ação inválida do agent-mock com in_reply_to do turno escala" do
      expect(action_dead_letter(turn, source: "agent-mock", reason: "acao_invalida", reply: { "text" => " " }).outcome)
        .to eq("escalated")
      expect(handoff_items.sole.payload).to include("turn" => turn.turn)
    end

    it "ação com \\u0000 recusada pela plataforma (conteudo_invalido) escala" do
      action = agent_action_for(turn, reply: { "text" => "oi\u0000" })
      violations = [ { "pointer" => "/reply/text", "type" => "conteudo_invalido", "message" => "caractere nulo" } ]

      result = record_dead_letter(JSON.generate(action),
                                  headers: dlq_headers(source: "platform", reason: "contrato", event_id: action["event_id"], violations:))

      expect(result.outcome).to eq("escalated")
    end

    it "dois DLQ do mesmo turno: um só handoff.requested (a chave da atribuição colide)" do
      first = broker_dead_letter(turn)
      second = action_dead_letter(turn, action: "refund")

      expect([ first.outcome, second.outcome ]).to eq(%w[escalated escalated])
      expect(handoff_items.count).to eq(1)
      expect(audits("handoff.requested").count).to eq(1)
      expect(audits("dead_letter.recorded").count).to eq(2)
      expect(second.handoff_event_id).to be_nil
    end

    it "o prazo do turno já vencido sem handoff ainda escala pela DLQ (o timeout usa a mesma chave)" do
      travel_to(turn.deadline_at + 1.second) do
        expect(broker_dead_letter(turn).outcome).to eq("escalated")
      end
    end
  end

  describe "RN-45, 07 seção 6: turno superado, aplicado ou expirado só é auditado" do
    it "turno superado por mensagem nova do cliente: audited, sem escalar" do
      turn
      ingest("é o de ontem, R$ 1.200")

      result = broker_dead_letter(turn)

      expect(result.outcome).to eq("audited")
      expect(handoff_items).to be_empty
      expect(audits("dead_letter.audited").sole.data).to include("reason" => "turno_superseded", "turn" => turn.turn,
                                                                  "dead_letter_id" => result.dead_letter_id)
      expect(audits("dead_letter.recorded").sole.data).to include("outcome" => "audited")
    end

    it "ação com in_reply_to de turno já aplicado: audited" do
      AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)

      result = action_dead_letter(turn, source: "agent-mock", reason: "acao_invalida", reply: { "text" => " " })

      expect(result.outcome).to eq("audited")
      expect(audits("dead_letter.audited").sole.data["reason"]).to eq("turno_applied")
      expect(handoff_items).to be_empty
    end

    it "turno expirado: audited" do
      turn.update_columns(status: "expired")

      expect(broker_dead_letter(turn).outcome).to eq("audited")
      expect(audits("dead_letter.audited").sole.data["reason"]).to eq("turno_expired")
    end

    it "atribuição mudou (timeout de ciclo anterior): audited" do
      turn
      ticket.update_columns(assignment_version: ticket.assignment_version + 1)

      expect(broker_dead_letter(turn).outcome).to eq("audited")
      expect(audits("dead_letter.audited").sole.data["reason"]).to eq("atribuicao_mudou")
    end

    it "caso já fora da IA: audited" do
      turn
      ticket.update_columns(state: "aguardando_humano")

      expect(broker_dead_letter(turn).outcome).to eq("audited")
      expect(audits("dead_letter.audited").sole.data["reason"]).to eq("fora_da_ia")
    end

    it "turno anterior com um turno mais novo aberto: audited" do
      turn.update_columns(status: "eligible")
      ticket.ai_turns.create!(brand_id: ticket.brand_id, turn: turn.turn + 1, context_until_seq: turn.context_until_seq,
                              assignment_version: turn.assignment_version, context: turn.context,
                              event_id: SecureRandom.uuid, status: "eligible", deadline_at: turn.deadline_at)

      expect(broker_dead_letter(turn).outcome).to eq("audited")
      expect(audits("dead_letter.audited").sole.data["reason"]).to eq("turno_superseded")
    end
  end

  describe "RN-45: sem correlação confiável não toca o atendimento" do
    def expect_untouched(result)
      expect(result.outcome).to eq("uncorrelated")
      expect(DeadLetter.find(result.dead_letter_id)).to have_attributes(brand_id: nil, ticket_id: nil, turn: nil)
      expect(handoff_items).to be_empty
      expect(AuditEvent.where(event_type: %w[dead_letter.recorded dead_letter.audited handoff.requested])).to be_empty
    end

    it "marca_divergente e turno_inexistente da plataforma nunca escalam (07, seção 5.3)" do
      %w[marca_divergente turno_inexistente].each do |reason|
        expect_untouched(action_dead_letter(turn, reason:))
      end
    end

    it "corpo que não é JSON" do
      expect_untouched(record_dead_letter("{nao", headers: dlq_headers(source: "broker", reason: "contrato", event_id: turn.event_id)))
    end

    it "event_id do cabeçalho diferente do corpo (event_id_divergente)" do
      headers = dlq_headers(source: "broker", reason: "event_id_divergente", event_id: SecureRandom.uuid)

      expect_untouched(record_dead_letter(turn_event_body(turn), headers:))
    end

    it "conversation_id que não é o atendimento do turno" do
      other = opened_turn(identity: "acc_infinitepay_outro")
      body = JSON.parse(turn_event_body(turn)).merge("conversation_id" => "tkt_#{other.ticket_id}")

      expect_untouched(record_dead_letter(JSON.generate(body),
                                          headers: dlq_headers(source: "broker", reason: "contrato", event_id: turn.event_id)))
    end

    it "número do turno no corpo diferente do turno do event_id" do
      expect_untouched(action_dead_letter(turn, turn: turn.turn + 1, action: "refund"))
    end

    it "in_reply_to que não é de turno nenhum" do
      expect_untouched(action_dead_letter(turn, in_reply_to: SecureRandom.uuid, action: "refund"))
    end

    it "schema do corpo de outro contrato" do
      body = JSON.parse(turn_event_body(turn)).merge("schema" => "helpdesk.agent_action.v1")

      expect_untouched(record_dead_letter(JSON.generate(body),
                                          headers: dlq_headers(source: "broker", reason: "contrato", event_id: turn.event_id)))
    end
  end

  describe "ADR-014, invariante 6: marca errada nunca correlaciona com atendimento de outra marca" do
    it "evento com o event_id de um turno da InfinitePay e a marca JIM no corpo: uncorrelated" do
      body = JSON.parse(turn_event_body(turn)).merge("brand" => "jim")

      result = record_dead_letter(JSON.generate(body),
                                  headers: dlq_headers(source: "broker", reason: "contrato", event_id: turn.event_id))

      expect(result.outcome).to eq("uncorrelated")
      expect(DeadLetter.find(result.dead_letter_id)).to have_attributes(brand_id: nil, ticket_id: nil)
      expect(AuditEvent.where(event_type: %w[dead_letter.recorded handoff.requested])).to be_empty
      expect(handoff_items).to be_empty
    end

    it "ação da JIM com in_reply_to de turno da InfinitePay: uncorrelated" do
      expect(action_dead_letter(turn, brand: "jim", action: "refund").outcome).to eq("uncorrelated")
      expect(handoff_items).to be_empty
    end
  end

  describe "invariante 13, RN-51: log em JSON sem o corpo" do
    it "registra dead_letter.recorded com ids e desfecho, sem o texto do cliente" do
      lines = []
      allow(Rails.logger).to receive(:info).and_wrap_original { |m, line| lines << line; m.call(line) }

      broker_dead_letter(turn)

      line = lines.map { JSON.parse(_1.to_s) rescue nil }.compact.find { _1["event"] == "dead_letter.recorded" }
      expect(line).to include("trace_id" => AgentActionHelpers::TRACE_ID, "source" => "broker", "reason" => "contrato",
                              "outcome" => "escalated", "ticket_id" => ticket.id, "offset" => kind_of(Integer))
      expect(lines.join).not_to include("meu repasse")
    end
  end
end
