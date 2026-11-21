# Envio de uma saída ao provedor do chat (07, seção 3.1 passo 7 e seção 3.2; RF-06, RNF-14, RNF-15).
#
#   Deliveries::Send.call(outbox_event_id) # => Result(status:, next_attempt_at:)
#
# Chamado pelo OutboxJob para o item "delivery.requested". Duas transações curtas, com a chamada HTTP
# entre elas e fora de qualquer transação (invariante 2):
#
# 1. Autoriza (trava o atendimento e depois o item, a mesma ordem do resto do sistema). Só a primeira
#    saída aberta do atendimento, por seq, sai (07, seção 3.2). Uma tentativa com reserva vigente não é
#    repetida. Autorizada, a entrega vai a `sending`, com `attempts + 1` e `lease_until`; o despertador
#    do item fica no fim da reserva, para a recuperação retomar uma tentativa abandonada.
# 2. Chama o provedor com o mesmo corpo e o mesmo delivery_id (Idempotency-Key) em toda tentativa.
# 3. Aplica o resultado só se a entrega ainda for desta tentativa: 2xx → delivered com a confirmação;
#    4xx → failed (definitivo); 5xx, 429, timeout ou conexão → nova tentativa com backoff (RN-43). Cada
#    tentativa transitória é classificada na auditoria delivery.retry_scheduled (`outcome`):
#    - sem_efeito: a mensagem com certeza não foi processada (conexão recusada, DNS, tempo para abrir a
#      conexão; 503 ou 429 respondidos pelo provedor);
#    - incerto: pode ter sido processada (leitura esgotada, conexão cortada depois de enviar, outro 5xx,
#      2xx sem message_id).
#    Ao esgotar: todas sem efeito → failed `provedor_indisponivel` e a ordem avança; ao menos uma incerta
#    (ou abandonada sem retry_scheduled) → conciliação: a entrega fica em `sending` e a ordem do
#    atendimento para (07, seção 3.2).
#    Uma saída encerrada (delivered, failed ou cancelled) acorda a próxima saída aberta.
#
# A espera da retentativa é só um despertador: o horário que vale é outbox_events.next_attempt_at
# (ADR-016). Repetir a chamada é seguro: o estado da entrega no banco decide.
module Deliveries
  class Send
    EVENT_TYPE = "delivery.requested".freeze
    Result = Data.define(:status, :next_attempt_at)
    Attempt = Data.define(:delivery, :item, :number, :body, :secret, :headers)

    def self.call(...) = new(...).call

    def initialize(outbox_event_id, client: ChatClient.new, jitter: Policy::DEFAULT_JITTER)
      @id = outbox_event_id
      @client = client
      @jitter = jitter
      @wake = []
    end

    def call
      outcome = with_wakeups { authorize }
      return outcome if outcome.is_a?(Result)

      started = Time.current
      response = begin
        @client.deliver(provider_account: outcome.delivery.provider_account, body: outcome.body, secret: outcome.secret,
                        headers: outcome.headers)
      rescue ChatClient::Unreachable => e
        e
      end
      with_wakeups { conclude(outcome, response, duration_ms: ((Time.current - started) * 1000).round) }
    end

    private

    # --- Transação 1: autorização ---

    def authorize
      ActiveRecord::Base.transaction do
        item = OutboxEvent.find_by(id: @id)
        next result(:skipped) unless item && item.completed_at.nil?

        # Invariante 6: atendimento e entrega sempre pela marca do item.
        ticket = Ticket.lock.find_by(id: item.ticket_id, brand_id: item.brand_id)
        item.lock!
        next result(:skipped) if item.completed_at

        now = Time.current
        next Result.new(status: :not_due, next_attempt_at: item.next_attempt_at) if item.next_attempt_at > now

        delivery = ticket&.deliveries&.find_by(brand_id: item.brand_id, delivery_id: item.payload["delivery_id"])
        next discard(item, ticket) unless delivery

        decide(item, delivery, now)
      end
    end

    def decide(item, delivery, now)
      return already_closed(item, delivery) unless Delivery::OPEN.include?(delivery.status)
      return wait_previous(item, delivery, now) if previous_open?(delivery)
      return in_flight(item, delivery) if delivery.status == "sending" && delivery.lease_until && delivery.lease_until >= now
      return reconcile(item, delivery, error: delivery.last_error) if delivery.attempts >= Policy::MAX_ATTEMPTS

      prepared = Request.build(delivery)
      if prepared.error
        # Erro da própria plataforma (sem adaptador, sem conta, corpo fora do contrato): nada sai (RN-44).
        return failed(item, delivery, attempt: delivery.attempts, reason: "plataforma", http_status: nil, platform_error: prepared.error)
      end

      start_attempt(item, delivery, prepared, now)
    end

    def previous_open?(delivery)
      Delivery.open.where(brand_id: delivery.brand_id, ticket_id: delivery.ticket_id).where(seq: ...delivery.seq).exists?
    end

    def start_attempt(item, delivery, prepared, now)
      number = delivery.attempts + 1
      lease = now + Policy::LEASE
      delivery.update!(status: "sending", attempts: number, lease_until: lease)
      item.update!(attempts: item.attempts + 1, next_attempt_at: lease, lease_until: lease)
      audit(delivery, "delivery.sending", seq: delivery.seq, attempt: number)
      log(:info, "delivery.sending", delivery, attempt: number)
      Attempt.new(delivery:, item:, number:, body: prepared.body, secret: prepared.secret, headers: headers(delivery))
    end

    def headers(delivery)
      { "Idempotency-Key" => delivery.delivery_id, "X-Conversation-Id" => "tkt_#{delivery.ticket_id}",
        "X-Conversation-Seq" => delivery.seq.to_s, "traceparent" => traceparent(delivery) }
    end

    # W3C Trace Context (RF-56). O span deriva do delivery_id: igual em todas as tentativas.
    def traceparent(delivery)
      span = delivery.delivery_id.delete("-")
      trace = delivery.trace_id.to_s.match?(/\A\h{32}\z/) ? delivery.trace_id.downcase : span
      "00-#{trace}-#{span[0, 16]}-01"
    end

    # --- Transação 2: resultado da chamada ---

    def conclude(attempt, response, duration_ms:)
      ActiveRecord::Base.transaction do
        Ticket.lock.find_by!(id: attempt.delivery.ticket_id, brand_id: attempt.delivery.brand_id)
        delivery = Delivery.find_by!(id: attempt.delivery.id, brand_id: attempt.delivery.brand_id)
        item = OutboxEvent.lock.find_by!(id: attempt.item.id, brand_id: delivery.brand_id)
        # Outra tentativa retomou depois da reserva vencer: o resultado desta não vale mais.
        next superseded(delivery, attempt) unless delivery.status == "sending" && delivery.attempts == attempt.number

        classify(item, delivery, attempt.number, response, duration_ms:)
      end
    end

    # 503 e 429 do provedor significam "não processado" (07, seção 5.0): sem efeito, como a recusa da conexão.
    NOT_PROCESSED = [ 429, 503 ].freeze

    def classify(item, delivery, number, response, duration_ms:)
      if response.is_a?(Exception)
        return transient(item, delivery, number, error: response.message, no_effect: response.no_effect, http_status: nil)
      end

      message_id = response.body["message_id"]
      case response.status
      when 200..299
        unless message_id.is_a?(String) && message_id.present?
          return transient(item, delivery, number, error: "http #{response.status} sem message_id", no_effect: false,
                                                   http_status: response.status)
        end

        delivered(item, delivery, number, message_id, replayed: response.replayed, duration_ms:)
      when *NOT_PROCESSED then transient(item, delivery, number, error: "http #{response.status}", no_effect: true,
                                                                 http_status: response.status)
      when 400..499
        provider_error = response.body["error"].presence
        failed(item, delivery, attempt: number, reason: rejection_reason(response.status, provider_error), http_status: response.status,
                               provider_error:)
      else transient(item, delivery, number, error: "http #{response.status}", no_effect: false, http_status: response.status)
      end
    end

    def delivered(item, delivery, number, message_id, replayed:, duration_ms:)
      now = Time.current
      delivery.update!(status: "delivered", provider_message_id: message_id, delivered_at: now, lease_until: nil, last_error: nil)
      complete(item)
      audit(delivery, "delivery.delivered", seq: delivery.seq, attempt: number, provider_message_id: message_id, duration_ms:, replayed:)
      log(:info, "delivery.delivered", delivery, attempt: number, replayed:, duration_ms:)
      wake_next(delivery)
      result(:delivered)
    end

    def transient(item, delivery, number, error:, no_effect:, http_status:)
      if number >= Policy::MAX_ATTEMPTS
        return reconcile(item, delivery, error:) unless no_effect && earlier_attempts_without_effect?(delivery, number)

        return failed(item, delivery, attempt: number, reason: "provedor_indisponivel", http_status:, error:)
      end

      retry_at = Time.current + Policy.backoff(number, jitter: @jitter)
      delivery.update!(lease_until: nil, last_error: error)
      item.update!(next_attempt_at: retry_at, lease_until: nil, last_error: error)
      audit(delivery, "delivery.retry_scheduled", attempt: number, error:, outcome: no_effect ? "sem_efeito" : "incerto",
                                                  next_attempt_at: retry_at.utc.iso8601(3))
      log(:warn, "delivery.retry_scheduled", delivery, attempt: number, error:)
      Result.new(status: :retry_scheduled, next_attempt_at: retry_at)
    end

    # Cada tentativa anterior a `number` tem um delivery.retry_scheduled sem_efeito. Uma tentativa sem esse
    # registro (abandonada com a reserva vencida) ou incerta impede afirmar que nada chegou ao provedor.
    def earlier_attempts_without_effect?(delivery, number)
      attempts = AuditEvent.where(brand_id: delivery.brand_id, ticket_id: delivery.ticket_id, event_type: "delivery.retry_scheduled")
                           .where("data->>'delivery_id' = ? AND data->>'outcome' = 'sem_efeito'", delivery.delivery_id)
                           .distinct.pluck(Arel.sql("(data->>'attempt')::int"))
      (1...number).all? { attempts.include?(_1) }
    end

    # Resultado incerto depois de todas as tentativas: a entrega fica em `sending`, sem reserva, e a
    # ordem do atendimento para até a conciliação (07, seções 3.2 e 6). O item sai da recuperação.
    def reconcile(item, delivery, error:)
      delivery.update!(lease_until: nil, last_error: error)
      complete(item, last_error: "reconciliation_needed")
      audit(delivery, "delivery.reconciliation_needed", attempts: delivery.attempts)
      log(:warn, "delivery.reconciliation_needed", delivery, attempt: delivery.attempts)
      result(:reconciliation_needed)
    end

    # Motivos que o painel rotula (delivery.failed.reason). O código cru do provedor vai em provider_error.
    CONTRACT_ERRORS = %w[contrato_invalido idempotency_key_reutilizada].freeze

    def rejection_reason(status, provider_error)
      if status == 409 then provider_error == "seq_repetida" ? "seq_repetida" : "seq_anterior"
      elsif [ 401, 403 ].include?(status) then "assinatura"
      elsif status == 422 && CONTRACT_ERRORS.include?(provider_error) then "contrato"
      else "recusada_pelo_provedor"
      end
    end

    def failed(item, delivery, attempt:, reason:, http_status:, **detail)
      error = detail.values.compact.first || reason
      origin = http_status || (detail[:platform_error] ? "plataforma" : "sem resposta")
      delivery.update!(status: "failed", lease_until: nil, last_error: "#{error} (#{origin})")
      complete(item, last_error: reason)
      audit(delivery, "delivery.failed", attempt:, reason:, http_status:, **detail.compact)
      log(:warn, "delivery.failed", delivery, attempt:, reason:, http_status:)
      wake_next(delivery)
      result(:failed)
    end

    def superseded(delivery, attempt)
      log(:warn, "delivery.attempt_superseded", delivery, attempt: attempt.number, current_attempt: delivery.attempts)
      result(:superseded)
    end

    # --- Itens que não chamam o provedor ---

    def already_closed(item, delivery)
      complete(item)
      wake_next(delivery)
      result(:already_closed)
    end

    def wait_previous(item, delivery, now)
      item.update!(next_attempt_at: now + Policy::ORDER_RECHECK)
      log(:info, "delivery.waiting_previous", delivery)
      result(:waiting_previous)
    end

    def in_flight(item, delivery)
      item.update!(next_attempt_at: delivery.lease_until)
      result(:in_flight)
    end

    # Entrega que não existe na marca e no atendimento do item: nada sai, e o item é encerrado.
    def discard(item, ticket)
      complete(item, last_error: "entrega_inexistente")
      AuditEvent.create!(brand_id: item.brand_id, ticket_id: ticket&.id, actor_type: "system", event_type: "delivery.discarded",
                         trace_id: item.trace_id, data: { outbox_event_id: item.id, reason: "entrega_inexistente" })
      JsonLog.warn("delivery.discarded", trace_id: item.trace_id, outbox_event_id: item.id, reason: "entrega_inexistente")
      result(:discarded)
    end

    # --- Apoio ---

    # 07, seção 3.2: a sequência avança após confirmação, cancelamento ou rejeição definitiva. Só a
    # próxima saída aberta é acordada; ela acorda a seguinte quando se encerrar.
    def wake_next(delivery)
      following = Delivery.open.where(brand_id: delivery.brand_id, ticket_id: delivery.ticket_id).where("seq > ?", delivery.seq)
                          .order(:seq).first
      return unless following

      now = Time.current
      items = OutboxEvent.where(brand_id: delivery.brand_id, dedup_key: "delivery:#{following.delivery_id}", completed_at: nil)
      items.where("next_attempt_at > ?", now).update_all(next_attempt_at: now)
      @wake.concat(items.pluck(:id))
    end

    # Avisos ao worker só depois do commit (invariante 2). Se o Redis falhar, a recuperação reoferece.
    def with_wakeups
      outcome = yield
      wake = @wake
      @wake = []
      wake.each do |id|
        OutboxJob.perform_later(id)
      rescue StandardError => e
        JsonLog.warn("delivery.wake_failed", outbox_event_id: id, error: e.class.name)
      end
      outcome
    ensure
      @wake = []
    end

    def complete(item, last_error: nil)
      item.update!(completed_at: Time.current, lease_until: nil, last_error:)
    end

    def result(status) = Result.new(status:, next_attempt_at: nil)

    def audit(delivery, event_type, **data)
      AuditEvent.create!(brand_id: delivery.brand_id, ticket_id: delivery.ticket_id, actor_type: "system", event_type:,
                         trace_id: delivery.trace_id, data: { delivery_id: delivery.delivery_id }.merge(data))
    end

    # Invariante 13, RN-51: só identificadores e estados; nunca o texto nem o customer_ref.
    def log(level, event, delivery, **fields)
      JsonLog.public_send(level, event, trace_id: delivery.trace_id, delivery_id: delivery.delivery_id,
                                        ticket_id: delivery.ticket_id, seq: delivery.seq, status: delivery.status, **fields)
    end
  end
end
