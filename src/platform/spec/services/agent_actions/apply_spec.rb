require "rails_helper"

RSpec.describe AgentActions::Apply, "RF-31: aplicação da ação do agente no atendimento (07, seções 3.1 passo 6 e 3.4)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:turn) { opened_turn }
  let(:ticket) { turn.ticket }

  def apply(action, traceparent: AgentActionHelpers::TRACEPARENT) = described_class.call(action, traceparent:)
  def audits(type) = AuditEvent.where(ticket_id: ticket.id, event_type: type)

  describe "RF-31, RN-37, RF-38, RF-54: ação válida" do
    it "aplica o reply com tool_calls: turno applied, response, horário do banco, prazos do ciclo limpos" do
      action = agent_action_for(turn)
      before_call = db_now

      result = apply(action)

      expect(result).to have_attributes(status: :applied, reason: nil, turn: turn.reload)
      expect(turn).to have_attributes(status: "applied", applied_event_id: action["event_id"], response: action)
      expect(turn.response_received_at).to be_between(before_call, db_now)
      expect(ticket.reload).to have_attributes(first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil,
                                               ai_deadline_at: nil, latest_customer_seq: 1, state: "novo")
      expect(ProcessedEvent.where(consumer: "agent_actions", event_id: action["event_id"])).to exist
    end

    it "RN-37, RF-56: audita com modelo, versão, configuração, consultas, tempos e o trace do traceparent" do
      action = agent_action_for(turn)

      apply(action)

      audit = audits("agent_action.applied").sole
      expect(audit).to have_attributes(actor_type: "agent", agent_model: "mock-deterministico", agent_version: "0.3.0",
                                       trace_id: AgentActionHelpers::TRACE_ID, brand_id: infinitepay.id)
      expect(audit.data).to include(
        "turn" => 1, "event_id" => action["event_id"], "in_reply_to" => turn.event_id, "action" => "reply",
        "tool_calls" => action["tool_calls"], "context_until_seq" => 1,
        "agent" => { "model" => "mock-deterministico", "version" => "0.3.0", "config_hash" => "sha256:9f1c2e" },
        "timing" => action["timing"], "classification" => { "category" => "repasses", "priority" => "alta" }
      )
      expect(audit.data["platform_received_at"]).to eq(turn.reload.response_received_at.utc.iso8601(6))
    end

    it "RF-56: sem traceparent, usa o trace do evento do turno no outbox" do
      apply(agent_action_for(turn), traceparent: nil)

      expect(audits("agent_action.applied").sole.trace_id).to eq(OutboxEvent.find(turn.event_id).trace_id)
    end

    it "aceita o corpo cru em JSON, como chega do Kafka" do
      action = agent_action_for(turn)

      expect(apply(JSON.generate(action)).status).to eq(:applied)
      expect(turn.reload.response).to eq(action)
    end

    it "bloco 04: escalate e resolve ficam registrados; handoff (bloco 10) e encerramento ainda não mudam o estado" do
      escalate = agent_action_for(turn, action: "escalate", escalation: {
        "reason" => "retencao_suspeita", "summary" => { "problema" => "Repasse retido", "dados_cliente" => "Lojista",
                                                        "acoes_tomadas" => "Consultou o repasse", "motivo" => "Retenção",
                                                        "pendente" => "Verificar retenção" }
      })
      escalate.delete("reply")

      expect(apply(escalate).status).to eq(:applied)
      expect(ticket.reload).to have_attributes(state: "novo", assignee_id: nil, assignment_version: 0)
      data = audits("agent_action.applied").sole.data
      expect(data).to include("action" => "escalate", "escalation" => escalate["escalation"])
      expect(data.keys).not_to include("reply", "resolution")
    end

    it "bloco 05: o reply aplicado grava uma saída; os detalhes ficam em apply_delivery_spec.rb" do
      action = agent_action_for(turn)

      expect { apply(action) }.to change(Message, :count).by(1).and change(Delivery, :count).by(1)
    end
  end

  it "RF-54: a resolve aplicada guarda resolution na auditoria" do
    resolve = agent_action_for(turn, action: "resolve", resolution: { "reason" => "duvida_respondida", "text" => "Fico à disposição." })
    resolve.delete("reply")

    expect(apply(resolve).status).to eq(:applied)
    expect(audits("agent_action.applied").sole.data["resolution"]).to eq(resolve["resolution"])
  end

  describe "RN-47, RNF-15: a mesma ação entregue de novo" do
    it "não produz um segundo efeito" do
      action = agent_action_for(turn)
      apply(action)

      expect { expect(apply(action)).to have_attributes(status: :duplicate, reason: nil) }
        .not_to change { [ AuditEvent.count, ProcessedEvent.count, turn.reload.attributes ] }
    end

    it "uma ação rejeitada repetida também não gera nova auditoria" do
      action = agent_action_for(turn, in_reply_to: SecureRandom.uuid)
      apply(action)

      expect { expect(apply(action).status).to eq(:duplicate) }.not_to change(AuditEvent, :count)
    end
  end

  describe "RN-56: segunda ação final para o mesmo turno" do
    it "é rejeitada e auditada; o resultado gravado e a primeira resposta ficam" do
      first = agent_action_for(turn)
      apply(first)
      second = agent_action_for(turn, reply: { "text" => "Outra resposta" })

      result = apply(second)

      expect(result).to have_attributes(status: :rejected, reason: "turno_nao_elegivel")
      expect(turn.reload).to have_attributes(status: "applied", applied_event_id: first["event_id"], response: first)
      rejected = audits("agent_action.rejected").sole
      expect(rejected.data).to include("reason" => "turno_nao_elegivel", "event_id" => second["event_id"], "turn" => 1)
      expect(rejected).to have_attributes(actor_type: "agent", agent_model: "mock-deterministico")
    end

    it "RF-54: a auditoria guarda o conteúdo de cada ação como veio, inclusive o da segunda, rejeitada" do
      apply(agent_action_for(turn))
      second = agent_action_for(turn, reply: { "text" => "Outra resposta" })

      apply(second)

      expect(audits("agent_action.applied").sole.data["reply"]).to eq("text" => "Seu repasse de R$ 1.200 cai hoje até as 18h.")
      rejected = audits("agent_action.rejected").sole.data
      expect(rejected["reply"]).to eq("text" => "Outra resposta")
      expect(rejected.keys).not_to include("escalation", "resolution")
    end
  end

  describe "RN-56, invariante 4: as quatro condições, sob o lock do atendimento" do
    def expect_rejected(action, reason, response: action)
      result = apply(action)
      expect(result).to have_attributes(status: :rejected, reason:)
      expect(turn.reload).to have_attributes(applied_event_id: nil)
      expect(turn.response).to eq(response)
      audit = audits("agent_action.rejected").sole
      expect(audit.data).to include("reason" => reason, "event_id" => action["event_id"], "turn" => action["turn"],
                                    "in_reply_to" => action["in_reply_to"], "tool_calls" => action["tool_calls"])
      expect(audit).to have_attributes(trace_id: AgentActionHelpers::TRACE_ID, agent_version: "0.3.0")
      expect(ProcessedEvent.where(event_id: action["event_id"])).to exist
    end

    it "1: in_reply_to diferente do event_id do turno é rejeitado e não vira a response do turno" do
      expect_rejected(agent_action_for(turn, in_reply_to: SecureRandom.uuid), "in_reply_to_divergente", response: nil)
      expect(turn.status).to eq("eligible")
    end

    it "1: turno que não existe no atendimento é rejeitado e auditado" do
      action = agent_action_for(turn, turn: 7)

      expect(apply(action)).to have_attributes(status: :rejected, reason: "turno_inexistente", turn: nil)
      expect(audits("agent_action.rejected").sole.data).to include("reason" => "turno_inexistente", "turn" => 7)
      expect(dead_letters).to be_empty
    end

    it "1: turno que já não é o atual é rejeitado" do
      turn.update_columns(status: "superseded")
      newer = open_turn_for(ingest("é o de ontem"))
      turn.update_columns(status: "eligible", context_until_seq: newer.context_until_seq)

      expect_rejected(agent_action_for(turn, context_until_seq: newer.context_until_seq), "turno_superado")
    end

    it "2: assignment_version devolvida diferente da do turno" do
      expect_rejected(agent_action_for(turn, assignment_version: 3), "atribuicao_mudou")
    end

    it "2: a atribuição do atendimento mudou depois do envio (IA → humano → IA)" do
      ticket.update_columns(assignment_version: 2)

      expect_rejected(agent_action_for(turn), "atribuicao_mudou")
      expect(turn.status).to eq("eligible")
    end

    it "2: o caso não está mais com a IA" do
      ticket.update_columns(state: "aguardando_humano")

      expect_rejected(agent_action_for(turn), "fora_da_ia")
    end

    it "RN-45, RN-46: com o handoff pedido na atribuição atual, a resposta não é aplicada (uma ação final por turno)" do
      request_handoff(ticket.reload, reason: "falha_de_integracao", source: "dlq", turn: turn.turn)

      expect_rejected(agent_action_for(turn), "handoff_pedido")
      expect(turn.status).to eq("eligible") # o Handoff::Escalate expira o turno ao escalar
      expect(ticket.messages.where(direction: "outbound")).to be_empty
    end

    it "handoff pedido numa atribuição anterior não bloqueia a resposta da atribuição atual" do
      request_handoff(ticket.reload, reason: "falha_de_integracao", source: "dlq", turn: turn.turn)
      OutboxEvent.where(event_type: "handoff.requested").update_all(dedup_key: "handoff:#{ticket.id}:99")

      expect(apply(agent_action_for(turn))).to have_attributes(status: :applied)
    end

    it "3: context_until_seq devolvido diferente do turno persistido" do
      expect_rejected(agent_action_for(turn, context_until_seq: 9), "contexto_divergente")
    end

    it "3: turno superado pela mensagem 2 gravada pela ingestão real antes da resposta (corrida dos 3 s)" do
      expect(turn.context_until_seq).to eq(1)
      ingest("é o de ontem, R$ 1.200")
      action = agent_action_for(turn)

      expect_rejected(action, "turno_superado")
      expect(turn.status).to eq("superseded")
      expect(ticket.reload).to have_attributes(latest_customer_seq: 2, first_pending_seq: 1)
      expect(ticket.dispatch_due_at).to be_present

      turn2 = open_turn_for(ticket)
      expect(turn2).to have_attributes(turn: 2, context_until_seq: 2)
      expect(turn2.context["pending_messages"].pluck("seq")).to eq([ 1, 2 ])
    end

    it "3: turno ainda eligible que não cobre latest_customer_seq (defesa além da ingestão)" do
      ticket.update_columns(latest_customer_seq: 2)

      expect_rejected(agent_action_for(turn), "turno_superado")
    end

    it "4: ciclo já encerrado" do
      ticket.update_columns(first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil,
                            progress_due_at: nil)

      expect_rejected(agent_action_for(turn), "ciclo_encerrado")
    end
  end

  describe "RN-46, ADR-020: prazo do turno pelo relógio do banco, lido após o lock" do
    it "resposta que chega com o prazo já vencido e o job de timeout atrasado é rejeitada; o turno segue eligible" do
      turn.update_columns(deadline_at: db_now - 0.001)
      action = agent_action_for(turn)

      expect(apply(action)).to have_attributes(status: :rejected, reason: "prazo_vencido")
      expect(turn.reload).to have_attributes(status: "eligible", response: action)
    end

    it "um instante antes do prazo (relógio real do banco) é aplicada" do
      turn.update_columns(deadline_at: db_now + 2.seconds)

      expect(apply(agent_action_for(turn)).status).to eq(:applied)
    end

    it "no limite exato (agora == deadline_at) já é rejeitada" do
      allow(DatabaseClock).to receive(:now).and_return(turn.deadline_at)

      expect(apply(agent_action_for(turn))).to have_attributes(status: :rejected, reason: "prazo_vencido")
    end

    it "1 µs antes do limite é aplicada" do
      allow(DatabaseClock).to receive(:now).and_return(turn.deadline_at - 0.000001)

      expect(apply(agent_action_for(turn)).status).to eq(:applied)
    end

    it "o teto do ciclo (ai_deadline_at) vencido também rejeita" do
      ticket.update_columns(ai_deadline_at: db_now - 0.001)

      expect(apply(agent_action_for(turn)).reason).to eq("prazo_vencido")
    end
  end

  describe "ADR-014, invariante 6: marca do atendimento" do
    it "marca divergente vai para a DLQ sem ler nem gravar nada no atendimento" do
      action = agent_action_for(turn, brand: "jim")

      expect { expect(apply(action)).to have_attributes(status: :rejected, reason: "marca_divergente") }
        .not_to change { [ AuditEvent.count, ProcessedEvent.count, turn.reload.attributes, ticket.reload.attributes ] }

      dlq = dead_letters.sole
      expect(dlq).to include(key: "tkt_#{ticket.id}", payload: JSON.generate(action))
      expect(dlq[:headers]).to include("dlq_reason" => "marca_divergente", "dlq_source" => "platform",
                                       "event_id" => action["event_id"], "traceparent" => AgentActionHelpers::TRACEPARENT)
    end

    it "atendimento inexistente vai para a DLQ: sem atendimento não há marca nem turno para auditar" do
      action = agent_action_for(turn, conversation_id: "tkt_999999999")

      expect { expect(apply(action)).to have_attributes(status: :rejected, reason: "turno_inexistente") }
        .not_to change { [ AuditEvent.count, ProcessedEvent.count ] }
      expect(dead_letters.sole[:headers]).to include("dlq_reason" => "turno_inexistente")
    end

    it "conversation_id fora do formato tkt_<id> vai para a DLQ" do
      action = agent_action_for(turn, conversation_id: "conv_abc")

      expect(apply(action).reason).to eq("turno_inexistente")
      expect(dead_letters.size).to eq(1)
    end

    it "marca desconhecida vai para a DLQ" do
      action = agent_action_for(turn, brand: "outra")

      expect(apply(action).reason).to eq("marca_divergente")
      expect(dead_letters.size).to eq(1)
    end
  end

  describe "RNF-28, RN-44, invariante 10: contrato agent_outbound" do
    it "ação fora do catálogo vai para a DLQ, sem retentativa e sem efeito" do
      action = agent_action_for(turn, action: "refund")

      expect { expect(apply(action)).to have_attributes(status: :invalid, reason: "contrato") }
        .not_to change { [ AuditEvent.count, ProcessedEvent.count, turn.reload.attributes ] }

      dlq = dead_letters.sole
      expect(dlq[:headers]).to include("dlq_reason" => "contrato", "dlq_source" => "platform",
                                       "event_id" => action["event_id"], "traceparent" => AgentActionHelpers::TRACEPARENT)
      expect(JSON.parse(dlq[:headers]["dlq_violations"])).to include(include("pointer" => "/action"))
      expect(dlq[:key]).to eq("tkt_#{ticket.id}")
    end

    it "JSON malformado vai para a DLQ com o corpo como chegou" do
      expect(apply("{nao é json").status).to eq(:invalid)

      expect(dead_letters.sole).to include(payload: "{nao é json")
      expect(dead_letters.sole[:headers]).to include("event_id" => "", "dlq_reason" => "contrato")
    end

    it "invariante 2: a DLQ é publicada fora da transação" do
      depth = ActiveRecord::Base.connection.open_transactions
      seen = nil
      allow(Karafka.producer).to receive(:produce_sync).and_wrap_original do |original, **message|
        seen = ActiveRecord::Base.connection.open_transactions
        original.call(**message)
      end

      apply(agent_action_for(turn, brand: "jim"))

      expect(seen).to eq(depth)
    end

    it "se o Kafka recusa a DLQ, o erro sobe (o consumer não confirma o offset) e nada foi gravado" do
      allow(Karafka.producer).to receive(:produce_sync).and_raise(WaterDrop::Errors::ProduceError.new("fora do ar"))

      expect { apply(agent_action_for(turn, action: "refund")) }.to raise_error(WaterDrop::Errors::ProduceError)
      expect(ProcessedEvent.count).to eq(0)
    end
  end

  describe "RN-44, invariante 10, 07 seção 6: ação no contrato que o Postgres não grava" do
    def nothing_recorded = [ ProcessedEvent.count, AiTurn.where.not(response: nil).count, AuditEvent.count, turn.reload.status ]

    {
      "reply.text" => [ { reply: { "text" => "oi\u0000" } }, "/reply/text" ],
      "tool_calls[].args" => [ { tool_calls: [ { "tool" => "get_settlement_status", "args" => { "date" => "a\u0000b" },
                                                   "result" => {}, "duration_ms" => 1 } ] }, "/tool_calls/0/args/date" ],
      "chave em tool_calls[].result" => [ { tool_calls: [ { "tool" => "get_settlement_status", "args" => {},
                                                             "result" => { "x\u0000" => 1 }, "duration_ms" => 1 } ] },
                                          "/tool_calls/0/result" ]
    }.each do |where, (overrides, pointer)|
      it "\\u0000 em #{where} vai para a DLQ como contrato, com o corpo original e sem efeito" do
        action = agent_action_for(turn, **overrides)
        expect(HelpdeskContracts.valid?(:agent_outbound, action)).to be(true)
        before = nothing_recorded

        expect(apply(JSON.generate(action))).to have_attributes(status: :invalid, reason: "contrato", turn: nil)

        expect(nothing_recorded).to eq(before)
        dlq = dead_letters.sole
        expect(dlq[:payload]).to eq(JSON.generate(action))
        expect(dlq[:headers]).to include("dlq_reason" => "contrato", "dlq_source" => "platform", "event_id" => action["event_id"])
        expect(JSON.parse(dlq[:headers]["dlq_violations"]))
          .to contain_exactly(include("pointer" => pointer, "type" => "conteudo_invalido"))
      end
    end

    it "defesa: erro de caractere do Postgres dentro da transação é permanente (DLQ, nada gravado)" do
      action = agent_action_for(turn)
      allow(AuditEvent).to receive(:create!).and_wrap_original do
        ActiveRecord::Base.connection.select_value(%q(SELECT '"\\u0000"'::jsonb))
      end

      expect { expect(apply(action)).to have_attributes(status: :invalid, reason: "contrato") }
        .not_to change { [ ProcessedEvent.count, AuditEvent.count, turn.reload.status, turn.response ] }
      expect(turn).to have_attributes(status: "eligible", response: nil)
      expect(dead_letters.sole[:headers]).to include("dlq_reason" => "contrato", "event_id" => action["event_id"])
      expect(JSON.parse(dead_letters.sole[:headers]["dlq_violations"])).to contain_exactly(include("type" => "conteudo_invalido"))
    end

    it "RNF-14: erro de banco transitório continua subindo, sem DLQ (o consumer não confirma o offset)" do
      action = agent_action_for(turn)
      allow(AuditEvent).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished, "banco fora")

      expect { apply(action) }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      expect(dead_letters).to be_empty
    end

    it "RNF-14: outro erro de SQL (não de caractere) também sobe" do
      action = agent_action_for(turn)
      allow(AuditEvent).to receive(:create!).and_wrap_original do
        ActiveRecord::Base.connection.select_value("SELECT 1/0")
      end

      expect { apply(action) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(dead_letters).to be_empty
    end
  end

  describe "RN-44, RF-37: cabeçalhos e log da DLQ" do
    it "JSON malformado usa o event_id do cabeçalho da mensagem Kafka" do
      header = SecureRandom.uuid

      described_class.call("{nao é json", traceparent: AgentActionHelpers::TRACEPARENT, header_event_id: header)

      expect(dead_letters.sole[:headers]).to include("event_id" => header)
    end

    it "o event_id do corpo vale mais que o do cabeçalho" do
      action = agent_action_for(turn, action: "refund")

      described_class.call(action, header_event_id: SecureRandom.uuid)

      expect(dead_letters.sole[:headers]).to include("event_id" => action["event_id"])
    end

    it "dlq_violations no formato do broker e do agent-mock: {pointer, type, message}" do
      apply(agent_action_for(turn, action: "refund"))

      violations = JSON.parse(dead_letters.sole[:headers]["dlq_violations"])
      expect(violations).to include(include("pointer" => "/action", "type" => "enum", "message" => kind_of(String)))
      expect(violations).to all(match("pointer" => kind_of(String), "type" => kind_of(String), "message" => kind_of(String)))
    end

    def json_lines
      lines = []
      allow(Rails.logger).to receive(:info).and_wrap_original { |m, line| lines << line; m.call(line) }
      lines
    end

    it "agent_action.dead_lettered só é logado depois de a DLQ confirmar" do
      lines = json_lines
      logged_before_produce = nil
      allow(Karafka.producer).to receive(:produce_sync).and_wrap_original do |original, **message|
        logged_before_produce = lines.any? { _1.to_s.include?("agent_action.dead_lettered") }
        original.call(**message)
      end

      apply(agent_action_for(turn, action: "refund"))

      expect(logged_before_produce).to be(false)
      expect(lines.map { JSON.parse(_1.to_s)["event"] rescue nil }).to include("agent_action.dead_lettered")
    end

    it "se a DLQ recusa, não loga agent_action.dead_lettered" do
      lines = json_lines
      allow(Karafka.producer).to receive(:produce_sync).and_raise(WaterDrop::Errors::ProduceError.new("fora do ar"))

      expect { apply(agent_action_for(turn, action: "refund")) }.to raise_error(WaterDrop::Errors::ProduceError)
      expect(lines.map(&:to_s).join).not_to include("agent_action.dead_lettered")
    end
  end

  describe "RN-44, RN-45: a mensagem da plataforma na DLQ segue o contrato dead_letter" do
    def dead_letter_errors(message)
      view = HelpdeskContracts::DeadLetter.view(headers: message[:headers], payload: message[:payload], key: message[:key])
      HelpdeskContracts.errors(:dead_letter, view).map(&:to_s)
    end

    {
      "contrato" => -> { agent_action_for(turn, action: "refund") },
      "JSON malformado" => -> { "{nao é json" },
      "conteudo_invalido" => -> { agent_action_for(turn, reply: { "text" => "oi\u0000" }) },
      "marca_divergente" => -> { agent_action_for(turn, brand: "jim") },
      "turno_inexistente" => -> { agent_action_for(turn, conversation_id: "tkt_999999999") },
      "conversation_id que não é texto" => -> { agent_action_for(turn, conversation_id: 42) },
      "conversation_id vazio" => -> { agent_action_for(turn, conversation_id: "") }
    }.each do |name, build|
      it "#{name}: dlq_source platform e cabeçalhos válidos no esquema" do
        described_class.call(instance_exec(&build), traceparent: nil)

        expect(dead_letters.sole[:headers]).to include("dlq_source" => "platform")
        expect(dead_letter_errors(dead_letters.sole)).to eq([])
      end
    end
  end

  describe "invariante 13, RN-51: log em JSON sem dados do cliente" do
    it "registra trace_id, event_id, in_reply_to, conversation_id, status e motivo, sem o texto da resposta" do
      lines = []
      allow(Rails.logger).to receive(:info).and_wrap_original { |m, line| lines << line; m.call(line) }
      action = agent_action_for(turn, in_reply_to: SecureRandom.uuid)

      apply(action)

      log = lines.map { JSON.parse(_1) rescue nil }.compact.find { _1["event"] == "agent_action.rejected" }
      expect(log).to include("trace_id" => AgentActionHelpers::TRACE_ID, "event_id" => action["event_id"],
                             "in_reply_to" => action["in_reply_to"], "conversation_id" => "tkt_#{ticket.id}",
                             "status" => "rejected", "reason" => "in_reply_to_divergente")
      expect(lines.join).not_to include("R$ 1.200 cai hoje")
    end
  end
end
