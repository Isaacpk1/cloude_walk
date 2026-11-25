-- Consultas que mais consomem tempo no banco durante o experimento (ms). Rode depois da carga.
\echo '== Top 15 por tempo total =='
SELECT calls, round(total_exec_time::numeric, 1) AS total_ms, round(mean_exec_time::numeric, 2) AS mean_ms,
       round(max_exec_time::numeric, 1) AS max_ms, rows, left(regexp_replace(query, '\s+', ' ', 'g'), 140) AS query
FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC LIMIT 15;

\echo '== Top 10 por tempo médio (mais de 20 chamadas) =='
SELECT calls, round(mean_exec_time::numeric, 2) AS mean_ms, round(max_exec_time::numeric, 1) AS max_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 140) AS query
FROM pg_stat_statements WHERE calls > 20 AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY mean_exec_time DESC LIMIT 10;

\echo '== Tabelas lidas sem índice (varreduras sequenciais) =='
SELECT relname, seq_scan, seq_tup_read, idx_scan, n_live_tup
FROM pg_stat_user_tables WHERE seq_scan > 100 ORDER BY seq_tup_read DESC LIMIT 10;

\echo == Consultas pesadas por chamada em outbox_events (blocos lidos por execução) ==
SELECT calls, round(mean_exec_time::numeric, 2) AS mean_ms,
       round((shared_blks_hit + shared_blks_read)::numeric / calls) AS blocos_por_chamada,
       left(regexp_replace(query, '\s+', ' ', 'g'), 110) AS query
FROM pg_stat_statements
WHERE query ILIKE '%outbox_events%' AND calls > 20
ORDER BY blocos_por_chamada DESC LIMIT 8;
