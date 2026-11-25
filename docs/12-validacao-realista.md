# 12 — Validação realista (ADR-029)

**Situação (25/11/2026): executado em parte.** As rodadas de 24 e 25/11 acharam e corrigiram cinco gargalos da plataforma (ADR-031 a ADR-035). A medição final com todas as correções ligadas ainda não foi feita. O roteiro completo de testes, com o que falta, está no [13](13-roteiro-de-testes.md).

## O que cada peça prova

| Peça | Arquivo | Pergunta que responde |
| --- | --- | --- |
| Agente realista | `docker-compose.realistic.yml` | A plataforma aguenta um agente de 3 a 12 s com 3% de falhas? |
| Carga do negócio | `bench/k6/chat_load.js` (perfis `negocio`, `caos`) | Operação média (5 msg/s), pico de 30 msg/s por 60 s e recuperação |
| Falhas | `docker-compose.chaos.yml`, `bench/chaos/run.ps1` | Kafka 30 s fora, Postgres +300 ms, Redis cortado, agente parado: algo se perde? (E2) |
| Sinais de ouro | `/metrics`, `infra/observability/` | Onde a fila cresce primeiro? Latência por ação (RNF-22) |
| Banco | `docker-compose.dbprofile.yml`, `bench/db/` | Quais consultas pesam? |
| Telas | `bench/ui/` | Quanto leva trocar de tela? LCP ≤ 2,5 s (RNF-32) |
| Qualidade | `bench/agent-quality/` | Um agente real decide como o esperado? |

## Resultado esperado a priori (hipóteses, não medidas)

1. **O agente satura antes da plataforma.** Teto ~6,4 turnos/s com 48 threads e 7,5 s de média. No pico de 30 msg/s a fila cresce no tópico `agent.inbound`, e o lag do consumidor é o primeiro sinal. Pelo cálculo, a fila do pico não esvazia em 5 min (RNF-10); se for confirmado, é um achado, não um defeito do teste.
2. **3% de falhas viram handoff** pelo prazo de 20 s do turno (RN-46), sem perda de mensagem.
3. **Kafka parado 30 s:** o outbox acumula e republica depois (P2, ADR-016); perdidas = 0.


## O que as rodadas de 24 e 25/11 mostraram

### 1. O teste estava medindo a coisa errada

Os perfis `pico` e `negocio` mandam **uma mensagem por cliente novo**: cada mensagem abre um atendimento, passa pela triagem, abre um turno e chama o agente. Na vida real, a maior parte das mensagens é de conversa já aberta. A rajada do `pico` (30 atendimentos novos por segundo) ficou acima da rajada do requisito (~12 por segundo, docs/05). Por isso foi criado o perfil **`realista`**: a unidade é a conversa, com 2 a 6 mensagens do mesmo cliente e pausa de 10 a 40 s entre elas, nas taxas do docs/05. Os perfis antigos ficam como **diagnóstico de limite**, não como aceite.

### 2. A plataforma também tinha problemas, independentes do teste

| # | Causa | Evidência | Correção |
|---|---|---|---|
| 1 | Jobs do mesmo atendimento esperando a trava uns dos outros | `SELECT tickets ... FOR UPDATE`: 12 135 chamadas, ~1 015 s de espera somada | Trava `FOR NO KEY UPDATE` ([ADR-031](08-decisoes-de-arquitetura.md)) e job que desiste em 300 ms e volta à fila ([ADR-032](08-decisoes-de-arquitetura.md)) |
| 2 | Threads demais por processo (GVL do Ruby) | 4 processos × 8 threads: evento do outbox em 9,1 s; 8 × 2: 1,3 s | Escalar por processo, não por thread (ADR-032) |
| 3 | Todos os eventos na mesma fila do Sidekiq | Timeouts, avisos e resumos furavam a fila de quem leva a resposta ao cliente | Filas `critical`, `timers` e `low` por tipo (ADR-032) |
| 4 | Fila da integração mal dimensionada | Turno ~15 s entre publicado e resposta no Kafka, com ~6 s de processamento do agente | Mais partições que threads, 192 no teste ([ADR-034](08-decisoes-de-arquitetura.md)) |
| 5 | Falta de capacidade do agente sem reação da plataforma | Cliente esperava 20 s e ia para humano com um turno sem chance de resposta | Controle de admissão: a plataforma é dona da fila ([ADR-035](08-decisoes-de-arquitetura.md)) |
| 6 | Entrada HTTP num processo só | `web` em ~100% de CPU, ack p95 de 39,6 s no patamar | Puma em modo cluster ([ADR-033](08-decisoes-de-arquitetura.md)) |

### 3. Como o overhead da plataforma é medido agora

