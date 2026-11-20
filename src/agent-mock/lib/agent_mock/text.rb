module AgentMock
  # Normaliza texto para casar palavras-chave: minúsculas, sem acento, espaços simples.
  module Text
    module_function

    def normalize(text)
      text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.gsub(/\s+/, " ").strip
    end

    # Palavra ou expressão inteira: "pessoa" não casa com "pessoal".
    def include_term?(normalized_text, term) = term_regexp(term).match?(normalized_text)

    # Posições (índice do caractere) de cada ocorrência do termo inteiro.
    def term_positions(normalized_text, term)
      normalized_text.to_enum(:scan, term_regexp(term)).map { Regexp.last_match.begin(0) }
    end

    def term_regexp(term) = /(?<![[:alnum:]])#{Regexp.escape(normalize(term))}(?![[:alnum:]])/

    # Formato brasileiro: 1234.5 → "1.234,50".
    def money(amount)
      integer, cents = format("%.2f", amount).split(".")
      "#{integer.reverse.scan(/\d{1,3}/).join('.').reverse},#{cents}"
    end
  end
end
