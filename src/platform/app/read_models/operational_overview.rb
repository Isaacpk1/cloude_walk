# RF-60, RNF-24, ADR-025: fotografia por marca e fila, sem o LIMIT da listagem humana.
# Só leitura. A coorte de 24 h inclui casos resolvidos e fechados; o estoque aberto não.
class OperationalOverview
  Row = Data.define(:brand_id, :brand_name, :queue_id, :queue_name, :open_count, :waiting_count,
                    :waiting_without_start, :average_wait_s, :max_wait_s, :outside_sla_count,
                    :cohort_count, :escalated_count) do
    def escalation_rate = cohort_count.zero? ? nil : 100.0 * escalated_count / cohort_count
  end
  GROUP = %i[brand_id queue_id].freeze

  attr_reader :now, :window_start

  def initialize(brand_ids:, now: Time.current)
    @brand_ids = brand_ids
    @now = now
    @window_start = now - 24.hours
  end

  def rows
    @rows ||= build_rows
  end

  private

  def tickets = Ticket.where(brand_id: @brand_ids)
  def opened = tickets.where.not(state: %w[resolvido fechado])
  def cohort = tickets.where(created_at: window_start..now)

  def build_rows
    brands = Brand.where(id: @brand_ids).pluck(:id, :name).to_h
    queues = HelpdeskQueue.where(brand_id: @brand_ids).includes(:current_version).index_by { [ _1.brand_id, _1.id ] }
    volume = opened.group(*GROUP).count
    waiting = waiting_metrics
    overdue = opened.where(sla_breached: true).or(opened.where(state: "aguardando_humano", sla_due_at: ..now)).group(*GROUP).count
    population = cohort.group(*GROUP).count
    escalated = cohort.where(id: AuditEvent.where(brand_id: @brand_ids, event_type: "ticket.escalated").select(:ticket_id)).group(*GROUP).count
    keys = (volume.keys + population.keys + queues.reject { |_, queue| queue.archived_at }.keys).uniq
    keys.map do |key|
      count, with_start, average_epoch, first_epoch = waiting.fetch(key, [ 0, 0, nil, nil ])
      Row.new(brand_id: key[0], brand_name: brands.fetch(key[0]), queue_id: key[1],
              queue_name: queues[key]&.current_version&.name || "Sem fila",
              open_count: volume.fetch(key, 0), waiting_count: count, waiting_without_start: count - with_start,
              average_wait_s: elapsed(average_epoch), max_wait_s: elapsed(first_epoch), outside_sla_count: overdue.fetch(key, 0),
              cohort_count: population.fetch(key, 0), escalated_count: escalated.fetch(key, 0))
    end.sort_by { [ _1.brand_name, _1.queue_name, _1.queue_id.to_i ] }
  end

  def waiting_metrics
    opened.where(state: "aguardando_humano").group(*GROUP)
          .pluck(*GROUP, Arel.sql("COUNT(*)"), Arel.sql("COUNT(sla_started_at)"),
                 Arel.sql("AVG(EXTRACT(EPOCH FROM sla_started_at))"), Arel.sql("MIN(EXTRACT(EPOCH FROM sla_started_at))"))
          .to_h { |brand_id, queue_id, *values| [ [ brand_id, queue_id ], values ] }
  end

  def elapsed(epoch) = epoch && [ now.to_f - epoch.to_f, 0.0 ].max
end
