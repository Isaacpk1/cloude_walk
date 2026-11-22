# Estado do resumo do handoff (RN-39, RN-40; 07, seção 3.2), da linha de handoff_summaries da escalação atual
# (mesma from_assignment_version do ticket.escalated). `status`: :available (os cinco campos, do agente ou da
# plataforma), :missing ("sem resumo", com o motivo) ou :pending (o worker ainda não gravou nada). O caso escala de
# qualquer jeito: o resumo nunca segura o handoff (RN-40). Campos e motivo são texto comum: o ERB escapa.
class ConversationView::HandoffSummary < Data.define(:status, :source, :fields, :missing_reason, :recorded_at,
                                                     :ms_since_escalated)
  STATUSES = %i[available missing pending].freeze

  FIELD_LABELS = {
    "problema" => "Problema relatado",
    "dados_cliente" => "Dados relevantes do cliente",
    "acoes_tomadas" => "Ações já tomadas e resultados",
    "motivo" => "Motivo da escalação",
    "pendente" => "O que está pendente"
  }.freeze

  SOURCE_LABELS = { "agent" => "do agente", "platform" => "da plataforma" }.freeze

  MISSING_REASONS = {
    "historico_vazio" => "histórico vazio, nada a resumir",
    "erro_ao_montar" => "erro ao montar o resumo"
  }.freeze

  PENDING = "Resumo pendente".freeze

  def self.pending = new(status: :pending)

  # `record`: a linha de handoff_summaries; `audit`: a auditoria handoff.summary_* correspondente, se houver.
  def self.from(record, audit = nil)
    return pending unless record

    new(status: record.status.to_sym, source: record.source, fields: record.fields, missing_reason: record.missing_reason,
        recorded_at: record.created_at, ms_since_escalated: audit&.data&.dig("ms_since_escalated"))
  end

  def initialize(status:, source: nil, fields: nil, missing_reason: nil, recorded_at: nil, ms_since_escalated: nil)
    raise ArgumentError, "estado do resumo desconhecido: #{status}" unless STATUSES.include?(status)

    super
  end

  def available? = status == :available
  def missing? = status == :missing
  def pending? = status == :pending

  def self.missing_reason_label(reason) = reason && MISSING_REASONS.fetch(reason, reason)
  def missing_reason_label = self.class.missing_reason_label(missing_reason)
  def source_label = SOURCE_LABELS.fetch(source, source)

  def label
    case status
    when :available then "Resumo disponível (#{source_label})"
    when :missing then "Sem resumo: #{missing_reason_label} (RN-40)"
    else PENDING
    end
  end

  # Os cinco campos na ordem da RN-39, com o rótulo; campo ausente aparece vazio.
  def field_rows = FIELD_LABELS.map { |key, label| [ label, fields.to_h[key].to_s ] }
end
