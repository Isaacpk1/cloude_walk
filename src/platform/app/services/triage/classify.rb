# Triagem por palavras-chave (RF-12; RN-11 a RN-13). Pura leitura da política, sem efeito.
#
#   Triage::Classify.call(brand:, text:) # => Classification(category:, priority:, tags:, matched:, unclassified:)
#
# O texto é comparado sem acento, sem maiúsculas e sem apóstrofo, palavra inteira ("pixel" não é Pix), com as
# palavras do idioma da marca (Triage::Policy). A categoria é a que tem mais palavras no texto; o empate fica com a
# primeira da política (as mais específicas vêm antes). A prioridade é a mais alta entre a base da categoria e as
# palavras de impacto (RN-12). Sem categoria, vale a RN-13: outros, média, `unclassified`. `matched` lista as
# palavras que decidiram categoria e prioridade, para a auditoria.
module Triage
  class Classify
    Classification = Data.define(:category, :priority, :tags, :matched, :unclassified)

    def self.call(...) = new(...).call

    def initialize(brand:, text:)
      @policy = Policy.for(brand)
      @locale = brand.locale
      @text = normalize(text)
    end

    def call
      category, category_words = best_category
      return unclassified if category.nil?

      impact_words = @policy.impact_for(@locale).transform_values { hits(_1) }.reject { |_, words| words.empty? }
      priority = @policy.highest([ @policy.base_priority.fetch(category), *impact_words.keys ])
      Classification.new(category:, priority:, tags:, matched: (category_words + impact_words.values.flatten).uniq,
                         unclassified: false)
    end

    private

    def best_category
      scored = @policy.keywords_for(@locale).map { |category, words| [ category, hits(words) ] }
      best = scored.max_by.with_index { |(_, words), index| [ words.size, -index ] }
      best if best && best.last.any?
    end

    def tags = @policy.tags_for(@locale).select { |_, words| hits(words).any? }.keys

    def unclassified
      Classification.new(category: @policy.fallback_category, priority: @policy.fallback_priority, tags:, matched: [],
                         unclassified: true)
    end

    def hits(words) = words.select { |word| @text.match?(/(?<![a-z0-9])#{Regexp.escape(word)}(?![a-z0-9])/) }

    def normalize(text) = I18n.transliterate(text.to_s.delete("'’")).downcase.squish
  end
end
