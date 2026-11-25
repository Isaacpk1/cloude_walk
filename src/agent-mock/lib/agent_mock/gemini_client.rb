require "json"
require "net/http"
require "uri"

module AgentMock
  # Cliente mínimo da API REST do Gemini (generateContent), sem gem (ADR-030). A chave vem só de GEMINI_API_KEY,
  # vai no cabeçalho x-goog-api-key e nunca é logada. Devolve o texto do primeiro candidato; qualquer falha vira Error.
  class GeminiClient
    Error = Class.new(StandardError)
    ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models".freeze

    def initialize(api_key: ENV["GEMINI_API_KEY"], timeout_s: 8)
      @api_key = api_key.to_s.strip
      @timeout_s = timeout_s
      raise Config::Invalid, "GEMINI_API_KEY ausente (AGENT_ENGINE=gemini)" if @api_key.empty?
    end

    def generate(model:, system:, prompt:, schema:, temperature:, max_output_tokens:)
      uri = URI("#{ENDPOINT}/#{model}:generateContent")
      response = post(uri, body(system:, prompt:, schema:, temperature:, max_output_tokens:))
      raise Error, "gemini_http_#{response.code}" unless response.is_a?(Net::HTTPSuccess)

      text = JSON.parse(response.body).dig("candidates", 0, "content", "parts", 0, "text")
      raise Error, "gemini_sem_texto" if text.to_s.strip.empty?

      text
    end

    private

    def body(system:, prompt:, schema:, temperature:, max_output_tokens:)
      {
        systemInstruction: { parts: [ { text: system } ] },
        contents: [ { role: "user", parts: [ { text: prompt } ] } ],
        generationConfig: { temperature:, maxOutputTokens: max_output_tokens, responseMimeType: "application/json",
                            responseSchema: schema }
      }
    end

    def post(uri, payload)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "x-goog-api-key" => @api_key)
      request.body = JSON.generate(payload)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: @timeout_s, read_timeout: @timeout_s) { _1.request(request) }
    end
  end
end
