# Porta de leitura usada pelas telas de conversa e linha do tempo.
# Os controllers falam só com esta classe, nunca com a fonte. A fonte padrão junta os registros
# reais (RecordedConversations, bloco 02) e os exemplos sintéticos, com a mesma interface:
# #all, #find(id) e #timeline(id), devolvendo ConversationView e TimelineView.
class ConversationReader
  NotFound = Class.new(StandardError)

  class << self
    attr_writer :source

    # Sem memorizar a fonte padrão: cada leitura vê o seed atual, mesmo se ele rodar
    # depois de o servidor subir.
    def source = @source || CompositeSource.new(RecordedConversations.new, SyntheticConversations.new)

    def all = source.all
    def find(id) = source.find(id) || raise(NotFound, "conversa #{id} não encontrada")
    def timeline(id) = source.timeline(id) || raise(NotFound, "linha do tempo #{id} não encontrada")
  end
end
