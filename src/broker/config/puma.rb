# Carregado pelo `bundle exec puma` (docs/10, seção 6). Sem estado: escala com réplicas (07, seção 7).
port ENV.fetch("PORT", "4100")
threads_count = Integer(ENV.fetch("PUMA_THREADS", "5"))
threads threads_count, threads_count
