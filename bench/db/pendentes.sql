-- Onde o outbox está parado: pendentes por tipo de evento e idade do mais antigo.
SELECT event_type,
       count(*) AS total,
       count(*) FILTER (WHERE completed_at IS NULL) AS pendentes,
       round(extract(epoch FROM now() - min(created_at) FILTER (WHERE completed_at IS NULL))::numeric) AS seg_mais_antigo
FROM outbox_events GROUP BY 1 ORDER BY pendentes DESC;
SELECT status, count(*) FROM ai_turns GROUP BY 1;
