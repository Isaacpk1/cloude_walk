module AgentMock
  # Normaliza texto para casar palavras-chave: minúsculas, sem acento, espaços simples.
  module Text
    module_function

    def normalize(text)
      text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.gsub(/\s+/, " ").strip
    end

    # Palavra ou expressão inteira: "pessoa" não casa com "pessoal".
    def include_term?(normalized_text, term)
      /(?<![[:alnum:]])#{Regexp.escape(normalize(term))}(?![[:alnum:]])/.match?(normalized_text)
    end

    # Formato brasileiro: 1234.5 → "1.234,50".
    def money(amount)
      integer, cents = format("%.2f", amount).split(".")
      "#{integer.reverse.scan(/\d{1,3}/).join('.').reverse},#{cents}"
    end
  end
end
