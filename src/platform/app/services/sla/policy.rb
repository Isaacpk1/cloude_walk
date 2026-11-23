# Política de SLA de uma fila (RN-21, RN-22; 06, "SLA padrão por prioridade"): três prazos por prioridade,
# em segundos. `queue_versions.sla_policy` guarda só o que a fila sobrescreve:
#
#   { "alta" => { "first_response_s" => 300, "assume_s" => 900, "resolve_s" => 86400 } }
#
# O que faltar, ou vier inválido (zero, negativo, texto), cai no padrão da prioridade. Prioridade nula ou
# desconhecida vale média (RN-13). O prazo que ordena a fila humana é o de assunção após escalação (RN-22).
module Sla
  class Policy
    DEFAULTS = {
      "critica" => { "first_response_s" => 60, "assume_s" => 300, "resolve_s" => 4 * 3600 },
      "alta" => { "first_response_s" => 300, "assume_s" => 900, "resolve_s" => 24 * 3600 },
      "media" => { "first_response_s" => 900, "assume_s" => 3600, "resolve_s" => 48 * 3600 },
      "baixa" => { "first_response_s" => 3600, "assume_s" => 4 * 3600, "resolve_s" => 5 * 24 * 3600 }
    }.freeze

    def self.for(queue_version) = new(queue_version&.sla_policy)

    # A versão da fila que o caso registrou, na marca dele (invariante 6).
    def self.for_ticket(ticket)
      version = ticket.queue_id && ticket.queue_version &&
                QueueVersion.joins(:queue).find_by(queue_id: ticket.queue_id, version: ticket.queue_version,
                                                   queues: { brand_id: ticket.brand_id })
      self.for(version)
    end

    def initialize(overrides)
      @overrides = overrides.is_a?(Hash) ? overrides : {}
    end

    def first_response_seconds(priority) = seconds(priority, "first_response_s")
    def assume_seconds(priority) = seconds(priority, "assume_s")
    def resolve_seconds(priority) = seconds(priority, "resolve_s")

    private

    def seconds(priority, field)
      level = DEFAULTS.key?(priority) ? priority : "media"
      custom = @overrides.dig(level, field)
      custom.is_a?(Integer) && custom.positive? ? custom : DEFAULTS.fetch(level).fetch(field)
    end
  end
end
