require "rails_helper"

# Triagem, roteamento na criação e atribuição (07, seção 3.1, passo 2; common11.md, Triage::Run).
RSpec.describe Triage::Run, "RF-12, RF-24, RN-28: triagem e atribuição do caso novo" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:config) { triage_setup(infinitepay) }
  let(:start) { Time.zone.parse("2026-11-22T12:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  def audits(ticket, type) = AuditEvent.where(ticket_id: ticket.id, event_type: type).order(:id)

  describe "RF-24: fila com IA atende primeiro" do
    it "classifica, roteia e atribui ao bot em com_ia, sem trocar a atribuição e sem mexer nos prazos do ciclo" do
      received = ingest("meu repasse não caiu, urgente")
      before = received.ticket.reload.slice(:first_pending_seq, :first_pending_at, :dispatch_due_at, :ai_deadline_at)
      evaluator = fixed_evaluator(routing_decision(config[:default]))

      result = run_triage(received.ticket, evaluator:)

      ticket = received.ticket.reload
      expect(result).to have_attributes(status: :triaged_to_ai)
      expect(ticket).to have_attributes(state: "com_ia", assignee_id: config[:bot].id, assignment_version: 0,
                                        category: "repasses", priority: "alta", tags: %w[urgente],
                                        queue_id: config[:default].id, queue_version: 1, ruleset_version: 3)
      expect(ticket.slice(*before.keys)).to eq(before)
      expect(ticket.with_ai?).to be(true)
      expect(evaluator.calls.sole).to eq(
        brand: ticket.brand,
        attributes: { "brand" => "infinitepay", "channel" => "chat", "category" => "repasses", "priority" => "alta",
                      "tags" => %w[urgente] }
      )
    end

    it "RF-54, RN-20: audita a classificação, a decisão com a versão das regras e a atribuição, com o trace_id" do
      received = ingest("meu repasse não caiu")
      run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])), trace_id: "e" * 32)

      ticket = received.ticket
      classified = audits(ticket, "triage.classified").sole
      expect(classified).to have_attributes(actor_type: "system", trace_id: "e" * 32, brand_id: infinitepay.id)
      expect(classified.data).to eq("category" => "repasses", "priority" => "alta", "tags" => [],
                                    "matched" => [ "repasse", "nao caiu" ], "unclassified" => false, "seq" => 1,
                                    "seqs" => [ 1 ])
      decided = audits(ticket, "routing.decided").sole
      expect(decided).to have_attributes(ruleset_version: 3, trace_id: "e" * 32)
      expect(decided.data).to eq("moment" => "criacao", "queue_id" => config[:default].id, "queue_version" => 1,
                                 "queue_name" => "Geral", "ruleset_version" => 3, "rule_index" => 0,
                                 "rule_name" => "Regra de teste", "group_index" => 0,
                                 "conditions" => [ { "field" => "category", "op" => "eq", "value" => "repasses" } ],
                                 "default" => false, "skipped_rules" => [])
      assigned = audits(ticket, "ticket.assigned").sole
      expect(assigned.data).to eq("to" => "ia", "reason" => "ia_primeiro", "queue_id" => config[:default].id,
                                  "assignee_id" => config[:bot].id, "state_from" => "novo", "state_to" => "com_ia")
      expect(classified.id).to be < decided.id
      expect(decided.id).to be < assigned.id
    end

    it "RN-15: grava as regras puladas e o nome da fila como o avaliador devolve" do
      skipped = [ { "rule_index" => 0, "rule_name" => "Crédito alto", "queue_id" => 99, "reason" => "fila_inativa" } ]
      decision = routing_decision(config[:default], default: true).with(skipped_rules: skipped)
      received = ingest("meu repasse não caiu")

      run_triage(received.ticket, evaluator: fixed_evaluator(decision))

      expect(audits(received.ticket, "routing.decided").sole.data).to include("skipped_rules" => skipped,
                                                                              "queue_name" => decision.queue_name)
    end

    it "RN-55: classifica todas as mensagens do cliente gravadas até a triagem (rajada antes do worker)" do
      ingest("oi")
      received = ingest("minha maquininha não liga")

      run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])))

      expect(received.ticket.reload).to have_attributes(category: "maquininha", priority: "critica")
      expect(audits(received.ticket, "triage.classified").sole.data).to include("seq" => 2, "seqs" => [ 1, 2 ])
    end

    it "RN-13: \"oi\" fica em outros, média, na fila padrão da marca" do
      received = ingest("oi")

      run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(config[:default], default: true,
                                                                                              ruleset_version: nil)))

      expect(received.ticket.reload).to have_attributes(category: "outros", priority: "media", queue_id: config[:default].id,
                                                        ruleset_version: nil, state: "com_ia")
      expect(audits(received.ticket, "triage.classified").sole.data).to include("unclassified" => true)
      expect(audits(received.ticket, "routing.decided").sole.data).to include("default" => true, "rule_index" => nil)
    end

    it "sem bot na equipe da marca, o caso fica com a IA sem responsável (RF-24 sem usuário bot configurado)" do
      config[:bot].team_memberships.destroy_all
      received = ingest("meu repasse não caiu")

      run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])))

      expect(received.ticket.reload).to have_attributes(state: "com_ia", assignee_id: nil)
      expect(audits(received.ticket, "ticket.assigned").sole.data).to include("to" => "ia", "assignee_id" => nil)
    end

    it "sem nenhuma fila na marca, o caso segue com a IA, sem fila (motivo sem_fila)" do
      received = ingest("meu repasse não caiu")

      run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(nil, default: true, ruleset_version: nil)))

      expect(received.ticket.reload).to have_attributes(state: "com_ia", queue_id: nil, queue_version: nil)
      expect(audits(received.ticket, "ticket.assigned").sole.data).to include("to" => "ia", "reason" => "sem_fila")
    end

    it "RN-14: a triagem nunca baixa uma prioridade já mais alta" do
      received = ingest("dúvida sobre taxa")
      received.ticket.update_columns(priority: "critica")

      run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])))

      expect(received.ticket.reload.priority).to eq("critica")
    end
  end

  describe "fila sem IA (RF-24 do avesso)" do
    it "vai para aguardando_humano nessa fila, encerra o ciclo da IA e não grava turno" do
      human = create(:queue_record, team: config[:team], brand: infinitepay)
      human.publish_version!(name: "Crédito", ai_first: false, created_by: nil)
      received = ingest("quero saber do meu empréstimo")

      result = run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(human.reload)))

      ticket = received.ticket.reload
      expect(result.status).to eq(:triaged_to_human)
      expect(ticket).to have_attributes(state: "aguardando_humano", queue_id: human.id, queue_version: 1, assignee_id: nil,
                                        assignment_version: 0, first_pending_seq: nil, first_pending_at: nil,
                                        dispatch_due_at: nil, ai_deadline_at: nil, progress_due_at: nil,
                                        category: "credito")
      expect(ticket.with_ai?).to be(false)
      expect(ticket.ai_turns).to be_empty
      expect(audits(ticket, "ticket.assigned").sole.data).to eq(
        "to" => "fila_humana", "reason" => "fila_sem_ia", "queue_id" => human.id, "assignee_id" => nil,
        "state_from" => "novo", "state_to" => "aguardando_humano",
        "transfer_delivery_id" => Delivery.find_by!(ticket_id: ticket.id, kind: "handoff_notice").delivery_id
      )
    end

    it "RN-33 (item 3), RN-42: o cliente recebe o aviso de transferência; o Result devolve o item para acordar" do
      human = create(:queue_record, team: config[:team], brand: infinitepay)
      human.publish_version!(name: "Crédito", ai_first: false, created_by: nil)
      received = ingest("quero saber do meu empréstimo")

      result = run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(human.reload)))

      notice = Delivery.find_by!(ticket_id: received.ticket.id, kind: "handoff_notice")
      expect(notice).to have_attributes(status: "pending", seq: 2, ai_assignment_version: nil)
      expect(notice.message).to have_attributes(author_type: "system", body: Handoff::Policy::DEFAULT.transfer_notice_text("pt-BR"))
      expect(result.wake_ids).to eq([ OutboxEvent.find_by!(dedup_key: "delivery:#{notice.delivery_id}").id ])
      expect(audits(received.ticket, "ticket.assigned").sole.data).to include("transfer_delivery_id" => notice.delivery_id)
    end

    it "fila com IA primeiro não grava aviso nem item a acordar" do
      received = ingest("meu repasse não caiu")

      result = run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])))

      expect(result.wake_ids).to be_empty
      expect(Delivery.where(ticket_id: received.ticket.id)).to be_empty
    end

    it "RN-20: vale a versão da fila que a decisão registrou, não uma publicada depois" do
      queue = config[:default]
      decision = routing_decision(queue)
      queue.publish_version!(name: "Geral", ai_first: false, created_by: nil)
      received = ingest("meu repasse não caiu")

      run_triage(received.ticket, evaluator: fixed_evaluator(decision))

      expect(received.ticket.reload).to have_attributes(state: "com_ia", queue_version: 1)
    end
  end

  describe "RN-28: categoria somente humana em fila IA primeiro" do
    it "vai para a fila de escalas da marca em aguardando_humano, sem turno e com o ciclo encerrado" do
      received = ingest("preciso trocar o e-mail do cadastro")

      result = run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])))

      ticket = received.ticket.reload
      expect(result.status).to eq(:triaged_to_human)
      expect(ticket).to have_attributes(state: "aguardando_humano", queue_id: config[:escalation].id, queue_version: 1,
                                        assignee_id: nil, category: "cadastro", priority: "baixa", dispatch_due_at: nil,
                                        first_pending_seq: nil, ai_deadline_at: nil)
      expect(audits(ticket, "routing.decided").sole.data).to include("queue_id" => config[:default].id)
      expect(audits(ticket, "ticket.assigned").sole.data).to include(
        "to" => "fila_humana", "reason" => "categoria_somente_humana", "queue_id" => config[:escalation].id
      )
    end

    it "sem fila de escalas ativa, fica na fila decidida, aguardando humano" do
      config[:escalation].update_columns(active: false)
      received = ingest("preciso trocar o e-mail do cadastro")

      run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])))

      expect(received.ticket.reload).to have_attributes(state: "aguardando_humano", queue_id: config[:default].id)
    end
  end

  describe "RN-34 (ordem): pedido de humano antes da triagem" do
    it "RN-11: classifica (categoria, prioridade, tags) mas pula roteamento e atribuição com handoff_pedido" do
      received = ingest("minha maquininha nao liga, quero falar com um atendente")
      evaluator = fixed_evaluator(routing_decision(config[:default]))

      result = run_triage(received.ticket, evaluator:)

      expect(result).to have_attributes(status: :skipped, reason: "handoff_pedido")
      expect(received.ticket.reload).to have_attributes(state: "novo", category: "maquininha", priority: "critica", queue_id: nil)
      expect(evaluator.calls).to be_empty
      expect(audits(received.ticket, "triage.skipped").sole.data).to eq("reason" => "handoff_pedido", "state" => "novo")
      expect(audits(received.ticket, "triage.classified").sole.data).to include("category" => "maquininha")
      expect(audits(received.ticket, "routing.decided")).to be_empty
    end
  end

  it "RN-11: rajada com pedido de humano pendente classifica uma vez só (a 2ª mensagem não reclassifica)" do
    first = ingest("quero falar com um atendente")
    run_triage(first.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])), seq: 1)
    ingest("e sobre meu cadastro")

    result = run_triage(first.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])), seq: 2)

    expect(result).to have_attributes(status: :skipped, reason: "ja_triado")
    expect(audits(first.ticket, "triage.classified").count).to eq(1)
  end

  describe "repetição" do
    it "o mesmo aviso de novo: não triagem outra vez; audita ja_triado" do
      received = ingest("meu repasse não caiu")
      evaluator = fixed_evaluator(routing_decision(config[:default]))
      run_triage(received.ticket, evaluator:, seq: 1)

      result = run_triage(received.ticket, evaluator:, seq: 1)

      expect(result).to have_attributes(status: :skipped, reason: "ja_triado")
      expect(evaluator.calls.size).to eq(1)
      expect(audits(received.ticket, "triage.classified").size).to eq(1)
      expect(audits(received.ticket, "routing.decided").size).to eq(1)
      expect(audits(received.ticket, "triage.skipped").sole.data).to eq("reason" => "ja_triado", "state" => "com_ia")
    end

    it "RN-17: mensagem nova depois da triagem não re-roteia nem audita nada" do
      received = ingest("meu repasse não caiu")
      evaluator = fixed_evaluator(routing_decision(config[:default]))
      run_triage(received.ticket, evaluator:, seq: 1)
      ingest("é o de ontem")

      result = run_triage(received.ticket, evaluator:, seq: 2)

      expect(result.status).to eq(:not_applicable)
      expect(evaluator.calls.size).to eq(1)
      expect(audits(received.ticket, "triage.skipped")).to be_empty
    end

    it "primeira mensagem de um caso que saiu de novo sem triagem (já escalado): fora_de_novo" do
      received = ingest("meu repasse não caiu")
      received.ticket.update_columns(state: "aguardando_humano")

      result = run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])), seq: 1)

      expect(result).to have_attributes(status: :skipped, reason: "fora_de_novo")
      expect(audits(received.ticket, "triage.skipped").sole.data).to eq("reason" => "fora_de_novo",
                                                                         "state" => "aguardando_humano")
      # RN-11: o caso escalado antes da triagem também recebe categoria; a fila e o estado não mudam.
      expect(received.ticket.reload).to have_attributes(category: "repasses", priority: "alta", state: "aguardando_humano")
      expect(audits(received.ticket, "routing.decided")).to be_empty
    end
  end

  describe "falha do avaliador" do
    it "o erro sobe, a transação desfaz tudo e o caso continua novo para a próxima tentativa" do
      received = ingest("meu repasse não caiu")
      failing = Object.new
      def failing.call(**) = raise(ActiveRecord::ConnectionFailed, "fora")

      expect { run_triage(received.ticket, evaluator: failing) }.to raise_error(ActiveRecord::ConnectionFailed)

      expect(received.ticket.reload).to have_attributes(state: "novo", category: nil, dispatch_due_at: be_present)
      expect(audits(received.ticket, "triage.classified")).to be_empty
    end
  end

  describe "marca errada (invariante 6)" do
    let!(:jim_config) { triage_setup(jim) }

    it "JIM: classifica em inglês e usa só a fila e o bot da JIM" do
      received = ingest("My card machine won't turn on", brand: "jim")

      run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(jim_config[:default])))

      expect(received.ticket.reload).to have_attributes(brand_id: jim.id, category: "maquininha", priority: "critica",
                                                        queue_id: jim_config[:default].id, assignee_id: jim_config[:bot].id)
    end

    it "decisão com fila de outra marca é recusada sem gravar nada" do
      received = ingest("meu repasse não caiu")

      expect do
        run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(jim_config[:default])))
      end.to raise_error(Triage::Run::QueueOutsideBrand)

      expect(received.ticket.reload).to have_attributes(state: "novo", queue_id: nil)
    end

    it "nunca usa o bot nem a fila de escalas de outra marca" do
      config[:bot].team_memberships.destroy_all
      config[:escalation].update_columns(active: false)
      received = ingest("preciso trocar o e-mail do cadastro")

      run_triage(received.ticket, evaluator: fixed_evaluator(routing_decision(config[:default])))
      ingest("meu repasse não caiu", identity: "acc_infinitepay_000022")
      other = Ticket.order(:id).last
      run_triage(other, evaluator: fixed_evaluator(routing_decision(config[:default])))

      expect(received.ticket.reload.queue_id).to eq(config[:default].id)
      expect(other.reload.assignee_id).to be_nil
    end
  end
end
