# Turno superado (RN-56; 07, seção 3.4), lido da auditoria ai_turn.superseded que a ingestão grava no mesmo
# commit da mensagem nova do cliente: `{ turns: [n, ...], by_seq: m }`. Serve à linha do tempo (um evento
# "Turno superado" por turno) e à conversa (o card do turno diz por qual mensagem e quando).
#
# Horário: o da gravação da mensagem que superou (messages.created_at, na mesma transação da auditoria),
# para o evento ficar junto da "Gravação" dessa mensagem na linha do tempo. Sem a mensagem, o da auditoria.
# Isolamento por marca (invariante 6): auditoria e mensagens filtradas pelo brand_id do atendimento.
class TurnSupersededEvents
  EVENT_TYPE = "ai_turn.superseded".freeze

  Superseded = Data.define(:turn, :by_seq, :at, :trace_id)

  def initialize(ticket)
    @ticket = ticket
  end

  def for_turn(number) = by_turn[number]

  def events
    by_turn.values.map do |item|
      TimelineView::Event.new(
        kind: :turn_superseded, started_at: item.at, finished_at: item.at, ticket_id: @ticket.id.to_s,
        seq: item.by_seq, turn: item.turn, trace_id: item.trace_id, source: DataSource::SYSTEM,
        detail: "Turno #{item.turn} superado pela mensagem seq #{item.by_seq} em #{PanelClock.format(item.at, precise: true)}: " \
                "a resposta que chegar para ele é descartada (RN-56)"
      )
    end
  end

  private

  # O primeiro registro de cada turno vale: um turno só é superado uma vez (eligible → superseded).
  def by_turn
    @by_turn ||= audits.each_with_object({}) do |audit, acc|
      seq = audit.data["by_seq"]
      Array(audit.data["turns"]).each do |number|
        acc[number] ||= Superseded.new(turn: number, by_seq: seq, at: committed_at(seq) || audit.occurred_at,
                                       trace_id: audit.trace_id)
      end
    end
  end

  def audits
    AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: EVENT_TYPE).order(:occurred_at, :id)
  end

  def committed_at(seq)
    @committed ||= Message.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id).pluck(:seq, :created_at).to_h
    @committed[seq]
  end
end
