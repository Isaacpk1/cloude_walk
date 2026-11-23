# Aplicação da ação do agente ao atendimento (RF-31; 07, seção 3.1, passo 6, e seção 3.4; RN-56).
#
#   AgentActions::Apply.call(payload, traceparent: header, header_event_id: header) # => Result(status:, reason:, turn:)
#
# `payload` é o corpo cru do Kafka (String) ou um Hash. `status`: :applied, :rejected, :duplicate ou :invalid.
# `header_event_id` (cabeçalho `event_id` da mensagem) só serve de reserva para a DLQ quando o corpo não
# traz um event_id legível (JSON malformado).
#
# 1. Contrato agent_outbound (invariante 10, RNF-28). Fora dele: falha permanente, DLQ sem retentativa (RN-44)
#    e nenhum efeito no atendimento. Também é falha de contrato um payload que o Postgres não consegue gravar
#    em jsonb: `\u0000` em qualquer string, chave ou valor (07, seção 6, "payload fora do contrato"). Sem isso
#    a transação falharia sempre, o offset nunca seria confirmado e a partição travaria.
# 2. Atendimento pelo conversation_id (`tkt_<id>`), sempre com o brand_id da marca do payload (invariante 6).
#    Marca divergente ou atendimento inexistente: DLQ sem efeito e sem auditoria, porque não há atendimento
#    verificado onde gravá-la (07, seção 5.3; ADR-014; 07, seção 6, "payload fora do contrato").
# 3. Uma transação: marca o evento em processed_events (RN-47, invariante 3), depois trava a linha do
#    atendimento, lê o relógio do banco e confere as quatro condições da seção 3.4. A ordem das travas é
#    processed_events → atendimento; não há ciclo porque a ingestão, Turns::Open e DispatchDue travam só o
#    atendimento e nunca tocam processed_events, e cada ação trava apenas a própria chave (consumer, event_id). Grava a primeira ação recebida no turno, o resultado (`eligible → applied` condicional,
#    invariante 8) e a auditoria (RN-37, RF-54). Aplicada com texto para o cliente (`reply.text` ou
#    `resolution.text`), grava também a saída (bloco 05; 07, seções 3.1 passo 6 e 3.2): a mensagem `outbound`
#    com o próximo seq do atendimento travado, pelo canal e pela conta da última mensagem do cliente (RF-06),
#    a versão do contexto (`Ticket#bump_context_version!`), a entrega `pending` (delivery_id estável, RNF-15), o item `delivery.requested` no outbox e a auditoria
#    `delivery.requested`. Aplicada (com ou sem texto), zera progress_due_at e cancela a entrega do aviso de progresso
#    do ciclo que ainda estiver `pending` (RN-57; auditoria delivery.cancelled `resposta_aplicada`); a que já estiver
#    em `sending` fica para a conciliação. Rejeitada, duplicada ou inválida não grava saída.
# 4. Fora da transação (invariante 2): a DLQ pelo produtor do Karafka, se for o caso, o despertador do envio
#    (OutboxJob com o item delivery.requested; o envio HTTP é do worker) e depois o log JSON.
#    Erro de caractere do Postgres dentro da transação (defesa além da checagem do passo 1) também é
#    permanente e vai para a DLQ; qualquer outro erro de banco é transitório e sobe (o offset não é confirmado).
#
# 5. Handoff (bloco 10; RN-33, itens 1 e 6): a `escalate` aplicada pede o handoff `decisao_do_agente` com o resumo do
#    agente, sem saída ao cliente; cada `reply` aplicado soma uma troca em `tickets.ai_turns_count` e, no limite da
#    Handoff::Policy, pede `limite_de_trocas`; a `resolve` aplicada zera a contagem. O pedido sai na transação do
#    `applied` e o OutboxJob dele é acordado depois do commit; a auditoria `agent_action.applied` leva `handoff_event_id`.
#
# Fora do escopo aqui: o envio ao provedor (Deliveries::Send, no worker), o Escalate e o aviso de transferência
# (Handoff::Escalate) e o encerramento da `resolve` (RN-36).
module AgentActions
  class Apply
    Result = Data.define(:status, :reason, :turn)

    TOPICS = { outbound: "helpdesk.agent.outbound.v1", dlq: "helpdesk.agent.dlq.v1" }.freeze
    CONSUMER = "agent_actions".freeze
    DELIVERY_EVENT = "delivery.requested".freeze
    CANCEL_REASON = "resposta_aplicada".freeze
    CONTENT_FIELDS = %w[reply escalation resolution].freeze
    CONVERSATION_ID = /\Atkt_(?<id>[1-9]\d{0,18})\z/
    TRACEPARENT = /\A00-(?<trace_id>\h{32})-\h{16}-\h{2}\z/
    NUL = "\u0000".freeze
    # Erros do Postgres causados pelo conteúdo do payload: repetir não muda o resultado.
    UNSTORABLE = [ PG::UntranslatableCharacter, PG::CharacterNotInRepertoire ].freeze

    # Saída da transação: o que aconteceu e o que fazer depois do commit.
    # delivery_event_id: o item delivery.requested gravado, para acordar o worker depois do commit.
    # handoff_event_id: o pedido de handoff gravado (escalate ou limite de trocas), para acordar o Escalate.
    Outcome = Data.define(:status, :reason, :turn, :trace_id, :dead_letter, :delivery_event_id, :handoff_event_id) do
      def initialize(delivery_event_id: nil, handoff_event_id: nil, **) = super
    end

    def self.call(...) = new(...).call

    def initialize(payload, traceparent: nil, header_event_id: nil)
      @raw = payload.is_a?(String) ? payload : JSON.generate(payload)
      @traceparent = traceparent
      @header_event_id = header_event_id
    end

    def call
      violations = HelpdeskContracts.errors(:agent_outbound, @raw).map(&:to_h)
      violations = unstorable(JSON.parse(@raw)) if violations.empty?
      outcome = violations.any? ? invalid(violations) : decide
      dead_letter(outcome) if outcome.dead_letter
      notify_worker(outcome.delivery_event_id, outcome.trace_id) if outcome.delivery_event_id
      notify_worker(outcome.handoff_event_id, outcome.trace_id) if outcome.handoff_event_id
      log(outcome) # depois da confirmação da DLQ: se o Kafka recusar, o erro sobe sem logar dead_lettered
      Result.new(status: outcome.status, reason: outcome.reason, turn: outcome.turn)
    end

    private

    attr_reader :action

    # violations: [{ pointer:, type:, message: }], o mesmo formato do broker e do agent-mock em dlq_violations.
    def invalid(violations)
      @action = parse_loose
      Outcome.new(status: :invalid, reason: "contrato", turn: nil, trace_id: header_trace_id, dead_letter: violations)
    end

    # O jsonb do Postgres não aceita \u0000 em string nenhuma (chave ou valor). O ponteiro é o da string;
    # para uma chave, o do objeto que a contém.
    def unstorable(value, pointer = "")
      case value
      when Hash
        value.flat_map do |key, item|
          key.include?(NUL) ? [ nul_violation(pointer) ] : unstorable(item, "#{pointer}/#{key.gsub('~', '~0').gsub('/', '~1')}")
        end
      when Array then value.each_with_index.flat_map { |item, index| unstorable(item, "#{pointer}/#{index}") }
      when String then value.include?(NUL) ? [ nul_violation(pointer) ] : []
      else []
      end
    end

    def nul_violation(pointer)
      { pointer:, type: "conteudo_invalido", message: "caractere nulo (\\u0000), que o Postgres não grava em jsonb" }
    end

    def decide
      @action = JSON.parse(@raw)
      ActiveRecord::Base.transaction do
        ticket = find_ticket
        next ticket if ticket.is_a?(Outcome)
        next duplicate unless mark_processed

        # Travas: processed_events (acima) e depois o atendimento. Sem ciclo: quem trava o atendimento
        # (ingestão, Turns::Open, DispatchDue) não toca processed_events, e cada ação só trava a própria chave.
        @ticket = Ticket.lock.find_by!(id: ticket.id, brand_id: ticket.brand_id)
        @now = DatabaseClock.now # depois do lock (condição 4)
        @turn = @ticket.ai_turns.find_by(brand_id: @ticket.brand_id, turn: action.fetch("turn"))
        judge
      end
    rescue ActiveRecord::StatementInvalid => e
      raise unless UNSTORABLE.any? { e.cause.is_a?(_1) }

      invalid([ { pointer: "", type: "conteudo_invalido", message: "o Postgres recusou o conteúdo: #{e.cause.class.name}" } ])
    end

    # --- Correlação com o atendimento e a marca (ADR-014) ---

    def find_ticket
      brand = Brand.find_by(slug: action.fetch("brand"))
      return unroutable("marca_divergente") unless brand

      id = CONVERSATION_ID.match(action.fetch("conversation_id"))&.[](:id)
      return unroutable("turno_inexistente") unless id

      Ticket.find_by(id:, brand_id: brand.id) || unroutable(other_brand?(id, brand) ? "marca_divergente" : "turno_inexistente")
    end

    # Só a existência, sem ler nenhum dado do atendimento da outra marca: distingue o motivo na DLQ.
    def other_brand?(id, brand) = Ticket.where(id:).where.not(brand_id: brand.id).exists?

    def unroutable(reason)
      Outcome.new(status: :rejected, reason:, turn: nil, trace_id: header_trace_id, dead_letter: [])
    end

    # RN-47: a chave primária (consumer, event_id) decide. Uma entrega concorrente da mesma ação espera o
    # commit da primeira aqui e não encontra linha a inserir.
    def mark_processed
      ProcessedEvent.insert({ consumer: CONSUMER, event_id: action.fetch("event_id") },
                            returning: [ :event_id ]).rows.any?
    end

    def duplicate = Outcome.new(status: :duplicate, reason: nil, turn: nil, trace_id: header_trace_id, dead_letter: nil)

    # --- As quatro condições (07, seção 3.4; invariante 4) ---

    def judge
      return reject("turno_inexistente", record_response: false) unless @turn
      return reject("in_reply_to_divergente", record_response: false) if action.fetch("in_reply_to") != @turn.event_id

      reason = rejection_reason
      reason ? reject(reason) : apply
    end

    # A atribuição vem primeiro no motivo: depois de um handoff (bloco 08) o turno também fica `expired`, e a
    # ação atrasada deve aparecer como `atribuicao_mudou`/`fora_da_ia`, não como prazo vencido. O resultado
    # (rejeitar) é o mesmo em qualquer ordem.
    def rejection_reason
      assignment_reason || turn_reason || context_reason || deadline_reason || handoff_reason
    end

    # 1. Turno atual e elegível.
    def turn_reason
      return "turno_superado" if @turn.status == "superseded"
      return expired_reason if @turn.status == "expired"
      return "turno_nao_elegivel" unless @turn.eligible?

      "turno_superado" if @ticket.ai_turns.where(turn: (@turn.turn + 1)..).exists?
    end

    # Turno expirado pelo pedido de handoff de um gatilho que não é prazo (falha definitiva, DLQ, contexto): o motivo é o
    # pedido. Expirado pelo timeout, ou por um pedido de prazo: prazo_vencido.
    def expired_reason
      reason = Handoff::Request.pending_reason(@ticket)
      reason && !Handoff::Request::DEADLINE_REASONS.include?(reason) ? "handoff_pedido" : "prazo_vencido"
    end

    # 2. Mesma atribuição, que continua com a IA.
    def assignment_reason
      returned = action.fetch("assignment_version")
      return "atribuicao_mudou" if returned != @turn.assignment_version || @turn.assignment_version != @ticket.assignment_version

      "fora_da_ia" unless @ticket.with_ai?
    end

    # 5. RN-45, RN-46: pedido o handoff nesta atribuição, a IA já não responde. Fica por último: um turno expirado
    # ou vencido mostra o motivo do prazo. O pedido já expira os turnos eligible; isto é a defesa sob o mesmo lock.
    def handoff_reason
      "handoff_pedido" if Handoff::Request.pending?(@ticket)
    end

    # 3. Contexto devolvido igual ao persistido, e o persistido cobre a última mensagem do cliente.
    def context_reason
      return "contexto_divergente" if action.fetch("context_until_seq") != @turn.context_until_seq

      "turno_superado" if @turn.context_until_seq < @ticket.latest_customer_seq
    end

    # 4. Ciclo pendente e relógio do banco antes do prazo do turno, que nunca passa do teto do ciclo (RN-46).
    def deadline_reason
      return "ciclo_encerrado" unless @ticket.first_pending_seq

      deadline = [ @turn.deadline_at, @ticket.ai_deadline_at ].compact.min
      "prazo_vencido" if @now >= deadline
    end

    # --- Efeitos ---

    def apply
      applied = record_response(status: "applied", applied_event_id: action.fetch("event_id"))
      # Sob o lock não há corrida; se outro caminho mudar o turno sem o lock, a regra do banco decide.
      return reject("turno_nao_elegivel") unless applied

      # "Marca o turno applied, registra a ação final, limpa os prazos e cancela o aviso de progresso do ciclo que
      # ainda estiver pending" (07, seção 3.4; RN-57).
      cycle_seq = @ticket.first_pending_seq
      handoff = handoff_effects
      @ticket.update_columns(first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil,
                             progress_due_at: nil)
      audit("agent_action.applied", **handoff)
      cancel_progress_notice(cycle_seq)
      request_delivery
      outcome(:applied, nil)
    end

    # --- Handoff pela ação do agente (bloco 10; RN-33, itens 1 e 6; 07, seção 3.2) ---

    # Com o turno já `applied` (o Request só expira turnos eligible: não desfaz a ação final) e antes de limpar o
    # ciclo, para o pedido levar o first_pending_seq. Devolve o que entra na auditoria `agent_action.applied`.
    def handoff_effects
      case action.fetch("action")
      when "escalate"
        { handoff_event_id: request_handoff("decisao_do_agente", summary: action.dig("escalation", "summary")) }
      when "reply" then count_exchange
      when "resolve" then reset_exchanges
      else {}
      end
    end

    # RN-33, item 6. Uma troca é um turno com `reply` aplicado na atribuição atual da IA: escalate, resolve e
    # respostas rejeitadas não contam. A soma é no banco, com a linha travada e o escopo da marca (invariante 8);
    # ao chegar ao limite, o pedido sai na mesma transação. A 10ª resposta é gravada aqui também, com seq menor
    # que o do aviso de transferência, que só o Escalate grava, depois do commit (RN-42; 07, seção 3.2).
    def count_exchange
      count = update_exchanges("ai_turns_count = ai_turns_count + 1")
      limit = Handoff::Policy.for(@ticket.brand).exchanges_limit
      return { ai_turns_count: count } if count < limit

      { ai_turns_count: count, handoff_event_id: request_handoff("limite_de_trocas") }.compact
    end

    # RN-33, item 6 ("sem resolver"): a resolve aplicada encerra a sequência de trocas.
    def reset_exchanges = { ai_turns_count: update_exchanges("ai_turns_count = 0") }

    def update_exchanges(assignment)
      sql = Ticket.sanitize_sql_array([ "UPDATE tickets SET #{assignment} WHERE id = ? AND brand_id = ? RETURNING ai_turns_count",
                                        @ticket.id, @ticket.brand_id ])
      value = Ticket.connection.select_value(sql, "Ticket Exchanges")
      @ticket[:ai_turns_count] = value
      @ticket.clear_attribute_changes([ :ai_turns_count ])
      value
    end

    # Um pedido por atribuição (chave do Request): colisão devolve nil e não muda o applied.
    def request_handoff(reason, summary: nil)
      @handoff_event_id = Handoff::Request.call(ticket: @ticket, reason:, source: "agent", turn: @turn.turn, summary:,
                                                trace_id:)
    end

    # RN-57: o aviso do ciclo que ainda não saiu (pending) não vale mais. Um aviso em `sending` fica para a
    # conciliação (07, seção 3.2) e sai antes da resposta, que tem seq maior. O item do envio é concluído aqui,
    # na mesma transação, como o Deliveries::Send faz no cancelamento do eval.
    def cancel_progress_notice(cycle_seq)
      Delivery.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, kind: "progress", status: "pending",
                     ai_first_pending_seq: cycle_seq).find_each do |delivery|
        delivery.update!(status: "cancelled", lease_until: nil, last_error: CANCEL_REASON)
        OutboxEvent.where(brand_id: @ticket.brand_id, dedup_key: "delivery:#{delivery.delivery_id}", completed_at: nil)
                   .update_all(completed_at: Time.current, lease_until: nil, last_error: CANCEL_REASON)
        AuditEvent.create!(
          brand_id: @ticket.brand_id, ticket: @ticket, actor_type: "system", event_type: "delivery.cancelled", trace_id:,
          data: { delivery_id: delivery.delivery_id, seq: delivery.seq, kind: delivery.kind, reason: CANCEL_REASON,
                  first_pending_seq: cycle_seq, turn: @turn.turn }
        )
      end
    end

    # --- Saída ao cliente (bloco 05; 07, seção 3.1, passo 6, e seção 3.2; RF-06, RNF-14, RNF-15) ---

    # Texto para o cliente e o tipo da entrega. A escalate não tem texto: o aviso de transferência é do Escalate.
    def outgoing
      case action.fetch("action")
      when "reply" then [ action.dig("reply", "text"), "reply" ]
      when "resolve" then [ action.dig("resolution", "text"), "resolution" ]
      end
    end

    # Com o atendimento travado, na transação do `applied`: a mensagem com o próximo seq (a mesma regra da
    # ingestão, que também trava o atendimento: os seqs não colidem), a entrega `pending`, o item do outbox
    # que acorda o envio (invariante 2: nada de HTTP aqui) e a auditoria. Responde pelo canal e pela conta da
    # última mensagem do cliente (RF-06).
    def request_delivery
      text, kind = outgoing
      return unless text

      origin = last_customer_message
      seq = Message.where(ticket_id: @ticket.id, brand_id: @ticket.brand_id).maximum(:seq).to_i + 1
      message = Message.create!(
        brand_id: @ticket.brand_id, ticket: @ticket, direction: "outbound", author_type: "bot", body: text, seq:,
        channel: origin.channel, provider_account: origin.provider_account, external_id: nil, trace_id:, received_at: @now
      )
      # RN-55, RF-33: a saída visível muda o que a IA veria no próximo turno (07, seção 3.4). Linha travada.
      context_version = @ticket.bump_context_version!
      delivery = Delivery.create!(
        brand_id: @ticket.brand_id, ticket: @ticket, message:, seq:, channel: message.channel,
        provider_account: message.provider_account, kind:, status: "pending",
        ai_assignment_version: @turn.assignment_version, trace_id:
      )
      delivery.reload # delivery_id vem do padrão do banco
      @delivery_event = OutboxEvent.create!(
        brand_id: @ticket.brand_id, ticket: @ticket, event_type: DELIVERY_EVENT, dedup_key: "delivery:#{delivery.delivery_id}",
        payload: { delivery_id: delivery.delivery_id, ticket_id: @ticket.id, seq: }, trace_id:, next_attempt_at: Time.current
      )
      AuditEvent.create!(
        brand_id: @ticket.brand_id, ticket: @ticket, actor_type: "system", event_type: DELIVERY_EVENT, trace_id:,
        data: { delivery_id: delivery.delivery_id, message_id: message.id, seq:, kind:, turn: @turn.turn,
                context_until_seq: @turn.context_until_seq, context_version: }
      )
    end

    def last_customer_message
      Message.where(ticket_id: @ticket.id, brand_id: @ticket.brand_id, direction: "inbound", author_type: "customer")
             .order(seq: :desc).first!
    end

    def reject(reason, record_response: true)
      record_response(status: nil) if record_response
      audit("agent_action.rejected", reason:)
      outcome(:rejected, reason)
    end

    # 07, seção 4: `response` guarda a primeira ação recebida para o turno, aplicada ou descartada; a
    # aplicação é a atualização condicional `eligible → applied` (RN-56, invariante 8).
    def record_response(status:, applied_event_id: nil)
      scope = AiTurn.where(id: @turn.id, brand_id: @ticket.brand_id)
      sets = [ "response = COALESCE(response, :response::jsonb)",
               "response_received_at = COALESCE(response_received_at, :now)", "updated_at = :now" ]
      if status
        scope = scope.where(status: "eligible")
        sets += [ "status = :status", "applied_event_id = :applied_event_id" ]
      end
      changed = scope.update_all([ sets.join(", "), { response: @raw, now: @now, status:, applied_event_id: } ])
      @turn.reload
      changed == 1
    end

    def audit(event_type, **extra)
      agent = action.fetch("agent")
      AuditEvent.create!(
        brand_id: @ticket.brand_id, ticket: @ticket, actor_type: "agent", event_type:, trace_id:,
        agent_model: agent["model"], agent_version: agent["version"],
        data: {
          turn: action.fetch("turn"), event_id: action.fetch("event_id"), in_reply_to: action.fetch("in_reply_to"),
          action: action.fetch("action"), tool_calls: action.fetch("tool_calls", []),
          agent: agent.slice("model", "version", "config_hash"), timing: action["timing"],
          context_until_seq: action.fetch("context_until_seq"), classification: action["classification"],
          turn_status: @turn&.status, platform_received_at: @now.utc.iso8601(6)
        }.merge(content, extra).compact
      )
    end

    # RF-54: o conteúdo da ação como veio (só o que existir). `response` guarda só a primeira ação do turno;
    # sem isto, uma segunda ação rejeitada ficaria sem conteúdo na auditoria.
    def content = action.slice(*CONTENT_FIELDS).transform_keys(&:to_sym)

    def outcome(status, reason)
      Outcome.new(status:, reason:, turn: @turn, trace_id:, dead_letter: nil, delivery_event_id: @delivery_event&.id,
                  handoff_event_id: @handoff_event_id)
    end

    # --- Rastreio (RF-56) ---

    def header_trace_id = TRACEPARENT.match(@traceparent.to_s)&.[](:trace_id)

    # O trace do turno: o do traceparent ou, sem ele, o do evento do turno no outbox.
    def trace_id
      @trace_id ||= header_trace_id ||
                    (@turn && OutboxEvent.where(id: @turn.event_id, brand_id: @ticket.brand_id).pick(:trace_id)) ||
                    action.fetch("event_id").delete("-")
    end

    # --- Fora da transação (invariante 2) ---

    # Despertador do envio, como na ingestão. Se o Redis estiver fora, a entrega já está gravada e o item segue
    # aberto no outbox: a recuperação o reoferece (07, seção 6).
    # O mesmo vale para o pedido de handoff (escalate, limite de trocas).
    def notify_worker(event_id, trace_id)
      OutboxJob.perform_later(event_id)
    rescue StandardError => e
      JsonLog.warn("outbox.enqueue_failed", trace_id:, event_id:, error: e.class.name)
    end

    def log(outcome)
      JsonLog.info("agent_action.#{outcome.dead_letter ? 'dead_lettered' : outcome.status}",
                   trace_id: outcome.trace_id, event_id: field("event_id"), in_reply_to: field("in_reply_to"),
                   conversation_id: field("conversation_id"), turn: field("turn"), status: outcome.status,
                   reason: outcome.reason)
    end

    # RN-44, invariante 10: o corpo vai como chegou, para o supervisor ver e reprocessar (RF-37, bloco 09).
    # Sem retentativa da ação; se o Kafka recusar, o erro sobe e o offset não é confirmado. Sem conversation_id
    # em texto, vai sem chave: o WaterDrop recusa chave vazia ou que não é texto, e o erro travaria a partição.
    # Formato: contrato dead_letter (src/contracts/v1/schemas/dead_letter.json).
    def dead_letter(outcome)
      key = field("conversation_id")
      Karafka.producer.produce_sync(
        topic: TOPICS.fetch(:dlq), key: (key if key.is_a?(String) && !key.empty?), payload: @raw,
        headers: { "dlq_reason" => outcome.reason, "dlq_source" => "platform",
                   "dlq_violations" => JSON.generate(outcome.dead_letter), "event_id" => (field("event_id") || @header_event_id).to_s,
                   "traceparent" => @traceparent.to_s }
      )
    end

    def field(name) = action.is_a?(Hash) ? action[name] : nil

    def parse_loose
      JSON.parse(@raw.dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError, EncodingError
      nil
    end
  end
end
