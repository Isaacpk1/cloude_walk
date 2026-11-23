# Experimento técnico: carga e latência (E1) e capacidade (E5)

Este é o experimento principal do projeto (docs/05, seção 2). Ele mede se a plataforma confirma e processa mensagens
com a rapidez e a segurança que os requisitos pedem, e onde a fila cresce primeiro quando a carga passa do limite.

## Hipótese

Com a configuração de referência (4 vCPU, 8 GB), a plataforma:

1. confirma cada mensagem recebida (ack `202`) em **p95 ≤ 200 ms** e **p99 ≤ 500 ms** a 20 msg/s, por 30 min (RNF-01, RNF-09);
2. não perde nenhuma mensagem confirmada, nem sob rajada de 100 msg/s por 60 s (RNF-10, RNF-14);
3. esvazia o que acumulou na rajada em até 5 min (RNF-10);
4. mantém erros 5xx abaixo de 0,1% no patamar (RNF-09).

O ack é rápido porque a ingestão só grava (mensagem, auditoria e outbox numa transação) e responde. Todo o resto
(publicar no Kafka, agente, aplicar a resposta, entregar ao canal) acontece depois, pelo outbox. Por isso a hipótese
separa o que é **latência do ack** (síncrona) do que é **fila** (assíncrona).

E5 acrescenta: ao dobrar as réplicas de `worker` e `consumer`, a vazão de turnos sobe pelo menos 1,6× (RNF-11), e o
formato da carga importa. **Muitas conversas independentes** escalam; **rajadas na mesma conversa** não, porque a
linha do atendimento é travada (invariante 1) e cada rajada vira poucos turnos superados (RN-56).

## Método

| Item | Valor |
| --- | --- |
| Gerador de carga | k6 em modelo aberto (`constant-arrival-rate`), que mantém a taxa mesmo com o servidor lento e evita *coordinated omission* |
| Alvo | `POST /webhooks/chat/infinitepay-chat-mock`, assinado com HMAC como o provedor (ADR-019) |
| Perfil `reference` | aquecimento 5 min a 20 msg/s, patamar 30 min a 20 msg/s, rajada 60 s a 100 msg/s, recuperação 2 min |
| Perfil `capacity` | rampa de 10 a 100 msg/s em 10 min, para achar a saturação |
| Perfil `smoke` | 30 s a 5 msg/s, só para conferir o roteiro |
| Formato (E5) | `MODE=independent`: cada mensagem de um cliente; `MODE=burst`: as mensagens se repartem entre `BURST_CUSTOMERS` (5) clientes |
| Semente | `SEED=42`: os clientes são `bench_<semente>_<n>`; o agente mock usa o perfil e a latência de 2 s configurados no `.env` |
| Repetição | `RUNS=3` execuções por cenário, com mediana e dispersão (RNF-30) |
| Resultado | só os 25 min finais do patamar contam; os 5 min de aquecimento são descartados (RNF-09) |

O que cada execução grava em `bench/results/AAAA-MM-DD-<perfil>-<formato>/`:

- `<run>-k6.json`: latência do ack (mediana, p90, p95, p99, máximo), contagem de `202`, `200` e recusas;
- `<run>-db.json`: gerado por `bench/analysis/reconcile.rb` a partir do banco.

### O que a reconciliação mede

| Métrica | De onde vem | Requisito |
| --- | --- | --- |
| Mensagens perdidas = `202` do k6 − mensagens do banco com o `message_id` da execução | k6 e `messages` | RNF-14, deve ser 0 |
| Atraso do outbox até publicar (`published_at − created_at`) | `outbox_events` | RNF-03, RNF-04 |
| Resposta entregue ao canal desde a mensagem do cliente | `deliveries.delivered_at − messages.received_at` | RNF-03, RNF-05 |
| Proporção de turnos superados | `ai_turns.status` | RN-56, E5 |
| Outbox ainda pendente ao fim | `outbox_events.completed_at IS NULL` | RNF-10 |

A fila que acumula primeiro se vê no Grafana (`infra/observability/`) durante a rajada: profundidade do outbox, lag
do consumidor do tópico e jobs do Sidekiq.

## Como rodar

```bash
make up && make seed
make bench                                     # smoke, 1 vez cada: confere o roteiro
make bench PROFILE=reference MODE=independent  # E1: 3 execuções, ~40 min cada
make bench PROFILE=reference MODE=burst        # E5: rajadas na mesma conversa
make bench PROFILE=capacity                    # saturação
docker compose up -d --scale worker=2 --scale consumer=2   # E5: refazer com 2 e 4 réplicas
```

Registre junto do resultado: CPU, memória, sistema e versão do Docker, e `git rev-parse HEAD`. Um resultado sem
semente e sem configuração não conta como evidência.

## Limitações conhecidas

1. **Nada foi medido ainda.** Este diretório traz o roteiro e a análise; os números entram em `results/` quando o
   experimento rodar no Compose da máquina de referência. Até lá, nenhuma meta acima está comprovada.
2. **Ambiente de desenvolvimento.** O `make up` monta `src/platform` e roda em modo `development`. No Docker Desktop do
   Windows a pasta montada somou cerca de 1,5 s por passo no bloco 03. Para números que representem a plataforma, rode
   com `RAILS_ENV=production`, código na imagem e sem a pasta montada. Esse perfil ainda não existe no Compose.
3. **Carga só no chat.** O k6 exercita o webhook do chat. WhatsApp e e-mail passam pelo mesmo núcleo de ingestão, mas o
   e-mail ainda faz chamadas à API do provedor simulado, então sua latência de ack é maior e não está medida.
4. **Agente mock.** A latência do agente é configurada (2 s), então a latência percebida do cliente mostra a plataforma,
   não um modelo de verdade. Resposta de LLM real muda o gargalo para o agente.
5. **Tudo numa máquina.** Postgres, Redis, Kafka, plataforma e k6 dividem os mesmos 4 vCPU. O k6 também consome CPU e
   pode antecipar a saturação. Um gerador em outra máquina daria números melhores.
6. **Relógio único.** As latências por etapa usam o relógio da própria plataforma. Em várias máquinas, o desvio entre
   relógios entraria no resultado.
7. **Comparação com o Chatwoot** (faixa de 10 a 20 mil conversas/dia) é só de ordem de grandeza: configuração, versão
   e tipo de carga são diferentes.
8. **Segurança e isolamento (E6), resiliência (E2) e filas (E3)** têm testes automatizados, não carga: ficam fora deste
   script.
