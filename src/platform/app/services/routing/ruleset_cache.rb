# Cache do conjunto de regras por marca, no processo (ADR-013). A cada roteamento confere a versão atual da marca
# com uma consulta pelo índice único (brand_id, version); só relê as regras quando ela muda. Assim uma versão nova
# vale no roteamento seguinte, sem reinício (RF-16, RN-18, RNF-07). A identidade inclui id e created_at: um banco
# recriado sem reiniciar o processo (ids e versões de volta a 1) não reaproveita regras de outro conjunto.
module Routing
  class RulesetCache
    Entry = Data.define(:identity, :version, :rules, :default_queue_id)

    def initialize
      @entries = Concurrent::Map.new
    end

    # Versão atual da marca, ou nil sem conjunto. Só leitura.
    def fetch(brand)
      identity = RoutingRuleset.where(brand_id: brand.id).order(version: :desc).pick(:id, :version, :created_at)
      if identity.nil?
        @entries.delete(brand.id)
        return
      end

      cached = @entries[brand.id]
      return cached if cached&.identity == identity

      @entries[brand.id] = load(brand, identity)
    end

    def clear = @entries.clear

    private

    def load(brand, identity)
      row = RoutingRuleset.find_by!(id: identity.first, brand_id: brand.id)
      Entry.new(identity:, version: row.version, rules: row.rules.fetch("rules").deep_dup.freeze,
                default_queue_id: row.default_queue_id)
    end
  end
end
