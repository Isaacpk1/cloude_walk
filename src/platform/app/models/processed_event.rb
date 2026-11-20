# Evento já processado por um consumidor (07, seção 4; RN-47, RNF-15). Chave primária composta
# (consumer, event_id). Gravado na mesma transação do efeito (invariante 3).
class ProcessedEvent < ApplicationRecord
  self.primary_key = [ :consumer, :event_id ]
end
