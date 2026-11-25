# Atendimento (RF-08, RF-10). Um aberto por cliente e canal (RN-03), garantido pelo banco.
class Ticket < ApplicationRecord
  STATES = %w[novo em_triagem com_ia aguardando_humano com_analista aguardando_cliente resolvido fechado].freeze
  CHANNELS = CustomerIdentity::CHANNELS
  # 07, seção 3.3: mensagens nesses estados não vão para a IA.
  HUMAN_STATES = %w[aguardando_humano com_analista resolvido fechado].freeze
  # Trava da linha do atendimento (ADR-031). FOR NO KEY UPDATE continua exclusivo entre quem altera o atendimento, mas
  # não bloqueia quem só grava linhas filhas (FOR KEY SHARE das chaves estrangeiras: auditoria, mensagens, entregas).
  ROW_LOCK = "FOR NO KEY UPDATE".freeze

  belongs_to :brand
  belongs_to :customer
  belongs_to :queue, class_name: "HelpdeskQueue", optional: true
  belongs_to :assignee, class_name: "User", optional: true
  belongs_to :linked_ticket, class_name: "Ticket", optional: true
  has_many :messages, -> { order(:seq) }, dependent: :restrict_with_exception, inverse_of: :ticket
  has_many :ai_turns, -> { order(:turn) }, dependent: :restrict_with_exception, inverse_of: :ticket
  has_many :deliveries, -> { order(:seq) }, dependent: :restrict_with_exception, inverse_of: :ticket
  has_many :audit_events, -> { order(:occurred_at, :id) }, dependent: :restrict_with_exception, inverse_of: :ticket

  validates :channel, inclusion: { in: CHANNELS }
  validates :state, inclusion: { in: STATES }

  scope :open, -> { where.not(state: "fechado") }

  # Versão do contexto do próximo turno (07, seção 3.4, "Estado no atendimento"; RN-55, RF-33). Sobe 1 em toda
  # gravação que muda o que a IA veria: mensagem do cliente e saída visível ao cliente. Quem chama já travou a
  # linha, na mesma transação da gravação. A soma é feita no banco (`context_version + 1`), não no valor em
  # memória, então uma cópia desatualizada não perde incremento. Escopo por marca (invariante 6).
  def bump_context_version!
    sql = self.class.sanitize_sql_array([ <<~SQL.squish, id, brand_id ])
      UPDATE tickets SET context_version = context_version + 1 WHERE id = ? AND brand_id = ? RETURNING context_version
    SQL
    value = self.class.connection.select_value(sql, "Ticket Bump Context Version")
    raise ActiveRecord::RecordNotFound.new("atendimento #{id} não encontrado na marca #{brand_id}", self.class.name) unless value

    self[:context_version] = value
    clear_attribute_changes([ :context_version ])
    value
  end

  # O caso está com a IA: fora dos estados humanos e sem responsável ou com o bot. A atribuição ao bot
  # entra com a triagem (bloco 11): até lá, todo caso que não está com um humano vai para a IA.
  def with_ai?
    return false if HUMAN_STATES.include?(state)

    assignee.nil? || assignee.kind == "bot"
  end
end
