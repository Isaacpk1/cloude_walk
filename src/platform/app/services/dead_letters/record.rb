# Uma mensagem de helpdesk.agent.dlq.v1 na plataforma (RF-34, RF-37, RN-44, RN-45, RN-48; 07, seções 4 e 6;
# interface dos blocos 08 e 09, item 4).
#
#   DeadLetters::Record.call(topic:, partition:, offset:, payload:, headers:, key:)
#   # => Result(status: :recorded | :duplicate, dead_letter_id:, outcome:, handoff_event_id:)
#
# 1. Monta a vista do contrato dead_letter e a valida. Fora do contrato, grava mesmo assim (source `unknown` se a
#    origem não for conhecida) e não correlaciona: sem cabeçalhos confiáveis não há vínculo comprovado.
# 2. Saneia o que o Postgres não grava (a mensagem nunca pode travar a partição): bytes que não são UTF-8 passam
#    por `scrub` (U+FFFD) e o NUL vira o texto literal `\u0000`, no corpo (text) e nos cabeçalhos (jsonb). O corpo
#    saneado ganha o cabeçalho gravado `payload_sanitized` (`utf8_invalido`, `nul` ou os dois, separados por
#    vírgula) e a explicação em `error`; o original continua no tópico pela retenção (RN-48).
# 3. Uma transação: grava a linha (idempotente por topic/partition/offset: a reentrega não tem efeito novo),
#    correlaciona (DeadLetters::Correlation, sempre com brand_id) e, com o atendimento travado, aplica a RN-45:
#    - turno ainda válido (eligible, o mais novo, cobre a última mensagem do cliente, mesma atribuição, caso com a
#      IA e ciclo pendente): `escalated` e o pedido `handoff.requested` no outbox (`falha_de_integracao`, `dlq`),
#      com a chave da atribuição (dois DLQ do mesmo turno colidem e geram um pedido só) e a auditoria do pedido;
#    - senão: `audited` e auditoria `dead_letter.audited` com o motivo (07, seção 6, "DLQ de turno superado");
#    - sem correlação: `uncorrelated`, sem tocar o atendimento.
#    Com atendimento, a auditoria `dead_letter.recorded`. O handoff em si é do worker (Handoff::Escalate).
# 4. Depois do commit (invariante 2): acorda o worker com o pedido e loga em JSON sem o corpo (invariante 13).
#    Erro de banco sobe: o consumer não confirma o offset e a mensagem volta.
#
# O prazo do turno não é conferido: vencido sem handoff, o caso escala de qualquer jeito e o pedido do timeout usa
# a mesma chave (o primeiro vence).
module DeadLetters
  class Record
    Result = Data.define(:status, :dead_letter_id, :outcome, :handoff_event_id)

    HANDOFF_EVENT = "handoff.requested".freeze
    HANDOFF_REASON = "falha_de_integracao".freeze
    HANDOFF_SOURCE = "dlq".freeze
    UNKNOWN_REASON = "desconhecido".freeze
    NUL = "\u0000".freeze
    NUL_ESCAPED = '\u0000'.freeze # o texto literal \u0000, seis caracteres
    TRACEPARENT = AgentActions::Apply::TRACEPARENT

    def self.call(...) = new(...).call

    def initialize(topic:, partition:, offset:, payload:, headers:, key: nil)
      @topic = topic
      @partition = partition
      @offset = offset
      @raw = payload.to_s
      @headers = headers
      @key = key
      @notes = []
    end

    def call
      prepare
      result = ActiveRecord::Base.transaction { record }
      wake_worker(result.handoff_event_id) if result.handoff_event_id
      log(result)
      result
    end

    private

    # --- Vista e saneamento (fora da transação: só memória) ---

    def prepare
      @view = HelpdeskContracts::DeadLetter.view(headers: @headers, payload: @raw, key: @key)
      @sanitized = []
      unless @raw.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        @sanitized << "utf8_invalido"
        @notes << "corpo saneado: bytes que não são UTF-8 trocados por U+FFFD"
      end
      if @view["payload"].include?(NUL)
        @sanitized << "nul"
        @notes << "corpo saneado: NUL escapado como o texto \\u0000"
        @view["payload"] = @view["payload"].gsub(NUL, NUL_ESCAPED)
      end
      @envelope_violations = HelpdeskContracts.errors(:dead_letter, @view)
      @notes << "fora do contrato dead_letter: #{@envelope_violations.map(&:to_s).join('; ')}" if @envelope_violations.any?
    end

    def stored_headers
      stored = @headers.to_h.to_h { |name, value| [ clean(name.to_s), clean((value.is_a?(Array) ? value.first : value).to_s) ] }
      @sanitized.any? ? stored.merge("payload_sanitized" => @sanitized.join(",")) : stored
    end

    def header(name) = @view.fetch("headers")[name]

    def source
      value = header("dlq_source")
      DeadLetter::SOURCES.include?(value) && value != "unknown" ? value : "unknown"
    end

    def reason
      value = header("dlq_reason")
      value.is_a?(String) && !value.empty? ? clean(value) : UNKNOWN_REASON
    end

    def violations
      value = header("dlq_violations")
      value.is_a?(Array) ? deep_clean(value) : []
    end

    def event_id
      value = header("event_id")
      value.is_a?(String) && !value.empty? ? clean(value) : nil
    end

    def header_trace_id = TRACEPARENT.match(header("traceparent").to_s)&.[](:trace_id)

    def clean(text) = HelpdeskContracts::DeadLetter.text(text).gsub(NUL, NUL_ESCAPED)

    def deep_clean(value)
      case value
      when Hash then value.to_h { |k, v| [ clean(k.to_s), deep_clean(v) ] }
      when Array then value.map { deep_clean(_1) }
      when String then clean(value)
      else value
      end
    end

    # --- Transação ---

    def record
      @dead_letter_id = insert_dead_letter
      return duplicate unless @dead_letter_id

      @correlation = @envelope_violations.any? ? Correlation::Missing.new(reason: "cabecalhos_fora_do_contrato") : correlate
      @correlation.is_a?(Correlation::Found) ? judge : uncorrelated
    end

    # RNF-14: um valor que o driver recusa (ArgumentError, antes de ir ao banco) é conteúdo, não falha transitória.
    # Subir faria a partição reentregar a mesma mensagem sem fim; vira sem correlação, com a nota do erro.
    def correlate
      Correlation.call(@view)
    rescue ArgumentError => e
      Correlation::Missing.new(reason: "correlacao_falhou (#{e.message})")
    end

    def insert_dead_letter
      row = { topic: @topic, partition: @partition, offset: @offset, source:, reason:, event_id:, trace_id: header_trace_id,
              violations:, headers: stored_headers, payload: @view.fetch("payload"), created_at: Time.current }
      DeadLetter.insert_all([ row ], unique_by: %i[topic partition offset], returning: [ :id ], record_timestamps: false)
                .rows.first&.first
    end

    def duplicate
      existing = DeadLetter.where(topic: @topic, partition: @partition, offset: @offset).pick(:id, :outcome)
      Result.new(status: :duplicate, dead_letter_id: existing[0], outcome: existing[1], handoff_event_id: nil)
    end

    def uncorrelated
      @notes << "sem correlação: #{@correlation.reason}"
      finish("uncorrelated")
    end

    # RN-45 sob o lock do atendimento (a mesma ordem da ingestão e do AgentActions::Apply: dead_letters → atendimento).
    def judge
      @ticket = Ticket.lock(Ticket::ROW_LOCK).find_by!(id: @correlation.ticket_id, brand_id: @correlation.brand_id)
      @turn = AiTurn.find_by!(id: @correlation.turn_id, brand_id: @ticket.brand_id)
      invalid = invalid_reason
      invalid ? audit_only(invalid) : escalate
    end

    # As condições de turno válido do AgentActions::Apply (07, seção 3.4), sem o prazo.
    def invalid_reason
      return "turno_#{@turn.status}" unless @turn.eligible?
      return "turno_superseded" if newer_turn? || @turn.context_until_seq < @ticket.latest_customer_seq
      return "atribuicao_mudou" if @turn.assignment_version != @ticket.assignment_version
      return "fora_da_ia" unless @ticket.with_ai?

      "ciclo_encerrado" unless @ticket.first_pending_seq
    end

    def newer_turn? = AiTurn.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, turn: (@turn.turn + 1)..).exists?

    # Interface item 1: o pedido passa pelo caminho único (Handoff::Request): um por atribuição, pela chave
    # `handoff:<ticket_id>:<assignment_version>`, com a auditoria handoff.requested e o aviso de progresso encerrado.
    def escalate
      @handoff_event_id = Handoff::Request.call(ticket: @ticket, reason: HANDOFF_REASON, source: HANDOFF_SOURCE,
                                                turn: @turn.turn, trace_id:)
      finish("escalated")
    end

    def audit_only(invalid)
      audit("dead_letter.audited", dead_letter_id: @dead_letter_id, reason: invalid, turn: @turn.turn, source:,
                                   dlq_reason: reason, event_id:)
      finish("audited")
    end

    def finish(outcome)
      found = @ticket
      DeadLetter.where(id: @dead_letter_id).update_all(
        outcome:, brand_id: found&.brand_id, ticket_id: found&.id, turn: @turn&.turn, trace_id: found ? trace_id : header_trace_id,
        error: @notes.presence&.join("; ")
      )
      if found
        audit("dead_letter.recorded", dead_letter_id: @dead_letter_id, source:, reason:, outcome:, event_id:,
                                      turn: @turn.turn, topic: @topic, partition: @partition, offset: @offset)
      end
      Result.new(status: :recorded, dead_letter_id: @dead_letter_id, outcome:, handoff_event_id: @handoff_event_id)
    end

    def audit(event_type, data)
      AuditEvent.create!(brand_id: @ticket.brand_id, ticket: @ticket, actor_type: "system", event_type:, trace_id:, data:)
    end

    # O trace do traceparent ou, sem ele, o do evento do turno no outbox (RF-56).
    def trace_id
      @trace_id ||= header_trace_id ||
                    OutboxEvent.where(id: @turn.event_id, brand_id: @ticket.brand_id).pick(:trace_id) ||
                    @turn.event_id.delete("-")
    end

    # --- Depois do commit ---

    # Se o Redis estiver fora, o pedido segue aberto no outbox e a recuperação o reoferece (07, seção 6).
    def wake_worker(id)
      OutboxJob.perform_later(id)
    rescue StandardError => e
      JsonLog.warn("outbox.enqueue_failed", trace_id: @trace_id, event_id: id, error: e.class.name)
    end

    def log(result)
      JsonLog.info(result.status == :duplicate ? "dead_letter.duplicate" : "dead_letter.recorded",
                   trace_id: @trace_id || header_trace_id, dead_letter_id: result.dead_letter_id, topic: @topic,
                   partition: @partition, offset: @offset, source:, reason:, outcome: result.outcome,
                   ticket_id: @ticket&.id, turn: @turn&.turn, handoff_event_id: result.handoff_event_id,
                   correlation: (@correlation.reason if @correlation.is_a?(Correlation::Missing)))
    end
  end
end
