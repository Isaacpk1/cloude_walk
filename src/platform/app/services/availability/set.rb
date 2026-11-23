# Disponibilidade do analista (RF-27; 07, seção 3.5): `online`, `pausa` ou `offline`.
#
#   Availability::Set.call(user:, status:, now: Time.current) # => Result(status:, changed:)
#
# Pausa e offline não recebem casos novos (RN-30, RN-31). `status_changed_at` marca quando o status mudou, que é o
# "desde quando está offline" da devolução da RN-31, e por isso só muda quando o status muda de fato: repetir
# "offline" não reinicia o relógio dos 10 minutos. Trava a linha do usuário, grava e audita em cada marca das
# equipes dele (`ticket_id` nulo, RF-54).
module Availability
  class Set
    Result = Data.define(:status, :changed)

    def self.call(...) = new(...).call

    def initialize(user:, status:, now: Time.current)
      @user = user
      @status = status.to_s
      @now = now
    end

    def call
      raise ArgumentError, "disponibilidade desconhecida: #{@status}" unless User::STATUSES.include?(@status)

      ActiveRecord::Base.transaction do
        user = User.lock.find(@user.id)
        next Result.new(status: user.status, changed: false) if user.status == @status

        from = user.status
        user.update_columns(status: @status, status_changed_at: @now, updated_at: @now)
        audit(user, from)
        @user.reload
        Result.new(status: @status, changed: true)
      end
    end

    private

    def audit(user, from)
      trace_id = SecureRandom.hex(16)
      Team.joins(:team_memberships).where(team_memberships: { user_id: user.id }).distinct.pluck(:brand_id).each do |brand_id|
        AuditEvent.create!(brand_id:, ticket_id: nil, actor_type: "user", actor_id: user.id, trace_id:,
                           event_type: "analyst.availability_changed", data: { user_id: user.id, from:, to: @status })
      end
    end
  end
end
