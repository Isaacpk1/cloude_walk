# Triagem, roteamento na criação e atribuição do caso novo (07, seção 3.1, passo 2; RF-12, RF-24, RN-11 a RN-13,
# RN-16, RN-17, RN-20, RN-28, RN-34).
#
#   Triage::Run.call(ticket:, trace_id:, seq: nil, evaluator: Routing::Evaluate) # => Result(status:, reason:)
#
# Quem chama já travou a linha do atendimento, na própria transação: o worker do `message.received`
# (Triage::OnMessage, fora da requisição, P1) e o Turns::Open, se o caso ainda estiver `novo` (nenhum turno abre
# antes da triagem). A trava decide a corrida entre os dois: quem chega depois vê o caso fora de `novo`.
#
# Só age em caso `novo` sem pedido de handoff na atribuição atual (RN-34: o pedido já leva o caso à fila humana).
# Classifica as mensagens do cliente gravadas até aqui (uma rajada antes do worker conta inteira, RN-55), pede a
# decisão ao avaliador de regras (pura leitura, escopo da marca) e grava categoria, prioridade (só sobe, RN-14),
# tags, fila e versões. Atribuição:
# - fila `ai_first` (na versão que a decisão registrou, RN-20) e categoria não somente humana → `com_ia`, com o bot
#   da marca como responsável (RF-24), sem incrementar `assignment_version` (é a primeira atribuição). Os prazos do
#   ciclo gravados pela ingestão ficam: contam desde a primeira mensagem pendente;
# - fila sem IA → `aguardando_humano` nessa fila; categoria somente humana em fila `ai_first` → `aguardando_humano`
#   na fila de escalas da marca (RN-28; sem ela, na fila decidida). Nos dois casos o ciclo da IA aberto pela ingestão
#   termina (first_pending_*, dispatch_due_at, ai_deadline_at, progress_due_at) e nenhum turno é gravado.
# - sem nenhuma fila na marca → `com_ia` sem fila (`sem_fila`), como antes do bloco 11: o handoff escala sem fila.
#
# Falha do avaliador (ou fila de outra marca na decisão, QueueOutsideBrand) sobe o erro: a transação de quem chamou
# desfaz tudo e o caso continua `novo`, com o item do outbox aberto para a nova tentativa. Se a falha persistir, o
# teto do ciclo (RN-46) pede o handoff e o caso chega a um humano.
#
# Fora de `novo`, nada muda (RN-17: mensagens novas não re-roteiam). Só audita `triage.skipped` quando o aviso é de
# uma mensagem que a triagem já cobriu (`ja_triado`) ou da primeira mensagem de um caso que saiu de `novo` sem
# triagem (`fora_de_novo`, por exemplo já escalado pelo pedido de humano); os avisos das mensagens seguintes não
# poluem a linha do tempo.
module Triage
  class Run
    class QueueOutsideBrand < StandardError; end

    # `wake_ids`: itens do outbox gravados aqui (o aviso de transferência, RN-42), para quem chamou acordar depois do commit.
    Result = Data.define(:status, :reason, :wake_ids) do
      def initialize(wake_ids: [], **) = super
    end

    CYCLE_RESET = { first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil,
                    progress_due_at: nil }.freeze

    def self.call(...) = new(...).call

    def initialize(ticket:, trace_id:, seq: nil, evaluator: Routing::Evaluate)
      @ticket = ticket
      @trace_id = trace_id
      @seq = seq
      @evaluator = evaluator
    end

    def call
      if ticket.state == "novo"
        if Handoff::Request.pending?(ticket)
          # Uma classificação por caso: a rajada com o pedido pendente não reclassifica a cada mensagem.
          return skip("ja_triado") if classified_seq

          return classify_only("handoff_pedido")
        end

        return triage
      end

      return skip("ja_triado") if @seq && classified_seq && @seq <= classified_seq
      return classify_only("fora_de_novo") if @seq && classified_seq.nil? && @seq == first_customer_seq

      Result.new(status: :not_applicable, reason: nil)
    end

    private

    attr_reader :ticket

    # RN-11: todo atendimento recebe uma categoria, mesmo o que chegou pedindo humano (o handoff do bloco 10 já decidiu
    # a fila). Classifica e grava categoria, prioridade (só sobe, RN-14) e tags; não roteia nem atribui.
    def classify_only(reason)
      messages = customer_messages
      classification = Classify.call(brand: ticket.brand, text: messages.map(&:body).join("\n"))
      priority = policy.highest([ ticket.priority, classification.priority ])
      audit_classified(classification, priority, messages)
      ticket.update_columns(category: classification.category, priority:, tags: classification.tags, updated_at: Time.current)
      skip(reason)
    end

    def triage
      messages = customer_messages
      classification = Classify.call(brand: ticket.brand, text: messages.map(&:body).join("\n"))
      priority = policy.highest([ ticket.priority, classification.priority ])
      decision = @evaluator.call(brand: ticket.brand, attributes: attributes(classification, priority))
      queue = brand_queue(decision.queue)

      audit_classified(classification, priority, messages)
      audit_decided(decision, queue)
      ticket.update_columns(category: classification.category, priority:, tags: classification.tags,
                            ruleset_version: decision.ruleset_version, updated_at: Time.current)
      assign(queue, decision.queue_version, classification.category)
    end

    def assign(queue, queue_version, category)
      if queue.nil? then to_ai(nil, nil, "sem_fila")
      elsif !ai_first?(queue, queue_version) then to_humans(queue, queue_version, "fila_sem_ia")
      elsif policy.human_only?(category) then to_humans(*escalation_target(queue, queue_version), "categoria_somente_humana")
      else to_ai(queue, queue_version, "ia_primeiro")
      end
    end

    def to_ai(queue, queue_version, reason)
      bot = brand_bot
      state_from = ticket.state
      ticket.update_columns(state: "com_ia", assignee_id: bot&.id, queue_id: queue&.id, queue_version:)
      audit("ticket.assigned", to: "ia", reason:, queue_id: queue&.id, assignee_id: bot&.id, state_from:,
                               state_to: "com_ia")
      Result.new(status: :triaged_to_ai, reason:)
    end

    def to_humans(queue, queue_version, reason)
      state_from = ticket.state
      ticket.update_columns(state: "aguardando_humano", assignee_id: nil, queue_id: queue.id, queue_version:, **CYCLE_RESET)
      # RN-33 (item 3), RN-42: ir para a fila humana é uma escalação; o cliente recebe o aviso de transferência.
      notice = Handoff::TransferNotice.call(ticket:, trace_id: @trace_id)
      audit("ticket.assigned", to: "fila_humana", reason:, queue_id: queue.id, assignee_id: nil, state_from:,
                               state_to: "aguardando_humano", transfer_delivery_id: notice&.delivery&.delivery_id)
      Result.new(status: :triaged_to_human, reason:, wake_ids: [ notice&.outbox_event_id ].compact)
    end

    # RN-28: a fila de escalas ativa da marca, na versão corrente; sem ela, a fila decidida.
    def escalation_target(queue, queue_version)
      escalation = HelpdeskQueue.where(brand_id: ticket.brand_id, active: true, escalation: true).first
      escalation ? [ escalation, escalation.current_version&.version ] : [ queue, queue_version ]
    end

    # RN-20: o `ai_first` da versão da fila que a decisão registrou.
    def ai_first?(queue, queue_version)
      version = QueueVersion.find_by(queue_id: queue.id, version: queue_version) || queue.current_version
      version.nil? || version.ai_first
    end

    # Invariante 6: a fila da decisão precisa ser ativa e da marca do atendimento.
    def brand_queue(queue)
      return if queue.nil?

      HelpdeskQueue.find_by(id: queue.id, brand_id: ticket.brand_id) or
        raise QueueOutsideBrand, "fila #{queue.id} fora da marca #{ticket.brand_id} (atendimento #{ticket.id})"
    end

    # RF-24: o usuário bot de uma equipe da marca.
    def brand_bot
      User.where(kind: "bot").joins(:teams).where(teams: { brand_id: ticket.brand_id }).order(:id).first
    end

    def attributes(classification, priority)
      { "brand" => ticket.brand.slug, "channel" => ticket.channel, "category" => classification.category,
        "priority" => priority, "tags" => classification.tags }
    end

    def customer_messages
      Message.where(brand_id: ticket.brand_id, ticket_id: ticket.id, direction: "inbound", author_type: "customer")
             .where(seq: ..ticket.latest_customer_seq).order(:seq).to_a
    end

    def first_customer_seq
      Message.where(brand_id: ticket.brand_id, ticket_id: ticket.id, direction: "inbound", author_type: "customer")
             .minimum(:seq)
    end

    def classified_seq
      return @classified_seq if defined?(@classified_seq)

      @classified_seq = AuditEvent.where(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: "triage.classified")
                                  .order(:id).last&.data&.fetch("seq", nil)
    end

    def audit_classified(classification, priority, messages)
      audit("triage.classified", category: classification.category, priority:, tags: classification.tags,
                                 matched: classification.matched, unclassified: classification.unclassified,
                                 seq: messages.last&.seq, seqs: messages.map(&:seq))
    end

    def audit_decided(decision, queue)
      audit("routing.decided", applied_ruleset: decision.ruleset_version,
                               moment: "criacao", queue_id: queue&.id, queue_version: decision.queue_version,
                               queue_name: decision.queue_name, ruleset_version: decision.ruleset_version,
                               rule_index: decision.rule_index, rule_name: decision.rule_name,
                               group_index: decision.group_index, conditions: decision.conditions,
                               default: decision.default, skipped_rules: decision.skipped_rules)
    end

    def skip(reason)
      audit("triage.skipped", reason:, state: ticket.state)
      Result.new(status: :skipped, reason:)
    end

    def policy = @policy ||= Policy.for(ticket.brand)

    # `applied_ruleset` vai para a coluna audit_events.ruleset_version (RN-20, RF-18).
    def audit(event_type, applied_ruleset: nil, **data)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type:,
                         trace_id: @trace_id, ruleset_version: applied_ruleset, data:)
    end
  end
end
