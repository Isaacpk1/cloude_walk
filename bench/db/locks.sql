-- Uma amostra: quem espera lock, por quanto tempo, e quem está bloqueando (para rodar em laço durante o pico).
SELECT now()::time(0) AS hora,
       a.pid, a.wait_event_type AS espera, a.wait_event AS evento,
       round(extract(epoch FROM now() - a.query_start)::numeric, 1) AS seg,
       pg_blocking_pids(a.pid) AS bloqueado_por,
       left(regexp_replace(a.query, '\s+', ' ', 'g'), 90) AS consulta
FROM pg_stat_activity a
WHERE a.datname = 'helpdesk_benchmark' AND a.pid <> pg_backend_pid()
  AND (a.wait_event_type = 'Lock' OR a.state = 'idle in transaction')
ORDER BY seg DESC NULLS LAST
LIMIT 12;
