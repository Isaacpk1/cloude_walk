-- Turnos por minuto: quantos abriram, quantos tiveram resposta aplicada, quantos expiraram, e quanto tempo a resposta
-- levou do turno aberto até chegar à plataforma (fila dentro do agente + processamento do agente + volta pelo Kafka).
-- Se "chegou_s" cresce enquanto "abertos" passa da capacidade do agente, o gargalo é o agente, não a plataforma.
SELECT date_trunc('minute', t.created_at)::time(0) AS minuto,
       count(*) AS abertos,
       count(*) FILTER (WHERE t.status = 'applied') AS aplicados,
       count(*) FILTER (WHERE t.status = 'expired') AS expirados,
       count(*) FILTER (WHERE t.status = 'superseded') AS superados,
       count(t.response_received_at) AS com_resposta,
       round(avg(extract(epoch FROM t.response_received_at - t.created_at))::numeric, 1) AS chegou_s_media,
       round((percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch FROM t.response_received_at - t.created_at)))::numeric, 1) AS chegou_s_p95,
       round(avg(((t.response->'timing'->>'agent_ms')::numeric) / 1000), 1) AS agente_s_media
FROM ai_turns t
GROUP BY 1 ORDER BY 1;

-- Motivos de handoff (ADR-035: agente_sem_vaga = a plataforma transferiu antes do prazo porque o agente estava cheio).
SELECT payload->>'reason' AS motivo, count(*) FROM outbox_events WHERE event_type = 'handoff.requested' GROUP BY 1 ORDER BY 2 DESC;
