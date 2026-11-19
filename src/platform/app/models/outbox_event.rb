# Item do outbox (invariante 2, ADR-016). O id é o event_id usado em todas as retentativas.
class OutboxEvent < ApplicationRecord
  belongs_to :brand
  belongs_to :ticket, optional: true
end
