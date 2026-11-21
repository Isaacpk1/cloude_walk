# Entrada de uma mensagem do cliente (invariante 1; 07, seção 3.1, passo 1).
#
#   Ingestion::Receive.call(normalized_message, provider_payload: webhook_cru)
#
# Uma transação só: identifica o cliente (RF-07, RN-01, RN-02, RN-05), cria ou trava o atendimento
# aberto do canal (RF-08, RN-03, RN-04, RN-09), deduplica (RNF-15), atribui o próximo `seq`, atualiza
# `latest_customer_seq` e os prazos do ciclo pendente (RN-55, RN-46) e grava auditoria (RF-54) e outbox
# (RNF-14). Nada externo acontece aqui dentro (invariante 2): quem chama só confirma ao provedor depois do
# retorno, isto é, depois do commit.
#
# Concorrência: o índice único da identidade e o do atendimento aberto decidem as corridas de criação.
# A linha do atendimento fica travada até o commit, então mensagens da mesma conversa entram em fila
# e a deduplicação é refeita com a trava (07, seção 3.4).
module Ingestion
  class Receive
    Result = Data.define(:status, :ticket, :message, :outbox_event_id) do
      def created? = status == :created
      def duplicate? = status == :duplicate
    end

    def self.call(...) = new(...).call

    def initialize(normalized, provider_payload:)
      @msg = HelpdeskContracts.validate!(:normalized_message, normalized)
      @provider_payload = provider_payload
    end

    def call
      result = persist
      notify_worker(result) if result.created?
      result
    end

    private

    def persist
      brand = Brand.find_by!(slug: @msg.fetch("brand"))

      ActiveRecord::Base.transaction do
        duplicate = find_duplicate(brand)
        next Result.new(status: :duplicate, ticket: duplicate.ticket, message: duplicate, outbox_event_id: nil) if duplicate

        customer = find_or_create_customer(brand)
        ticket, opened = lock_or_open_ticket(brand, customer)
        # Outra entrega do mesmo webhook pode ter sido gravada enquanto esperávamos a trava.
        duplicate = find_duplicate(brand)
        next Result.new(status: :duplicate, ticket: duplicate.ticket, message: duplicate, outbox_event_id: nil) if duplicate

        record(ticket, opened)
      end
    end

    # Depois do commit (invariante 2). Se o Redis estiver fora, a mensagem já está gravada e o item
    # segue aberto no outbox: a recuperação o reoferece (07, seção 6). O provedor recebe o 202.
    def notify_worker(result)
      OutboxJob.perform_later(result.outbox_event_id)
    rescue StandardError => e
      JsonLog.warn("outbox.enqueue_failed", trace_id:, event_id: result.outbox_event_id, error: e.class.name)
    end

    def channel = @msg.fetch("channel")
    def trace_id = @msg.fetch("trace_id")

    def find_duplicate(brand)
      Message.find_by(brand:, provider_account: @msg.fetch("provider_account"), channel:,
                      external_id: @msg.fetch("external_id"))
    end

    # RN-05: remetente desconhecido vira cliente não verificado. A corrida entre dois webhooks do
    # mesmo remetente novo é decidida pelo índice único da identidade (RN-02).
    def find_or_create_customer(brand)
      identity_attrs = { brand:, channel:, external_id: @msg.dig("sender", "channel_identity") }
      existing = CustomerIdentity.find_by(identity_attrs)
      return existing.customer if existing

      ActiveRecord::Base.transaction(requires_new: true) do
        customer = Customer.create!(brand:, display_name: unverified_name, verified: false)
        customer.identities.create!(identity_attrs)
        customer
      end
    rescue ActiveRecord::RecordNotUnique
      CustomerIdentity.find_by!(identity_attrs).customer
    end

    def unverified_name = "Cliente não verificado (#{channel} …#{@msg.dig('sender', 'channel_identity').last(4)})"

    # RN-03: um atendimento aberto por cliente e canal. A linha fica travada até o commit.
    def lock_or_open_ticket(brand, customer)
      ticket = Ticket.open.lock.find_by(customer:, channel:)
      return [ ticket, false ] if ticket

      created = ActiveRecord::Base.transaction(requires_new: true) do
        Ticket.create!(brand:, customer:, channel:, state: "novo", linked_ticket: ticket_to_link(customer),
                       evaluation: evaluation_account?(brand))
      end
      [ created, true ]
    rescue ActiveRecord::RecordNotUnique
      [ Ticket.open.lock.find_by!(customer:, channel:), false ]
    end

    # ADR-023, item 5: o atendimento aberto por uma conta de eval da marca nasce marcado, no mesmo commit da
    # primeira mensagem. O worker não publica o turno nem entrega a saída de um atendimento marcado.
    def evaluation_account?(brand)
      ProviderAccount.exists?(brand:, channel:, slug: @msg.fetch("provider_account"), evaluation: true)
    end

    # RN-09: o último atendimento fechado no mesmo canal. Senão, RN-04: um aberto em outro canal.
    def ticket_to_link(customer)
      Ticket.where(customer:, channel:, state: "fechado").order(id: :desc).first ||
        Ticket.open.where(customer:).where.not(channel:).order(id: :desc).first
    end

    def record(ticket, opened)
      seq = ticket.messages.maximum(:seq).to_i + 1
      message = ticket.messages.create!(
        brand_id: ticket.brand_id, provider_account: @msg.fetch("provider_account"), channel:, direction: "inbound",
        author_type: "customer", author_id: ticket.customer_id, body: @msg.dig("content", "text"),
        subject: @msg.dig("content", "subject"), attachments: @msg.dig("content", "attachments") || [],
        external_id: @msg.fetch("external_id"), seq:, trace_id:, provider_payload: @provider_payload,
        received_at: Time.iso8601(@msg.fetch("received_at"))
      )
      window = window_for(ticket)
      ticket.update!(latest_customer_seq: seq, **cycle_deadlines(ticket, seq, window))
      # RN-55, RF-33: a mensagem muda o que a IA veria. Mesma transação, linha travada (07, seção 3.4).
      context_version = ticket.bump_context_version!
      supersede_turns(ticket, seq)

      audit(ticket, "ticket.created", state: ticket.state, channel:, linked_ticket_id: ticket.linked_ticket_id) if opened
      # Invariante 7: a decisão de janela (RN-55) fica registrada junto do recebimento.
      audit(ticket, "message.received", message_id: message.id, seq:, channel:,
                                        provider_account: message.provider_account, external_id: message.external_id,
                                        first_pending_seq: ticket.first_pending_seq,
                                        dispatch_due_at: ticket.dispatch_due_at&.iso8601(3),
                                        ai_deadline_at: ticket.ai_deadline_at&.iso8601(3),
                                        window_ms: window&.in_milliseconds&.round,
                                        ceiling_at: ceiling_at(ticket), context_version:)
      notice = OutboxEvent.create!(
        brand_id: ticket.brand_id, ticket:, event_type: "message.received", trace_id:, next_attempt_at: Time.current,
        payload: { ticket_id: ticket.id, message_id: message.id, seq: }
      )

      Result.new(status: :created, ticket:, message:, outbox_event_id: notice.id)
    end

    # RN-55 (ADR-020): a janela do canal na política da marca. Canal sem parâmetro é erro (KeyError), não
    # janela padrão. Caso fora da IA não usa janela.
    def window_for(ticket)
      Turns::Policy.for(ticket.brand).window_for(ticket.channel) if ticket.with_ai?
    end

    # RN-55, RN-46 (07, seção 3.4; ADR-016, ADR-020): com a linha travada, a mensagem abre o ciclo pendente, se
    # não houver um, e empurra o fim da janela de agrupamento até o teto de 4 s. O `scheduler` abre o
    # turno quando dispatch_due_at vence. Caso fora da IA não ganha prazos da IA.
    def cycle_deadlines(ticket, seq, window)
      return {} unless window

      now = Time.current
      policy = Turns::Policy.for(ticket.brand)
      cycle = if ticket.first_pending_seq
        {}
      else
        { first_pending_seq: seq, first_pending_at: now, ai_deadline_at: Turns::Window.ai_deadline_at(first_pending_at: now, policy:) }
      end
      first_pending_at = cycle.fetch(:first_pending_at, ticket.first_pending_at)
      cycle.merge(dispatch_due_at: Turns::Window.dispatch_due_at(channel: ticket.channel, now:, first_pending_at:, policy:))
    end

    # Teto da janela do ciclo pendente (RN-55): first_pending_at + 4 s, para a auditoria.
    def ceiling_at(ticket)
      return unless ticket.with_ai? && ticket.first_pending_at

      (ticket.first_pending_at + Turns::Policy.for(ticket.brand).ceiling).utc.iso8601(3)
    end

    # RN-56, invariante 4: no mesmo commit, todo turno elegível que não cobre esta mensagem perde a
    # validade, mesmo antes de o turno seguinte sair (07, seção 3.4).
    def supersede_turns(ticket, seq)
      turns = ticket.ai_turns.eligible.where(context_until_seq: ...seq).pluck(:turn)
      return if turns.empty?

      ticket.ai_turns.where(turn: turns).update_all(status: "superseded", updated_at: Time.current)
      audit(ticket, "ai_turn.superseded", turns:, by_seq: seq)
    end

    def audit(ticket, event_type, **data)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket:, actor_type: "customer", actor_id: ticket.customer_id,
                         event_type:, trace_id:, data:)
    end
  end
end
