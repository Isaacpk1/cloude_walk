# Uma linha de dead_letters (07, seção 4; RF-37, RN-45, RN-48) no formato de leitura do painel. O corpo e os
# cabeçalhos vêm de fora (broker, agente, consumer): a tela os mostra como texto, com o escape do ERB. Os
# rótulos de origem, motivo e desfecho ficam aqui, num lugar só: a lista, o detalhe e o evento da linha do
# tempo (DeadLetterEvents, via TimelineView::Error) usam os mesmos.
class DeadLetterView < Data.define(:id, :created_at, :source, :reason, :event_id, :trace_id, :turn, :ticket_id, :brand_slug,
                                   :brand_name, :outcome, :violations, :headers, :payload, :error, :attempts,
                                   :reprocessed_at, :topic, :partition, :offset)
  SOURCES = {
    "broker" => "Broker (publicação para o agente)",
    "agent-mock" => "Agente (agent-mock)",
    "platform" => "Plataforma (aplicação da ação do agente)"
  }.freeze

  # Etapa do fluxo em que o evento foi desviado (motivo da falha por etapa, ROADMAP 09).
  STAGES = { "broker" => :publicacao, "agent-mock" => :agente, "platform" => :aplicacao }.freeze

  REASONS = {
    "contrato" => "Fora do contrato (RN-44, RNF-28)",
    "acao_invalida" => "Ação do agente fora do contrato agent_outbound",
    "marca_divergente" => "Marca da ação diferente da marca do atendimento (ADR-014)",
    "turno_inexistente" => "Sem atendimento na marca informada",
    "conteudo_invalido" => "Conteúdo que o Postgres não grava (ex.: \\u0000 numa string)"
  }.freeze

  OUTCOMES = {
    "escalated" => "Escalou o atendimento: turno ainda válido (RN-45)",
    "audited" => "Só auditado: o turno já tinha sido superado, aplicado ou expirado (RN-45)",
    "uncorrelated" => "Sem correlação confiável: nenhum atendimento alterado (RN-45)"
  }.freeze
  NO_OUTCOME = "Sem decisão registrada".freeze

  REPROCESSING = "Reprocessamento: bloco seguinte (RF-37 é S; a regra da RN-48 ainda não foi implementada)".freeze

  # Controle que não é quebra de linha nem tabulação: aparece escrito (\u0000), em vez de sumir na página.
  CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/

  def self.from(record)
    new(id: record.id, created_at: record.created_at, source: record.source, reason: record.reason, event_id: record.event_id,
        trace_id: record.trace_id, turn: record.turn, ticket_id: record.ticket_id, brand_slug: record.brand&.slug,
        brand_name: record.brand&.name, outcome: record.outcome, violations: Array(record.violations),
        headers: record.headers || {}, payload: record.payload, error: record.error, attempts: record.attempts,
        reprocessed_at: record.reprocessed_at, topic: record.topic, partition: record.partition, offset: record.offset)
  end

  def self.outcome_label(outcome) = OUTCOMES.fetch(outcome, outcome || NO_OUTCOME)

  def source_label = SOURCES.fetch(source, source)
  def reason_label = REASONS.fetch(reason, reason)
  def outcome_label = self.class.outcome_label(outcome)
  def stage = STAGES[source]
  def correlated? = !ticket_id.nil?

  def payload_text = self.class.printable(payload)
  def headers_text = self.class.printable(JSON.pretty_generate(headers))
  def violations_text = violations.empty? ? "nenhuma" : violations.join(", ")

  def self.printable(text)
    utf8 = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("�")
    utf8.gsub(CONTROL) { format("\\u%04X", _1.ord) }
  end
end
