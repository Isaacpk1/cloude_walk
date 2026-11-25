# Observabilidade do experimento (ADR-009, ADR-029)

```powershell
docker compose -p helpdesk-bench -f docker-compose.yml -f docker-compose.bench.yml -f docker-compose.observability.yml up -d --wait
```

- Grafana http://localhost:3001 (admin / admin): painel **Help desk: sinais de ouro** (latência p95 por ação, tráfego, 5xx, outbox, turnos, entregas, DLQ).
- Prometheus http://localhost:9090 lê `web:3000/metrics` a cada 15 s. `METRICS_TOKEN` (opcional) exige `Authorization: Bearer`.
- Jaeger http://localhost:16686 recebe traces OTLP.

## Ligar traces (OpenTelemetry)

```powershell
docker compose run --rm web bundle add opentelemetry-sdk opentelemetry-exporter-otlp opentelemetry-instrumentation-all
docker compose -p helpdesk-bench ... build web worker consumer scheduler
```
O initializer `config/initializers/opentelemetry.rb` só liga com `OTEL_EXPORTER_OTLP_ENDPOINT` (o overlay define). Sem as gems, só registra um aviso.

## Bullet (N+1 no painel, em desenvolvimento)

```powershell
docker compose run --rm web bundle add bullet --group development
docker compose restart web
```
Os avisos aparecem no log do `web` e no rodapé das páginas.
