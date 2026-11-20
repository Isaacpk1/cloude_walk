# Relógio do Postgres. Prazos de negócio são conferidos com o horário do banco, lido depois de travar a
# linha (07, seção 3.4, condição 4): `clock_timestamp()` avança dentro da transação, ao contrário de `now()`,
# que para no início dela e ficaria atrasado depois da espera pelo lock.
module DatabaseClock
  module_function

  def now = ActiveRecord::Base.connection.select_value("SELECT clock_timestamp()")
end
