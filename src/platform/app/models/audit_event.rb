# Evento de auditoria (RF-54, RN-54). Só inserção: o banco recusa UPDATE e DELETE.
class AuditEvent < ApplicationRecord
  belongs_to :brand
  belongs_to :ticket, optional: true, inverse_of: :audit_events

  def readonly? = persisted?
end
