# Junta fontes com a interface do ConversationReader (#all, #find, #timeline).
# A primeira que encontrar o id responde; a lista mostra as fontes na ordem dada.
class CompositeSource
  def initialize(*sources) = @sources = sources

  def all = @sources.flat_map(&:all)
  def find(id) = first_answer { _1.find(id) }
  def timeline(id) = first_answer { _1.timeline(id) }

  private

  def first_answer
    @sources.each do |source|
      answer = yield source
      return answer if answer
    end
    nil
  end
end
