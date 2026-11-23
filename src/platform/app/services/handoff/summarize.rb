# Resumo do handoff montado pela plataforma (RN-39, RN-40, RF-40, RF-41, RNF-06; 07, seção 3.2 "Resumo do handoff").
#
#   Handoff::Summarize.call(outbox_event_id) # => Result(status:, reason:)
#
# Chamado pelo OutboxJob para o item "handoff.summary", que o Escalate grava quando o pedido não trouxe o resumo do
# agente, com a chave `summary:<ticket>:<from_assignment_version>` e o payload
# `{ ticket_id, from_assignment_version, reason, escalated_at }`.
#
# Uma transação: trava o atendimento e depois o item (a ordem do resto do sistema), sempre na marca do item
# (invariante 6). Monta os cinco campos (HandoffSummary::FIELDS) a partir do histórico do atendimento: as mensagens
# do cliente e da IA, as consultas (`tool_calls`) que as ações do agente registraram nos turnos da atribuição que
# escalou (ai_turns.response) e o motivo do handoff em texto. Sem PII crua (RN-51): o nome vai mascarado e telefone,
# e-mail e documento saem do texto. Grava `HandoffSummary` com `source: platform`:
#
# - `available` com os campos; auditoria `handoff.summary_available` (`source`, `from_assignment_version`,
#   `ms_since_escalated`, `summary_id`);
# - `missing` com `missing_reason`: `historico_vazio` (nenhuma mensagem do cliente) ou `erro_ao_montar` (a montagem
#   falhou; roda num savepoint, para o erro não abortar a transação); auditoria `handoff.summary_missing`.
#
# A inserção é idempotente (ON CONFLICT DO NOTHING no índice único `(ticket_id, from_assignment_version)`): se o
# agente já gravou o resumo dele, ou outro worker gravou primeiro, não grava nem audita nada (`already_present`).
# O item é concluído na mesma transação, em todos os desfechos. `ms_since_escalated` usa o relógio do banco
# (DatabaseClock), lido depois do lock, contra o `escalated_at` do payload; nunca negativo.
#
# Nunca bloqueia nem desfaz o handoff (RN-40): não muda estado, fila nem atribuição do atendimento. Sem
# atendimento na marca do item (`atendimento_inexistente`, inclusive payload com atendimento de outra marca), o item
# encerra com `last_error` e sem efeito. Nada externo aqui (invariante 2).
module Handoff
  class Summarize
    EVENT_TYPE = "handoff.summary".freeze
    SOURCE = "platform".freeze
    Result = Data.define(:status, :reason)

    # RN-39, campo "motivo": o motivo do pedido (Handoff::Request::REASONS) em texto para o analista.
    REASON_TEXTS = {
      "prazo_do_turno" => "A IA não respondeu dentro do prazo do turno.",
      "teto_do_ciclo" => "O cliente esperou mais que o teto do ciclo sem resposta da IA.",
      "publicacao_falhou" => "A mensagem não pôde ser enviada ao agente de IA (falha definitiva na publicação).",
      "contexto_excede_limite" => "As mensagens pendentes passaram do limite de contexto da IA.",
      "falha_de_integracao" => "Falha de integração com o agente de IA (evento na DLQ).",
      "limite_de_trocas" => "A IA trocou o limite de mensagens sem resolver o atendimento.",
      "pedido_do_cliente" => "O cliente pediu para falar com um atendente.",
      "decisao_do_agente" => "O agente de IA decidiu escalar o atendimento."
    }.freeze

    QUOTE_LIMIT = 300
    FIELD_LIMIT = 1_000

    # RN-51: o que sai do texto. Documento (CPF, CNPJ) antes de telefone, que tem um número parecido de dígitos.
    EMAIL = /[\w.+-]+@[\w-]+(\.[\w-]+)+/
    DOCUMENT = %r{\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b|\b\d{2}\.?\d{3}\.?\d{3}/?\d{4}-?\d{2}\b}
    # O nome que a ingestão dá ao cliente sem cadastro (Ingestion::Receive#unverified_name).
    PROVISIONAL_NAME = /\ACliente não verificado \(/
    PHONE_CANDIDATE = /(?<![\w.,])\+?\(?\d[\d\s().-]{6,}\d(?![\w,])/

    def self.call(...) = new(...).call

    def initialize(outbox_event_id)
      @id = outbox_event_id
    end

    def call
      result = ActiveRecord::Base.transaction do
        @item = OutboxEvent.find_by(id: @id, event_type: EVENT_TYPE)
        next Result.new(status: :skipped, reason: nil) unless @item

        @ticket = Ticket.lock.find_by(id: @item.ticket_id || payload["ticket_id"], brand_id: @item.brand_id)
        @item.lock!
        next Result.new(status: :already_done, reason: nil) if @item.completed_at

        decide
      end
      log(result)
      result
    end

    private

    attr_reader :item, :ticket

    def payload = item.payload
    def from = payload["from_assignment_version"]

    def decide
      return discard("atendimento_inexistente") unless ticket
      return already_present if existing_summary?

      @now = DatabaseClock.now # depois do lock
      fields, missing_reason, error = assemble
      summary_id = insert(fields:, missing_reason:)
      return already_present unless summary_id

      complete
      if fields
        audit("handoff.summary_available", source: SOURCE, summary_id:)
        Result.new(status: :available, reason: nil)
      else
        audit("handoff.summary_missing", missing_reason:, summary_id:, error:)
        Result.new(status: :missing, reason: missing_reason)
      end
    end

    # O Escalate grava o resumo do agente com o mesmo lock do atendimento: sob o lock, a leitura é confiável. O
    # ON CONFLICT do insert é a defesa.
    def existing_summary?
      HandoffSummary.where(brand_id: ticket.brand_id, ticket_id: ticket.id, from_assignment_version: from).exists?
    end

    # Savepoint: um erro de banco na montagem não aborta a transação, que ainda grava o "sem resumo" (RN-40).
    def assemble
      fields = ActiveRecord::Base.transaction(requires_new: true) { build_fields }
      fields ? [ fields, nil, nil ] : [ nil, "historico_vazio", nil ]
    rescue StandardError => e
      [ nil, "erro_ao_montar", e.class.name ]
    end

    def insert(fields:, missing_reason:)
      row = { brand_id: ticket.brand_id, ticket_id: ticket.id, from_assignment_version: from, source: SOURCE,
              status: fields ? "available" : "missing", fields:, missing_reason:, trace_id: item.trace_id }
      HandoffSummary.insert_all([ row ], unique_by: %i[ticket_id from_assignment_version], returning: [ :id ])
                    .rows.first&.first
    end

    def already_present
      complete
      Result.new(status: :already_present, reason: nil)
    end

    def discard(reason)
      complete(last_error: reason)
      Result.new(status: :discarded, reason:)
    end

    def complete(last_error: nil) = item.update!(completed_at: Time.current, lease_until: nil, last_error:)

    # --- Montagem (RN-39) ---

    def build_fields
      customer_messages = messages.select { _1.author_type == "customer" && _1.direction == "inbound" }
      return if customer_messages.empty?

      fields = {
        "problema" => problem(customer_messages),
        "dados_cliente" => customer_data,
        "acoes_tomadas" => actions_taken,
        "motivo" => REASON_TEXTS.fetch(payload["reason"].to_s) { "Motivo do handoff: #{payload['reason']}." },
        "pendente" => pending(customer_messages)
      }
      fields.transform_values { _1.truncate(FIELD_LIMIT) }
    end

    def messages
      @messages ||= Message.where(brand_id: ticket.brand_id, ticket_id: ticket.id, internal: false).order(:seq).to_a
    end

    # RF-41: só conta como dito ao cliente o que não foi cancelado nem falhou (a escalação cancela as saídas que não
    # começaram, RN-38). As canceladas aparecem à parte, para o analista não supor que o cliente leu.
    # O aviso de progresso (RN-57) não é resposta: fica fora do resumo.
    def bot_messages = all_bot_messages.reject { undelivered_seqs.include?(_1.seq) }
    def cancelled_bot_messages = all_bot_messages.select { undelivered_seqs.include?(_1.seq) }
    def all_bot_messages = messages.select { _1.direction == "outbound" && _1.author_type == "bot" && !progress_seqs.include?(_1.seq) }

    def ticket_deliveries = @ticket_deliveries ||= Delivery.where(brand_id: ticket.brand_id, ticket_id: ticket.id).pluck(:seq, :kind, :status)
    def undelivered_seqs = @undelivered_seqs ||= ticket_deliveries.filter_map { |seq, _, status| seq if %w[cancelled failed].include?(status) }.to_set
    def progress_seqs = @progress_seqs ||= ticket_deliveries.filter_map { |seq, kind, _| seq if kind == "progress" }.to_set

    def problem(customer_messages)
      text = "Cliente relatou: #{quote(customer_messages.first.body)}"
      others = customer_messages.size - 1
      others.positive? ? "#{text} (mais #{others} #{others == 1 ? 'mensagem' : 'mensagens'} no histórico)" : text
    end

    def customer_data
      customer = ticket.customer
      parts = [ "Cliente #{mask_name(customer.display_name)} (#{customer.verified ? 'verificado' : 'não verificado'})",
                "canal #{ticket.channel}", "marca #{ticket.brand.name}" ]
      parts << "categoria #{ticket.category}" if ticket.category
      parts << "prioridade #{ticket.priority}" if ticket.priority
      parts.join(", ")
    end

    # Consultas registradas nas ações do agente da atribuição que escalou (07, seção 5.3: "isso alimenta o campo
    # ações já tomadas do resumo") e as respostas que a IA deu ao cliente.
    def actions_taken
      lines = tool_calls.map { |call| "Consultou #{call['tool']}#{hash_text(call['args'], '(', ')')}#{hash_text(call['result'], ' → ', '')}" }
      replies = bot_messages
      lines << "Respondeu ao cliente #{replies.size}x; última resposta: #{quote(replies.last.body)}" if replies.any?
      dropped = cancelled_bot_messages
      lines << "Resposta preparada e não entregue (cancelada no handoff): #{quote(dropped.last.body)}" if dropped.any?
      lines.empty? ? "A IA não registrou consultas nem respostas." : "#{lines.join('; ')}."
    end

    def tool_calls
      AiTurn.where(brand_id: ticket.brand_id, ticket_id: ticket.id, assignment_version: from).where.not(response: nil)
            .order(:turn).pluck(:response).flat_map { Array(_1["tool_calls"]) }
    end

    def pending(customer_messages)
      answered_until = bot_messages.map(&:seq).max.to_i
      open = customer_messages.select { _1.seq > answered_until }
      return "Confirmar com o cliente se a última resposta da IA resolveu o problema." if open.empty?

      "Responder ao cliente, sem resposta desde: #{open.map { quote(_1.body) }.join(' ')}"
    end

    def hash_text(hash, prefix, suffix)
      return "" unless hash.is_a?(Hash) && hash.any?

      "#{prefix}#{redact(hash.map { |key, value| "#{key}: #{value.is_a?(String) ? value : value.to_json}" }.join(', '))}#{suffix}"
    end

    # Todo texto vindo do cliente, da IA ou das consultas passa pelo redact (RN-51).
    def quote(text) = "«#{redact(text.to_s.squish).truncate(QUOTE_LIMIT)}»"

    # --- RN-51 ---

    # O nome provisório leva o fim da identidade do canal: também não sai.
    def mask_name(name) = provisional?(name) ? "sem nome informado" : name.to_s.split.map { "#{_1[0]}***" }.join(" ")

    def provisional?(name) = name.to_s.match?(PROVISIONAL_NAME)

    def redact(text)
      text = text.gsub(EMAIL, "[e-mail]").gsub(DOCUMENT, "[documento]")
      text = text.gsub(PHONE_CANDIDATE) { |match| match.count("0-9").between?(10, 13) ? "[telefone]" : match }
      name_parts.reduce(text) { |acc, part| acc.gsub(/(?<!\p{L})#{Regexp.escape(part)}(?!\p{L})/i, "#{part[0]}***") }
    end

    # Partes do nome do cliente que aparecem no texto. O nome provisório da ingestão ("Cliente não verificado
    # (chat …0021)") não é nome de pessoa: mascarar as palavras dele só estragaria o texto.
    def name_parts
      @name_parts ||= begin
        name = ticket.customer.display_name.to_s
        provisional?(name) ? [] : name.split.grep(/\A\p{L}{3,}\z/)
      end
    end

    # --- Auditoria e log ---

    def ms_since_escalated
      escalated_at = Time.iso8601(payload["escalated_at"].to_s)
      [ ((@now - escalated_at) * 1000).round, 0 ].max
    rescue ArgumentError
      nil
    end

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type:, trace_id: item.trace_id,
                         data: { outbox_event_id: item.id, from_assignment_version: from, reason: payload["reason"],
                                 ms_since_escalated: }.merge(data).compact)
    end

    # RN-51: só identificadores, estados e motivos.
    def log(result)
      return if result.status == :skipped

      JsonLog.info("handoff.summary_#{result.status}", trace_id: item.trace_id, outbox_event_id: item.id,
                                                       ticket_id: ticket&.id, reason: result.reason)
    end
  end
end
