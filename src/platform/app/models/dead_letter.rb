# Espelho de uma mensagem do tópico de DLQ (07, seção 4; RF-37, RN-45, RN-48). Gravado pelo
# DeadLetters::Record, uma linha por topic/partition/offset.
#
# Retenção (RN-48, RNF-16): o banco recusa apagar uma linha com menos de RETENTION (gatilho
# dead_letters_retention). A limpeza dos registros antigos é pendência; o tópico guarda o mesmo prazo
# (infra/kafka/topics.yml, retention.ms).
class DeadLetter < ApplicationRecord
  # unknown: dlq_source ausente ou fora do contrato dead_letter (a mensagem é gravada mesmo assim).
  SOURCES = %w[broker agent-mock platform unknown].freeze
  OUTCOMES = %w[escalated audited uncorrelated].freeze
  RETENTION = 7.days

  belongs_to :brand, optional: true
  belongs_to :ticket, optional: true

  validates :source, inclusion: { in: SOURCES }
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
end
