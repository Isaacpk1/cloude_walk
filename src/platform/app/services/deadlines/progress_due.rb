# Aviso de progresso vencido (RN-57; 07, seção 3.4, "Regras de tempo" e "Registro dos prazos"; ADR-016). Uma volta
# do scheduler:
#
#   Deadlines::ProgressDue.call(now: Time.current, limit: 100) # => ids dos itens criados
#
# Numa transação, trava com FOR UPDATE SKIP LOCKED os atendimentos com progress_due_at <= now e ciclo pendente
# cuja chave do aviso ainda não está no outbox. Sob o lock, revalida pelo relógio do banco (lido depois das
# travas) e pelo estado: o caso continua com a IA e nenhuma resposta aplicada cobre o ciclo. Se vale, grava um
# `progress.notice` por atendimento. A chave identifica o atendimento e o ciclo (first_pending_seq): um aviso por
# ciclo, e um ciclo novo gera outra chave. O próprio item é o marcador da emissão: o scheduler não limpa
# progress_due_at (quem zera é o worker, Turns::ProgressNotice, ou a resposta aplicada). O índice único do
# dedup_key decide qualquer corrida que escape do SKIP LOCKED.
#
# Se não vale mais (fora da IA, resposta aplicada), zera progress_due_at e audita o descarte, para o atendimento
# não voltar a cada volta. Prazo ainda não vencido no relógio do banco: fica para a próxima volta.
#
# Depois do commit, acorda o worker pelo ID (invariante 2). Se o Redis falhar, o item segue aberto e a
# recuperação do outbox o reoferece (07, seção 6).
module Deadlines
  class ProgressDue
    EVENT_TYPE = "progress.notice".freeze
    AUDIT_EVENT = "progress.notice_scheduled".freeze
    DISCARD_EVENT = "progress.notice_discarded".freeze
    DEDUP_KEY_SQL = "'progress:' || tickets.id || ':' || tickets.first_pending_seq".freeze

    def self.call(...) = new(...).call

    def self.dedup_key(ticket_id, first_pending_seq) = "progress:#{ticket_id}:#{first_pending_seq}"

    # Resposta aplicada que cobre o ciclo (o ciclo começa em first_pending_seq), na marca do atendimento.
    def self.answered?(ticket, first_pending_seq)
      AiTurn.where(ticket_id: ticket.id, brand_id: ticket.brand_id, status: "applied")
            .where(context_until_seq: first_pending_seq..).exists?
    end

    def initialize(now:, limit:, brand_id: nil, ticket_ids: nil)
      @now = now
      @limit = limit
      @brand_id = brand_id
      @ticket_ids = ticket_ids
    end

    def call
      ids = ActiveRecord::Base.transaction { emit(due_tickets) }
      wake_worker(ids)
      ids
    end

    private

    attr_reader :now

    def due_tickets
      scope = Ticket.where(progress_due_at: ..now).where.not(first_pending_seq: nil)
      scope = scope.where(brand_id: @brand_id) if @brand_id
      scope = scope.where(id: @ticket_ids) if @ticket_ids
      scope.where("NOT EXISTS (SELECT 1 FROM outbox_events o WHERE o.dedup_key = #{DEDUP_KEY_SQL})")
           .order(:progress_due_at, :id).limit(@limit).lock("FOR UPDATE SKIP LOCKED").to_a
    end

    def emit(tickets)
      return [] if tickets.empty?

      db_now = DatabaseClock.now # depois das travas
      traces = trace_ids(tickets)
      tickets.filter_map do |ticket|
        next if ticket.progress_due_at > db_now

        reason = discard_reason(ticket)
        next discard(ticket, reason, traces.fetch(ticket.id)) if reason

        id = insert_item(ticket, traces.fetch(ticket.id))
        audit(ticket, AUDIT_EVENT, traces.fetch(ticket.id), outbox_event_id: id, delay_ms: ((now - ticket.progress_due_at) * 1000).round) if id
        id
      end
    end

    def discard_reason(ticket)
      return "fora_da_ia" unless ticket.with_ai?

      "resposta_aplicada" if self.class.answered?(ticket, ticket.first_pending_seq)
    end

    def discard(ticket, reason, trace_id)
      audit(ticket, DISCARD_EVENT, trace_id, reason:, source: "scheduler")
      ticket.update_columns(progress_due_at: nil)
      nil
    end

    # trace_id da primeira mensagem do ciclo (seq = first_pending_seq), da mesma marca.
    def trace_ids(tickets)
      Message.joins(:ticket).where(ticket_id: tickets.map(&:id))
             .where("messages.seq = tickets.first_pending_seq AND messages.brand_id = tickets.brand_id")
             .pluck(:ticket_id, :trace_id).to_h
    end

    def insert_item(ticket, trace_id)
      row = {
        brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: EVENT_TYPE, dedup_key: key(ticket),
        payload: payload(ticket), trace_id:, next_attempt_at: now, created_at: now
      }
      result = OutboxEvent.insert_all([ row ], unique_by: :index_outbox_events_on_dedup_key, returning: [ :id ],
                                               record_timestamps: false)
      result.rows.first&.first
    end

    def key(ticket) = self.class.dedup_key(ticket.id, ticket.first_pending_seq)

    def payload(ticket)
      { "ticket_id" => ticket.id, "first_pending_seq" => ticket.first_pending_seq,
        "assignment_version" => ticket.assignment_version, "progress_due_at" => ticket.progress_due_at.iso8601(3) }
    end

    # RF-54: o atraso entre o prazo e a emissão é a métrica do scheduler (ADR-016).
    def audit(ticket, event_type, trace_id, **data)
      AuditEvent.create!(
        brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type:, trace_id:,
        data: { dedup_key: key(ticket), first_pending_seq: ticket.first_pending_seq,
                assignment_version: ticket.assignment_version, progress_due_at: ticket.progress_due_at&.iso8601(3) }.merge(data)
      )
    end

    def wake_worker(ids)
      ids.each { OutboxJob.perform_later(_1) }
      JsonLog.info("scheduler.progress_registered", count: ids.size) if ids.any?
    rescue StandardError => e
      JsonLog.warn("outbox.enqueue_failed", source: "scheduler", count: ids.size, error: e.class.name)
    end
  end
end