O agente é **caixa-preta**: o tempo de processamento dele está fora do escopo. Mas a **fila até ele é da integração**, porque a plataforma define o tópico, as partições e a chave. Por isso:

| Trecho | De → até | Conta como |
|---|---|---|
| Ida | janela de agrupamento fechada → turno publicado no Kafka | plataforma |
| Fila da integração | publicado → o agente começa (tempo até a resposta entrar no Kafka, menos o processamento que o agente declara) | plataforma |
| Processamento | o que o agente declara em `timing.agent_ms` | agente, fora do escopo |
| Volta | resposta no Kafka → aplicada → entregue ao canal | plataforma |

**Overhead da plataforma = ida + fila da integração + volta** (`overhead_com_fila` no `reconcile.rb`). É a leitura do RNF-03 registrada no docs/05.

Há dois tipos de fila, e só um é defeito da plataforma: **fila por desenho** (conversas colidindo na mesma partição com o agente ocioso) e **fila por falta de capacidade** (chegam mais turnos do que o agente processa em paralelo). A segunda não se resolve na plataforma; o que a plataforma deve fazer é reagir a ela (ADR-035). Por isso o critério de aprovação é o **patamar**; na **rajada** acima da capacidade, julga-se o comportamento: nada perdido, turno sem vaga tratado em segundos, fila drenada depois.

### 4. Números, antes e depois

| Rodada | Configuração | Turnos aplicados | Outbox até publicar (mediano) | Overhead | Ack do patamar (p95) |
|---|---|---|---|---|---|
| Pico, 24/11 | 4 workers, trava antiga | 6 / 879 | 11,6 s | 36 s (conta antiga) | — |
| Pico, 24/11 | 8 × 2, ADR-031 | 121 / 1276 | 1,3 s | 11,7 s (conta antiga) | — |
| Realista, 25/11 | 8 × 2, ADR-031 | 364 / 2191 | 0,12 s | 9,4 s (conta antiga) | 33 s |
| Realista, 25/11 | + ADR-032 | 373 / 2247 | 0,14 s | ida + volta 1,6 s; com a fila ~10 s | 39,6 s |
| Realista | + ADR-033, 034 e 035 | **a medir** | | | |

Turnos aplicados baixos não reprovam a plataforma sozinhos: o agente simulado atende 48 turnos ao mesmo tempo, de 3 a 12 s cada (~6,4 turnos/s), e a rajada passa disso. O que reprova é o overhead acima de 1 s no patamar e o ack lento.

### 5. Hipóteses a priori, conferidas

1. **"O agente satura antes da plataforma"**: verdadeira só em parte. A plataforma saturou antes (trava, threads, fila única, entrada HTTP). Depois das correções, o agente passou a ser o limite na rajada.
2. **"3% de falhas viram handoff"**: confirmado no comportamento (todo turno sem resposta foi para humano); a medição do tempo até o handoff ficou para a rodada com a admissão.
3. **"Kafka parado 30 s"**: ainda não executado com validade (as rodadas de caos antigas tinham o agente fora do ar).

## Como rodar

```powershell
.\bench\pico.ps1 -Ajustado -Perfil realista     # aceite: conversas reais (~20 min)
.\bench\pico.ps1 -Ajustado -Perfil estresse     # degraus de 1 a 24 msg/s: onde quebra (~12 min)
.\bench\pico.ps1 -Ajustado                      # diagnóstico da rajada (~10 min)
.\bench\negocio\run.ps1                         # tudo junto (~20 min)
.\bench\chaos\run.ps1 -Cenario kafka            # um cenário de falha (~5 min)
.\bench\ui\run.ps1                              # só as telas
```

Ligar Bullet e OpenTelemetry exige gems (um comando cada, ver `infra/observability/README.md`). Sem elas, os dois ficam desligados e o resto funciona.

## Limitações

- O perfil `realista` usa premissas (4 mensagens por conversa, pausa de 10 a 40 s) a validar com a CloudWalk. A pausa é curta para um chat real por limite de memória do k6 no notebook.
- Rodada única por configuração: as diferenças pequenas entre rodadas podem ser variação.
- O tempo de processamento do agente vem do próprio agente (`timing.agent_ms`); com o agente real, é um campo do contrato.

- A latência do agente é uniforme na faixa, não a cauda real (lognormal) de um LLM. Calibrar com uma amostra de um agente real.
- Tudo numa máquina; o k6, o Chromium do Playwright e o Grafana disputam CPU com a plataforma.
- LCP medido em ambiente local, sem rede, serve para comparar versões, não como Web Vitals de campo.
- `/metrics` é por processo e faz `COUNT` a cada leitura.
- Falhas de rede só no Postgres e no Redis; o Kafka usa pausa do contêiner.
