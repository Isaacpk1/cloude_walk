# Conjunto de regras de roteamento de uma marca, versionado inteiro (ADR-013): a lista ordenada de regras no formato
# do ADR-003 (esquema routing_rules v1 do src/contracts) e a fila padrão. Só inserção: cada mudança é uma versão nova
# e as antigas nunca são editadas (RN-20; o banco recusa UPDATE e DELETE). A versão atual é a maior da marca.
#
#   RoutingRuleset.publish!(brand:, rules:, default_queue:, created_by:) # => versão nova ou InvalidRules
class RoutingRuleset < ApplicationRecord
  # Conjunto recusado na publicação: fora do esquema (ADR-003) ou com fila fora da marca, inativa ou ausente
  # (RF-17, RN-15). `violations` traz cada motivo em texto, para o editor mostrar ao supervisor.
  class InvalidRules < StandardError
    attr_reader :violations

    def initialize(violations)
      @violations = violations
      super("conjunto de regras inválido: #{violations.join('; ')}")
    end
  end

  belongs_to :brand
  belongs_to :default_queue, class_name: "HelpdeskQueue"
  belongs_to :created_by, class_name: "User"

  def readonly? = persisted?

  def self.current_for(brand) = where(brand_id: brand.id).order(version: :desc).first

  def self.publish!(brand:, rules:, default_queue:, created_by:)
    rules = rules.deep_stringify_keys
    violations = HelpdeskContracts.errors(:routing_rules, rules).map(&:to_s)
    raise InvalidRules, violations if violations.any?

    transaction do
      # Serializa as publicações da marca: duas ao mesmo tempo viram versões seguidas, sem buraco nem duplicata
      # (RN-20). FOR NO KEY UPDATE não bloqueia quem só grava linhas que apontam para a marca (FK, FOR KEY SHARE),
      # como a ingestão. As filas são conferidas depois da trava, já com o estado que vai valer.
      Brand.lock("FOR NO KEY UPDATE").find(brand.id)
      violations = queue_violations(brand, rules, default_queue)
      raise InvalidRules, violations if violations.any?

      version = where(brand_id: brand.id).maximum(:version).to_i + 1
      create!(brand:, version:, rules:, default_queue:, created_by:)
    end
  end

  # RF-17, RN-15: a fila padrão existe, e ela e toda queue_id das regras são filas ativas da mesma marca.
  def self.queue_violations(brand, rules, default_queue)
    ids = rules["rules"].map { _1["queue_id"] }
    queues = HelpdeskQueue.where(brand_id: brand.id, id: [ *ids, default_queue&.id ].compact).index_by(&:id)
    violations = []
    default = default_queue && queues[default_queue.id]
    violations << "a fila padrão é obrigatória e deve ser uma fila ativa da marca" unless default&.active?
    rules["rules"].each_with_index do |rule, index|
      queue = queues[rule["queue_id"]]
      label = "regra #{index + 1} «#{rule['name']}»"
      if queue.nil?
        violations << "#{label}: a fila #{rule['queue_id']} não existe na marca #{brand.slug}"
      elsif !queue.active?
        violations << "#{label}: a fila #{queue.id} está inativa"
      end
    end
    violations
  end
  private_class_method :queue_violations
end
