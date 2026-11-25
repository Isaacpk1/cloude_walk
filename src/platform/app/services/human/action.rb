# Base das ações do analista sobre o atendimento (bloco 14; 07, seção 3.6; RF-46, RF-48, RF-49). Cada ação roda em
# uma transação só, com a linha do atendimento travada e filtrada por brand_id (invariantes 1 e 6): confere que o
# atendimento é da marca, está com o analista e é dele, faz o efeito e audita (invariante 7). Nada externo dentro da
# transação (invariante 2): o envio ao canal é o item `delivery.requested` do outbox, acordado depois do commit.
module Human
  class Action
    Result = Data.define(:status, :reason, :delivery_event_id) do
      def initialize(delivery_event_id: nil, reason: nil, **) = super
    end
    REJECTED = :rejected
    HUMAN_STATES = %w[com_analista aguardando_cliente].freeze

    def self.call(...) = new(...).call

    def initialize(ticket_id:, brand_id:, user:, now: Time.current, **rest)
      @ticket_id = ticket_id
      @brand_id = brand_id
      @user = user
      @now = now
      @rest = rest
    end

    def call
      result = ActiveRecord::Base.transaction do
        @ticket = Ticket.lock(Ticket::ROW_LOCK).find_by(id: @ticket_id, brand_id: @brand_id)
        reason = rejection
        reason ? Result.new(status: REJECTED, reason:) : perform
      end
      wake(result.delivery_event_id) if result.delivery_event_id
      result
    end

    private

    # Motivo da recusa, ou nil. Atendimento de outra marca é "inexistente" (invariante 6, RNF-24).
    def rejection
      return "atendimento_inexistente" unless @ticket
      return "caso_fora_do_analista" unless HUMAN_STATES.include?(@ticket.state)
      return "nao_e_o_responsavel" unless @ticket.assignee_id == @user.id

      validate
    end

    def validate = nil

    def trace_id = @trace_id ||= SecureRandom.hex(16)

    def next_seq = Message.where(ticket_id: @ticket.id, brand_id: @ticket.brand_id).maximum(:seq).to_i + 1

    def origin
      @origin ||= Message.where(ticket_id: @ticket.id, brand_id: @ticket.brand_id, direction: "inbound", author_type: "customer")
                         .order(seq: :desc).first!
    end

    def create_message(text, internal:)
      Message.create!(brand_id: @ticket.brand_id, ticket: @ticket, direction: "outbound", author_type: "analyst",
                      author_id: @user.id, body: text, internal:, seq: next_seq, channel: origin.channel,
                      provider_account: origin.provider_account, external_id: nil, trace_id:, received_at: @now)
    end

    # Entrega ao cliente (RN-38): delivery_id estável, item no outbox com chave única e auditoria do pedido.
    def request_delivery(message, kind:)
      context_version = @ticket.bump_context_version!
      delivery = Delivery.create!(brand_id: @ticket.brand_id, ticket: @ticket, message:, seq: message.seq,
                                  channel: message.channel, provider_account: message.provider_account, kind:,
                                  status: "pending", trace_id:)
      delivery.reload # delivery_id vem do padrão do banco
      event = OutboxEvent.create!(brand_id: @ticket.brand_id, ticket: @ticket, event_type: "delivery.requested",
                                  dedup_key: "delivery:#{delivery.delivery_id}", trace_id:, next_attempt_at: @now,
                                  payload: { delivery_id: delivery.delivery_id, ticket_id: @ticket.id, seq: message.seq })
      audit("delivery.requested", delivery_id: delivery.delivery_id, message_id: message.id, seq: message.seq, kind:,
                                  context_version:)
      [ delivery, event ]
    end

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: @ticket.brand_id, ticket: @ticket, actor_type: "user", actor_id: @user.id, event_type:,
                         trace_id:, data: { user_id: @user.id, **data })
    end

    def wake(event_id)
      OutboxJob.perform_later(event_id)
    rescue StandardError => e
      JsonLog.warn("outbox.enqueue_failed", trace_id:, event_id:, error: e.class.name)
    end
  end
end
