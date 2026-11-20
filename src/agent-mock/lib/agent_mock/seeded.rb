require "digest"
require "json"

module AgentMock
  # Números pseudoaleatórios derivados de (semente, partes). Não dependem da ordem de chegada
  # dos eventos nem da partição: mesma entrada + mesma semente = mesmo número (RNF-30).
  module Seeded
    module_function

    def integer(seed, *parts) = Digest::SHA256.hexdigest(JSON.generate([ seed, *parts ])).to_i(16)
    def random(seed, *parts) = Random.new(integer(seed, *parts) % (2**64))
  end
end
