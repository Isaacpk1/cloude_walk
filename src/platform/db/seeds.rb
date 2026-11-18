# Carrega os dados sintéticos do ambiente (RF-61). A semente vem de SEED (padrão 42).
require_relative "seeds/synthetic"

Seeds::Synthetic.call(
  seed: Integer(ENV.fetch("SEED", 42)),
  customers_per_brand: Integer(ENV.fetch("CUSTOMERS_PER_BRAND", 5))
)
