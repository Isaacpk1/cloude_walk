# Abertura de um turno da IA pela ação "turn.dispatch" do outbox (07, seção 3.1, passo 3, e seção 3.4;
# RN-55; ADR-016).
#
#   Turns::Open.call(outbox_event_id) # => Result(status:, turn:, handoff_event_id:)
#
# A ingestão grava os prazos do ciclo no atendimento (dispatch_due_at, ai_deadline_at). Quando a janela
# de agrupamento vence, o scheduler grava a ação "turn.dispatch" no outbox e o worker chega aqui.
#
# Uma transação, com a linha do atendimento travada (antes do item, na mesma ordem da ingestão):
# revalida a ação e a encerra. Ou descarta com o motivo auditado, ou monta o contexto pela RN-49
# (Turns::ContextBuilder; pendentes acima do limite não abrem turno), grava o turno `eligible` com a
# versão e o digest do contexto (Turns::ContextDigest) e o seu evento no outbox (invariante 2)
# e zera dispatch_due_at. first_pending_* e ai_deadline_at ficam até a resposta aplicada (bloco 07).
# Nos descartes sem abertura possível até uma gravação nova (#settled, #refused) dispatch_due_at também zera.
# O evento fica pronto e imutável: as retentativas reenviam o mesmo conteúdo com o mesmo event_id
# (invariante 3). A publicação acontece depois, fora da transação.
#
# Triagem antes do primeiro turno (bloco 11; 07, seção 3.1, passo 2): se o caso ainda estiver `novo` (o worker do
# message.received não rodou), o Triage::Run roda aqui, sob o mesmo lock, antes de qualquer outra conferência.
# Triado para humano (fila sem IA ou categoria somente humana, RN-28), o turno não abre (`triaged_to_human`) e o
# ciclo já saiu encerrado pela triagem. Erro na triagem sobe: nada é gravado e a ação fica aberta para a nova
# tentativa; nenhum turno abre sem triagem, e o teto do ciclo (RN-46) leva o caso a um humano se a falha persistir.
module Turns
  class Open
    # `wake_ids`: outros itens gravados aqui (o aviso de transferência da triagem, RN-42), acordados depois do commit.
    Result = Data.define(:status, :turn, :handoff_event_id, :wake_ids) do
      def initialize(handoff_event_id: nil, wake_ids: [], **) = super
    end
    # Recusas que pedem o handoff na hora (RN-46, RN-49; ADR-020 item 3), com o motivo do pedido. As demais
    # recusas terminais (sem_prazo, prazo_vencido) ficam para o teto do ciclo (Deadlines::CycleTimeout).
    HANDOFF_REASONS = { "contexto_excede_limite" => "contexto_excede_limite", "contrato" => "publicacao_falhou" }.freeze

    DISPATCH_TYPE = Deadlines::DispatchDue::EVENT_TYPE
    EVENT_TYPE = "agent.event".freeze
    # Recusas terminais do ciclo atual (ver #refused). O painel lê a mesma lista.
    TERMINAL_REASONS = %w[sem_prazo prazo_vencido contexto_excede_limite contrato].freeze

    def self.call(...) = new(...).call

    def initialize(outbox_event_id)
      @outbox_event_id = outbox_event_id
    end

    def call
      ActiveRecord::Base.transaction do
        item = OutboxEvent.find(@outbox_event_id)
        # Ordem das travas igual à da ingestão: atendimento primeiro, depois o item. Escopo por marca (invariante 6).
        ticket = Ticket.lock(Ticket::ROW_LOCK).find_by!(id: item.ticket_id, brand_id: item.brand_id)
        item.lock!
        next Result.new(status: :already_done, turn: nil) if item.completed_at

        @ticket = ticket
        @item = item
        decide
      end
    end

    private

    attr_reader :ticket, :item

    def decide
      return settled(:triaged_to_human, reason: "triado_para_humano", state: ticket.state) if triaged_to_human?
      return settled(:skipped, reason: "fora_da_ia", state: ticket.state) unless ticket.with_ai?

      expected = item.payload["assignment_version"]
      if expected != ticket.assignment_version
        return not_opened(:stale_assignment, reason: "atribuicao_mudou", expected_version: expected,
                                             current_version: ticket.assignment_version)
      end

      # RN-46: com o handoff pedido nesta atribuição, o caso não volta para a IA enquanto o Escalate não roda.
      return settled(:handoff_requested, reason: "handoff_pedido") if Handoff::Request.pending?(ticket)

      covering = ticket.ai_turns.eligible.where(context_until_seq: ticket.latest_customer_seq...).order(:turn).last
      return settled(:covered, reason: "coberto", covered_by_turn: covering.turn) if covering

      window_closed? ? check_deadline : window_still_open
    end

    def triaged_to_human?
      return false unless ticket.state == "novo"

      triage = Triage::Run.call(ticket:, trace_id: item.trace_id)
      @wake_ids = triage.wake_ids
      triage.status == :triaged_to_human
    end

    def now = @now ||= Time.current
    def window_closed? = ticket.dispatch_due_at && ticket.dispatch_due_at <= now

    # Uma ação de versão anterior não encurta a janela da mensagem mais recente (07, seção 3.4).
    def window_still_open
      return not_opened(:no_window, reason: "sem_janela") unless ticket.dispatch_due_at

      not_opened(:window_open, reason: "janela_aberta", dispatch_due_at: iso(ticket.dispatch_due_at))
    end

    # RN-46, ADR-020: o teto do ciclo (ai_deadline_at) não reinicia. Vencido, o turno não abre.
    def check_deadline
      cycle_deadline_at = ticket.ai_deadline_at
      return refused(:expired, reason: "sem_prazo") unless cycle_deadline_at
      return refused(:expired, reason: "prazo_vencido", deadline_at: iso(cycle_deadline_at)) if now >= cycle_deadline_at

      open_turn
    end

    def open_turn
      context = ContextBuilder.call(ticket:, policy:, now:)
      # RN-49: pendentes acima do limite não abrem turno e o caso vai para humano (handoff pedido na recusa).
      # O histórico completo no handoff (resumo, RN-39) entra no bloco 10.
      if context.pending_chars > policy.pending_chars_limit
        return refused(:context_too_large, reason: "contexto_excede_limite", pending_chars: context.pending_chars,
                                           limit: policy.pending_chars_limit, pending_seqs: context.pending.map(&:seq))
      end

      event_id = SecureRandom.uuid
      number = ticket.ai_turns.maximum(:turn).to_i + 1
      payload = Envelope.new(ticket:, event_id:, turn: number, context:, deadline_at:).to_h
      # Invariante 10, RN-44: fora do contrato é falha permanente; nada sai e a ação não é repetida.
      violations = HelpdeskContracts.errors(:agent_inbound, payload)
      return refused(:invalid, reason: "contrato", violations: violations.map(&:pointer)) if violations.any?

      turn = create_turn(number, event_id, payload)
      dispatch_due_at = ticket.dispatch_due_at
      ticket.update_columns(dispatch_due_at: nil)
      complete_item
      audit_opened(turn, context, dispatch_due_at)
      Result.new(status: :opened, turn:)
    end

    # 07, seção 3.4: o turno guarda o mesmo `context` do evento, a versão do contexto do atendimento lida com
    # a linha travada e o digest canônico, para conferir depois que o enviado é o gravado.
    def create_turn(number, event_id, payload)
      context = payload.fetch("context")
      turn = ticket.ai_turns.create!(
        brand_id: ticket.brand_id, turn: number, context_until_seq: ticket.latest_customer_seq,
        assignment_version: ticket.assignment_version, context:, event_id:, status: "eligible", deadline_at:,
        context_version: ticket.context_version, context_digest: ContextDigest.call(context)
      )
      OutboxEvent.create!(id: event_id, brand_id: ticket.brand_id, ticket:, event_type: EVENT_TYPE, payload:,
                          trace_id: item.trace_id, next_attempt_at: now)
      turn
    end

    def audit_opened(turn, context, dispatch_due_at)
      audit("ai_turn.opened", turn: turn.turn, event_id: turn.event_id, context_until_seq: turn.context_until_seq,
                              context_version: turn.context_version, context_digest: turn.context_digest,
                              pending_seqs: context.pending.map(&:seq), history_seqs: context.history.map(&:seq),
                              channel: ticket.channel, window_ms: policy.window_for(ticket.channel).in_milliseconds.to_i,
                              pending_chars: context.pending_chars, context_chars: context.chars,
                              deadline_at: iso(deadline_at), dispatch_due_at: iso(dispatch_due_at))
    end

    # Desfechos em que nenhuma volta do scheduler abre turno sem uma gravação nova: dispatch_due_at zera na mesma
    # transação, para o scheduler não varrer o atendimento a cada volta e o painel não esperar um turno que não vem.
    # Uma mensagem nova do cliente volta a gravar dispatch_due_at pela ingestão, e um turno novo é tentado.
    # - coberto: um turno elegível já cobre latest_customer_seq; só uma mensagem nova pede outro.
    # - fora_da_ia: o caso está com humano; o ciclo da IA não continua (07, seção 3.3).
    # Ficam com dispatch_due_at: janela_aberta (a janela da mensagem mais nova ainda vale), sem_janela (já é nulo)
    # e atribuicao_mudou (o caso segue na IA com outra versão: a próxima volta emite uma chave nova e abre o turno).
    def settled(status, **data)
      ticket.update_columns(dispatch_due_at: nil)
      not_opened(status, **data)
    end

    # Recusa terminal do ciclo atual (TERMINAL_REASONS): além de zerar dispatch_due_at, o ciclo pendente fica
    # (first_pending_*, ai_deadline_at) para o timeout e o handoff (blocos 08 e 10). O painel mostra a recusa.
    # RN-46, RN-49: contexto_excede_limite e contrato pedem o handoff na mesma transação (origem `turns`).
    def refused(status, **data)
      handoff = HANDOFF_REASONS[data[:reason]]
      @handoff_event_id = Handoff::Request.call(ticket:, reason: handoff, source: "turns", trace_id: item.trace_id) if handoff
      settled(status, **data)
    end

    def not_opened(status, **data)
      complete_item
      audit("ai_turn.not_opened", **data)
      Result.new(status:, turn: nil, handoff_event_id: @handoff_event_id, wake_ids: @wake_ids || [])
    end

    def complete_item = item.update!(completed_at: now, lease_until: nil)

    # ADR-020: o turno tem 20 s desde a abertura, sem passar do teto do ciclo.
    def deadline_at
      @deadline_at ||= policy.turn_deadline_at(opened_at: now, cycle_deadline_at: ticket.ai_deadline_at)
    end

    def policy = @policy ||= Turns::Policy.for_ticket(ticket)
    def iso(time) = time&.utc&.iso8601(3)

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket:, actor_type: "system", event_type:, trace_id: item.trace_id,
                         data: { dispatch_id: item.id, cover_until_seq: item.payload["cover_until_seq"] }.merge(data))
    end
  end
end
