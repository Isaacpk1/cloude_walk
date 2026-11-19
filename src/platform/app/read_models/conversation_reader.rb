# Porta de leitura usada pelas telas de conversa e linha do tempo.
# Os controllers falam só com esta classe, nunca com a fonte. Hoje a fonte é
# SyntheticConversations; no bloco 02+ entra um adaptador dos registros reais com
# a mesma interface: #all, #find(id) e #timeline(id), devolvendo ConversationView e TimelineView.
class ConversationReader
  NotFound = Class.new(StandardError)

  class << self
    attr_writer :source

    # Sem memorizar a fonte padrão: cada leitura vê o seed atual, mesmo se ele rodar
    # depois de o servidor subir.
    def source = @source || SyntheticConversations.new

    def all = source.all
    def find(id) = source.find(id) || raise(NotFound, "conversa #{id} não encontrada")
    def timeline(id) = source.timeline(id) || raise(NotFound, "linha do tempo #{id} não encontrada")
  end
end
