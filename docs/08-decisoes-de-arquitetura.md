# 08 — Decisões de arquitetura (ADR)

Cada decisão de stack fica registrada com o contexto, a escolha, as alternativas descartadas e as consequências. O TAPI não impõe stack, mas exige **coerência entre arquitetura e implementação e a justificativa de cada escolha** (TAPI, seção 8).

Formato: ADR curto (contexto → decisão → alternativas → consequências). Um ADR aceito não é editado. Se a decisão mudar, um novo ADR o **substitui** e o antigo é marcado como *substituído*.

## Resumo da stack

| Camada | Escolha | ADR |
| --- | --- | --- |
| Aplicação principal | Ruby + Ruby on Rails 8 | [ADR-001](#adr-001--aplicação-principal-em-ruby-on-rails-8) |
| Interface web | Hotwire (Turbo + Stimulus) com ActionCable | [ADR-002](#adr-002--interface-web-em-hotwire-sem-spa) |
| Modelo das regras de roteamento | Forma normal disjuntiva em JSONB | [ADR-003](#adr-003--regras-de-roteamento-em-forma-normal-disjuntiva) |
| Mensageria | Apache Kafka 4.x em modo KRaft, nó único | [ADR-004](#adr-004--mensageria-com-apache-kafka-4x-kraft) |
| Cliente Kafka | Karafka (consumo) e WaterDrop (produção) | [ADR-004](#adr-004--mensageria-com-apache-kafka-4x-kraft) |
| Jobs assíncronos | Sidekiq + Redis | [ADR-005](#adr-005--jobs-assíncronos-com-sidekiq--redis) |
| Persistência | PostgreSQL, com padrão outbox e auditoria só de inserção | [ADR-006](#adr-006--postgresql-como-fonte-da-verdade) |
| Broker de webhooks | Serviço Ruby separado (Rack/Roda) | [ADR-007](#adr-007--broker-de-webhooks-como-serviço-separado) |
| Agente de IA | Mock determinístico em Ruby, configurável | [ADR-008](#adr-008--agente-de-ia-mock-determinístico) |
| Observabilidade | OpenTelemetry (`traceparent`), Prometheus, Grafana, logs JSON | [ADR-009](#adr-009--observabilidade-com-opentelemetry-prometheus-e-grafana) |
| Testes e experimento | RSpec, karafka-testing, k6, pandas + Plotly | [ADR-010](#adr-010--testes-e-experimento) |
| Empacotamento | Docker Compose | [ADR-011](#adr-011--empacotamento-com-docker-compose) |
| Canais | Provedores simulados num serviço próprio (`channels-mock`) | [ADR-012](#adr-012--canais-simulados-como-provedores-externos) |
| Versionamento das regras | Conjunto de regras da marca versionado inteiro | [ADR-013](#adr-013--versionar-o-conjunto-de-regras-inteiro) |
| Isolamento entre marcas | Lógico, por `brand_id` em todas as tabelas de negócio | [ADR-014](#adr-014--isolamento-lógico-por-marca) |
| Prazos e cronômetros | Gravados no Postgres e executados a partir de ações duráveis no outbox | [ADR-016](#adr-016--prazos-do-atendimento-e-ações-duráveis-no-outbox) |
| Organização do repositório | Monorepo com o código em `src/`, um diretório por fronteira de rede | [ADR-017](#adr-017--monorepo-com-o-código-em-src) |
| Formato dos canais simulados | Subconjunto fiel da Cloud API do WhatsApp e da API do Gmail, com adaptador de entrada e de saída por canal | [ADR-018](#adr-018--canais-simulados-no-formato-dos-provedores-reais) |
| Contas e autenticação dos webhooks de entrada | Conta do provedor na URL e cadastrada na tabela `provider_accounts`, com segredo criptografado. Cada canal confere a assinatura do seu provedor | [ADR-019](#adr-019--contas-dos-provedores-e-autenticação-dos-webhooks-de-entrada) |
| Prazo da IA | 20 s por turno, teto de 60 s por ciclo, escalação imediata em falha definitiva da publicação. Configurável por marca no bloco 12 | [ADR-020](#adr-020--prazo-da-ia-por-turno-com-teto-do-ciclo) |
| Entrega ao canal | Identidade e ordem da entrega em cabeçalhos; aceite do provedor vale como entregue; falha certa avança a fila e só o resultado incerto vai para conciliação (proposto) | [ADR-021](#adr-021--entrega-ao-canal-identidade-aceite-e-conciliação) |
| Contexto do turno | Versão do contexto no atendimento, digest SHA-256 do JSON canônico no turno e limites de tamanho do RN-49 (proposto) | [ADR-022](#adr-022--versão-e-prova-do-contexto-do-turno) |
| Evals | Execuções gravadas em `eval_runs`, com checagens determinísticas sobre o caminho real da plataforma e relógio real (proposto) | [ADR-023](#adr-023--evals-com-execução-gravada-e-checagens-determinísticas) |

### Orçamento de memória (RNF-29: 4 vCPU, 8 GB)

Estimativa para validar no primeiro `docker compose up`. Os números do Rails e do Sidekiq vêm do dimensionamento publicado do Chatwoot, que tem stack equivalente.

| Contêiner | Estimativa |
| --- | --- |
| `web` (Rails/Puma + ActionCable) | ~1 GB |
| `worker` (Sidekiq) | ~400 MB |
| `consumer` (Karafka: respostas do agente) | ~400 MB |
| `broker` (webhooks → Kafka) | ~200 MB |
| `agent-mock` | ~200 MB |
| `scheduler` (prazos) | ~250 MB |
| `channels-mock` (provedores + simulador do cliente) | ~150 MB |
| `kafka` (heap limitado a 768 MB) | ~1 GB |
| `postgres` | ~1 GB |
| `redis` | ~100 MB |
| `prometheus` + `grafana` | ~400 MB |
| **Total** | **~5,2 GB**, com folga para o SO e o k6 |

---

## ADR-001 — Aplicação principal em Ruby on Rails 8

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** O projeto é individual e dura 1 mês. A plataforma é pesada em CRUD (filas, regras, equipes, atendentes), autenticação, perfis e telas em tempo real. A carga-alvo é baixa para qualquer linguagem moderna: 20 msg/s de referência e 60 msg/s de capacidade (RNF-09, RNF-12). O gargalo provável é o banco e o desenho (outbox, partições), não a linguagem. O TAPI informa que a CloudWalk opera boa parte do atendimento em Ruby.

**Decisão.** Ruby (versão estável mais recente no início da implementação) com Rails 8.x.

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Python + FastAPI | Async e Pydantic (contratos) são vantagens, mas autenticação, perfis, migrações, admin e tempo real teriam de ser montados à mão. Também se afasta da stack da CloudWalk. Seria a escolha se o domínio de Ruby fosse um risco. |
| Rust ou Go | Desempenho e memória melhores, mas o desempenho não é o gargalo nesta carga. Construir toda a interface e o CRUD sozinho em 1 mês é o maior risco do projeto. |

**Consequências.**

- (+) Mesma linguagem da operação da CloudWalk: o código pode ser lido e avaliado por quem mantém o atendimento hoje.
- (+) O Chatwoot, recomendado pelo TAPI, usa Rails, Sidekiq, PostgreSQL, Redis e ActionCable. Serve como referência de desenho.
- (+) As convenções do Rails reduzem o código de infraestrutura e deixam o tempo para o que o TAPI avalia: filas, integração, handoff e experimento.
- (−) O GVL limita o paralelismo de CPU por processo. A escala horizontal (RNF-11) é feita com mais processos ou réplicas, não com threads.
- (−) Um processo Rails consome mais memória que Go ou Rust (ver orçamento acima).

---

## ADR-002 — Interface web em Hotwire, sem SPA

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** Três interfaces: simulador de cliente (RF-04), painel do analista em tempo real (RF-45 a RF-50) e configuração de filas e regras (RF-13 a RF-21). O painel precisa receber mensagens novas em p95 ≤ 1 s (RNF-06) e ter LCP ≤ 2,5 s (RNF-32).

**Decisão.** Hotwire (Turbo Drive, Turbo Frames, Turbo Streams e Stimulus) servido pelo próprio Rails, com atualizações em tempo real por ActionCable (adaptador Redis, ver ADR-005). Sem etapa de build de JavaScript (importmap).

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| React ou Next.js separado | Dois apps, autenticação entre eles (CORS, tokens), estado duplicado no cliente e testes em duas linguagens. Ganha em interações ricas, mas a única tela que precisaria disso é o editor de regras, resolvido pelo ADR-003. |
| Hotwire + ilha React só no editor de regras | Exige bundler (jsbundling/esbuild) e uma API JSON só para o editor. Fica como **plano B**, se o editor em Stimulus não ficar usável (ver gatilho abaixo). |

**Consequências.**

- (+) Um só app e um só deploy. HTML renderizado no servidor ajuda no LCP (RNF-32).
- (+) Turbo Streams por ActionCable entregam as mensagens novas ao painel sem polling.
- (−) Interações muito ricas (aninhamento arbitrário, arrastar e soltar complexo) ficam trabalhosas em Stimulus.
- **Gatilho do plano B:** se o teste cronometrado do RNF-31 (criar fila e regra em ≤ 3 min) falhar por causa do editor, ele vira uma ilha React. O modelo de dados não muda (ADR-003).
- A ordenação das regras por arrastar (RF-15) usa SortableJS com um controller Stimulus.

---

## ADR-003 — Regras de roteamento em forma normal disjuntiva

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** O RF-14 pede condições combináveis com E/OU sobre marca, canal, categoria, prioridade e tags. Uma árvore booleana arbitrária exige um editor recursivo, difícil de fazer em Stimulus. As regras precisam ser versionadas (RF-18, RN-20) e valer sem deploy (RF-16).

**Decisão.** Cada regra é uma **disjunção de grupos**, e cada grupo é uma **conjunção de condições**: `(A e B) ou (C e D)`. As condições ficam numa coluna JSONB validada por JSON Schema versionado:

```json
{
  "schema_version": 1,
  "any": [
    { "all": [ { "field": "category", "op": "eq", "value": "credito" },
               { "field": "priority", "op": "in", "value": ["alta", "critica"] } ] },
    { "all": [ { "field": "tags", "op": "contains", "value": "vip" } ] }
  ]
}
```

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Árvore booleana com aninhamento livre | Mais expressiva na forma, não no poder: toda expressão booleana tem equivalente em forma normal disjuntiva. Custa um editor recursivo. |
| Regras em código (Ruby, DSL) | Viola o RF-16 e o TAPI: a operação precisa editar sem desenvolvimento. |

**Formato implementado (bloco 11).** O conjunto da marca é `{ "schema_version": 1, "rules": [ { "name", "queue_id", "any": [ { "all": [condição] } ] } ] }` (`src/contracts/v1/schemas/routing_rules.json`). Campos: `brand`, `channel`, `category`, `priority` com `eq` e `neq` (texto) e `in` e `not_in` (lista não vazia); `tags` só com `contains` (um texto). Regra que casa mas aponta para fila inativa é pulada e registrada em `skipped_rules` na auditoria do roteamento (RN-15).
| Motor de regras externo | Mais um componente para operar, sem ganho neste volume. |

**Consequências.**

- (+) A interface tem só dois níveis ("adicionar condição", "adicionar grupo").
- (+) O avaliador é simples e testável: uma regra casa se algum grupo tem todas as condições verdadeiras.
- (+) O JSON é o mesmo para qualquer editor: trocar para a ilha React (ADR-002) não mexe no banco nem no avaliador.
- (−) Expressões com "ou" dentro de "e" precisam ser distribuídas pelo supervisor em mais de um grupo.

---

## ADR-004 — Mensageria com Apache Kafka 4.x (KRaft)

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** A arquitetura atual da CloudWalk usa um tópico Kafka entre o broker e o agente, e o TAPI avalia a "aderência da arquitetura ao desenho fornecido". A ordem das mensagens de uma conversa deve ser preservada com vários consumidores (RNF-13), e eventos precisam ser reprocessáveis (RF-37).

**Decisão.** Apache Kafka 4.x em modo KRaft, com um nó no Docker Compose. Em Ruby, Karafka para consumir e WaterDrop para produzir (ambos sobre o librdkafka). Tópicos iniciais:

| Tópico | Produtor → consumidor | Chave |
| --- | --- | --- |
| `helpdesk.agent.inbound.v1` | broker → agente | `conversation_id` |
| `helpdesk.agent.outbound.v1` | agente → plataforma | `conversation_id` |
| `helpdesk.agent.dlq.v1` | consumidores → supervisor (RF-37) | `conversation_id` |

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Redpanda | Compatível com a API do Kafka e mais leve, mas a Community Edition usa licença BSL (não é open source). O p99 em execuções longas é contestado (ver referências do [05](05-requisitos-nao-funcionais.md)). Como o código é o mesmo, a troca continua possível. |
| RabbitMQ | Retentativa e DLQ simples (DLX), mas não tem ordem por chave nem replay nativos e se afasta do "tópico Kafka" do desenho de referência. |

**Consequências.**

- (+) A partição por `conversation_id` garante ordem por conversa e permite escalar consumidores até o número de partições (RNF-11, RNF-13).
- (+) Desde a 4.0 o ZooKeeper foi removido, então o Kafka roda num contêiner só.
- (+) O Karafka traz DLQ, retentativas e testes sem cluster (karafka-testing).
- (−) A JVM consome ~1 GB. O heap é limitado no Compose.
- (−) A entrega é "pelo menos uma vez". Todo consumidor precisa ser idempotente por `event_id` (RF-35, RN-47).
- Número de partições inicial: **48**. Cada partição é processada um evento por vez, então a vazão do agente é cerca de partições ÷ latência do agente. Com o mock a 2 s, 6 partições dariam só ~3 turnos/s, abaixo da carga de referência. Com 48, o teto é ~24 turnos/s, e as 48 partições também dividem bem entre 1, 2 e 4 réplicas no E5. *Revisado em 17/11/2026 após revisão externa; a versão anterior previa 6.*
- A ordem garantida pelo Kafka é a de **publicação** na partição. A ordem de negócio é a do `seq` no Postgres, e a validade de cada resposta é decidida no banco ([07, seção 3.4](07-arquitetura.md#34-cliente-que-escreve-enquanto-a-ia-responde-turnos)).

---

## ADR-005 — Jobs assíncronos com Sidekiq + Redis

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** Disparo de webhooks com retentativa (RF-29, RF-34), publicação do outbox, timers de SLA e de inatividade (RN-07, RN-25), timeout do agente (RF-36) e geração de resumo do handoff precisam rodar fora da requisição. O Postgres é a peça medida no E1.

**Decisão.** Sidekiq com Redis. O mesmo Redis serve ao ActionCable (ADR-002) e ao rate limit por marca e canal (RNF-33).

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Solid Queue e Solid Cable (padrão do Rails 8) | Tira o Redis da stack, mas joga a fila de jobs e o pub/sub dos WebSockets no Postgres. Isso mistura essa carga com a medida do experimento e dificulta isolar o gargalo. |
| Consumir tudo pelo Kafka | O Kafka não tem agendamento nem atraso por mensagem, que os timers de SLA e o backoff precisam. |

**Consequências.**

- (+) É a sugestão do TAPI e o padrão do Chatwoot. É maduro, tem painel web e suporta retentativa com backoff.
- (+) Um único Redis atende três necessidades.
- (−) Mais um contêiner. O Redis não é a fonte da verdade: se ele perder dados, o outbox no Postgres permite republicar (ADR-006).

---

## ADR-006 — PostgreSQL como fonte da verdade

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** Nenhuma mensagem aceita pode ser perdida (RNF-14). A auditoria deve ser imutável (RNF-21, RN-54). As filas e regras são dados versionados (RF-18).

**Decisão.** PostgreSQL (versão estável mais recente) como fonte da verdade, com três padrões:

1. **Outbox transacional:** a mensagem do cliente e o evento a publicar são gravados na mesma transação, e só então a ingestão responde. Um job publica o outbox no broker.
2. **Auditoria só de inserção:** tabela `audit_events` com `UPDATE` e `DELETE` revogados ao usuário da aplicação.
3. **Versionamento por linha:** cada alteração de fila ou regra cria uma nova linha de versão, e as antigas não mudam.

**Alternativas consideradas.** O banco já é sugerido pelo TAPI e não há candidato melhor para o volume. Um armazenamento separado para auditoria (por exemplo, um tópico Kafka compactado) foi descartado por adicionar consistência eventual onde a auditoria precisa ser exata.

**Consequências.**

- (+) Garantia de "aceitou, persistiu" (RPO = 0 da RNF-19).
- (+) JSONB para as condições das regras (ADR-003) e o contexto dos eventos.
- (−) O outbox adiciona um salto de latência. Ele entra no orçamento do RNF-03 e é medido no E1.

---

## ADR-007 — Broker de webhooks como serviço separado

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** No desenho atual, um broker consome do help desk os webhooks e os publica num tópico Kafka. O TAPI pede integração "em estrutura semelhante à atual" e avalia a robustez diante de falhas e reentregas.

**Decisão.** Um serviço Ruby pequeno (Rack/Roda + WaterDrop), em contêiner próprio. Ele recebe o webhook, valida o HMAC-SHA256 e a janela anti-replay (RNF-23), valida o contrato (RNF-28) e publica no tópico de entrada com a chave `conversation_id`.

**Alternativas consideradas.** A plataforma poderia publicar direto no Kafka, o que é mais simples e mais rápido. Foi descartada porque quebra a aderência ao desenho de referência e deixaria sem teste justamente a fronteira webhook que o TAPI pede (reentrega, assinatura, duplicatas).

**Consequências.**

- (+) Mesmo fluxo da CloudWalk: plataforma → webhook → broker → tópico → agente.
- (+) O broker pode cair e voltar de forma independente (RNF-17, E2).
- (−) Mais um salto HTTP, medido no RNF-04 (p99 ≤ 100 ms).

---

## ADR-008 — Agente de IA mock determinístico

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** O agente real não será fornecido. O experimento precisa de comportamento reprodutível (RNF-30) e de injeção de falhas (E2). O TAPI aceita mock determinístico ou LLM aberto, desde que modelo, versão e configuração sejam registrados.

**Decisão.** Um consumidor Karafka em Ruby que lê o tópico de entrada e responde no tópico de saída. Ele decide por regras configuráveis (palavras-chave → responder, consultar, escalar ou encerrar) e tem latência, taxa de falha e modo "mudo" configuráveis (RF-38). Cada resposta carrega `agent_model`, `agent_version` e `agent_config_hash` (RN-37).

**Alternativas consideradas.** Um agente com LLM aberto deixaria a demonstração mais realista, mas a latência e as decisões variam entre execuções, o que prejudica a reprodutibilidade do experimento. Fica como evolução: o contrato do tópico não muda, então um agente com LLM pode substituir o mock.

**Consequências.**

- (+) Experimento reprodutível com semente fixa. A latência do agente vira parâmetro e é descontada do overhead (RNF-03).
- (−) Não avalia a qualidade das respostas da IA, o que está fora do escopo do TAPI.

---

## ADR-009 — Observabilidade com OpenTelemetry, Prometheus e Grafana

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** Cada mensagem precisa de um trace ID ponta a ponta (RF-56, RNF-20). O experimento mede latência por salto (RNF-03) e os quatro sinais de ouro (RNF-22).

**Decisão.** Propagação W3C `traceparent` com o SDK do OpenTelemetry para Ruby (HTTP e cabeçalhos Kafka). Métricas em `/metrics` no formato Prometheus, painéis no Grafana e logs em JSON com `trace_id` e PII mascarada (RNF-25).

**Consequências.**

- (+) Padrão aberto. O mesmo `trace_id` liga logs, auditoria e eventos do Kafka.
- (−) Um coletor de traces (Jaeger ou Tempo) é opcional. Sem ele, a correlação é feita pelos logs e pela auditoria, o que basta para o experimento.

---

## ADR-010 — Testes e experimento

**Status:** aceito · **Data:** 17/11/2026

**Decisão.**

| Uso | Ferramenta | Motivo |
| --- | --- | --- |
| Testes de domínio e de aceite (RNF-27) | RSpec | Padrão do ecossistema Ruby, sugerido pelo TAPI |
| Testes de consumidores e produtores Kafka | karafka-testing | Testa sem subir o cluster |
| Testes de contrato (RNF-28) | json_schemer | Valida os esquemas JSON versionados |
| Carga (E1, E5) | k6, executor `constant-arrival-rate` | Modelo aberto, evita *coordinated omission* |
| Análise dos resultados | pandas + Plotly (Python) | Sugerido pelo TAPI. Roda fora da plataforma, então a segunda linguagem não pesa |
| Segurança (RNF-26) | Brakeman, bundler-audit, Trivy | Análise estática e de dependências |

---

## ADR-011 — Empacotamento com Docker Compose

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** A plataforma deve ser self-hosted e subir com um comando numa máquina limpa (RNF-29).

**Decisão.** Docker Compose com todos os serviços (`web`, `worker`, `scheduler`, `consumer`, `broker`, `agent-mock`, `channels-mock`, `kafka`, `postgres`, `redis`, `prometheus`, `grafana`) e um `Makefile` (`make up`, `make seed`, `make bench`).

**Alternativas consideradas.** O Kamal (citado pelo TAPI) faz deploy em servidores reais e fica como evolução. O Kubernetes é desproporcional para uma máquina e um mês.

**Consequências.**

- (+) Reprodutível por qualquer avaliador seguindo só o README.
- (−) Tudo numa máquina: os números do experimento são um limite inferior de latência (limitação já declarada no [05](05-requisitos-nao-funcionais.md)).

---

## ADR-012 — Canais simulados como provedores externos

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** WhatsApp, e-mail e chat do app são simulados (escopo). Mesmo assim, a plataforma deve receber as mensagens "pelo mesmo caminho que um canal real" (RF-01 a RF-03) e responder pelo canal de origem (RF-06). O orçamento de latência mede a entrada (salto 1) e a entrega (salto 6) separadamente.

**Decisão.** Um serviço `channels-mock` faz o papel dos provedores. Ele envia webhooks de entrada no formato de cada canal, expõe uma "API do provedor" para a plataforma entregar as respostas e hospeda o simulador do cliente (RF-04). A plataforma nunca fala direto com o cliente.

**Alternativas consideradas.** Colocar o simulador dentro do `web` é mais simples, mas a entrega ao cliente viraria uma chamada interna, sem rede, sem falha possível e sem medida do salto 6. Também esconderia o que muda quando um provedor real entrar.

**Consequências.**

- (+) Trocar o mock por um provedor real (por exemplo, a API do WhatsApp Business) mexe só nos adaptadores de entrada e saída.
- (+) Permite injetar falhas na entrega (E2) e medir o salto 6 (RNF-03).
- (−) Mais um contêiner (~150 MB).

---

## ADR-013 — Versionar o conjunto de regras inteiro

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** As regras são avaliadas em ordem e a primeira que casa decide (RN-16), então a **ordem faz parte do significado**. Toda decisão de roteamento deve registrar a versão aplicada (RN-20), e a alteração deve valer em até 5 s sem reinício (RNF-07).

**Decisão.** Cada marca tem um **conjunto de regras** (`routing_rulesets`) versionado como um todo: a lista ordenada de regras (no formato do [ADR-003](#adr-003--regras-de-roteamento-em-forma-normal-disjuntiva)) e a fila padrão. Qualquer mudança (editar, criar, excluir ou reordenar) cria uma nova versão. O roteamento lê a versão atual e a guarda no atendimento e na auditoria. Os processos mantêm a versão em cache e conferem o número da versão a cada roteamento, uma consulta barata por chave primária.

**Alternativas consideradas.** Versionar cada regra separadamente não captura a reordenação nem mudanças em várias regras ao mesmo tempo: o roteamento poderia ver metade de uma alteração.

**Consequências.**

- (+) Toda decisão aponta para um estado completo e reproduzível da configuração. O E3 só precisa comparar números de versão.
- (+) A troca é atômica: um atendimento usa a versão antiga ou a nova, nunca uma mistura.
- (+) Simular uma regra antes de salvar (RF-20) é avaliar um conjunto ainda não salvo.
- (+) O cache do processo confere `(id, version, created_at)` da versão atual pelo índice único `(brand_id, version)` a cada roteamento. A versão nova vale no roteamento seguinte ao commit (RNF-07). As filas são lidas a cada roteamento, então desativar uma fila também vale na hora.
- (−) Cada edição grava o conjunto inteiro, o que é irrelevante para dezenas de regras por marca.

---

## ADR-014 — Isolamento lógico por marca

**Status:** aceito · **Data:** 17/11/2026

**Contexto.** Nenhum perfil pode ver dados de marca não atribuída (RN-52, RNF-24). O guia de isolamento da AWS, citado no TAPI, descreve três modelos: silo (infraestrutura por inquilino), ponte (esquema por inquilino) e pool (tabelas compartilhadas com identificador do inquilino).

**Decisão.** Modelo **pool**: `brand_id` em todas as tabelas de negócio, escopo obrigatório na camada de acesso a dados e políticas por perfil. O Row-Level Security do Postgres fica como evolução (defesa em profundidade).

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Silo (banco por marca) | Isolamento máximo, mas multiplica a operação, e a CloudWalk tem poucas marcas que compartilham equipes |
| Ponte (esquema por marca) | Migrações por esquema e consultas entre marcas (painel do supervisor) ficam complexas |
| Row-Level Security desde o início | Exige definir o contexto da sessão a cada requisição e job. Fica para depois do básico funcionar |

**Consequências.**

- (+) Simples de operar. Um supervisor pode ver várias marcas sem consultas entre bancos.
- (−) O isolamento depende do código aplicar o escopo sempre. Por isso o E6 tem testes adversariais que tentam ler e alterar dados de outra marca por API e por interface.

---

## ADR-015 — Prazos gravados no Postgres com agendador próprio

**Status:** substituído por [ADR-016](#adr-016--prazos-do-atendimento-e-ações-duráveis-no-outbox) · **Data:** 17/11/2026

**Contexto.** A plataforma depende de prazos curtos e precisos: a janela de agrupamento de 1,5 s (RN-55), o aviso de progresso aos 15 s (RN-57), o timeout do agente aos 30 s, com escalação em até T + 2 s (RN-46, RNF-18), além dos prazos de SLA. O agendador do Sidekiq confere os jobs agendados a cada ~5 s, e eles moram no Redis, que não é fonte da verdade.

**Decisão.** Os prazos são **colunas no Postgres** (`tickets.dispatch_due_at`, `tickets.first_pending_at`, `ai_turns.deadline_at`, prazos de SLA), gravadas na mesma transação que os cria. Um processo `scheduler` consulta, a cada 250 ms, os prazos vencidos por índices parciais, usando `FOR UPDATE SKIP LOCKED`, e enfileira no Sidekiq a ação correspondente. Os jobs conferem de novo o estado com a linha travada antes de agir.

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Jobs agendados do Sidekiq (`perform_in`) | Precisão de ~5 s e estado no Redis. Reduzir o intervalo de verificação do Sidekiq aumenta a carga no Redis e continua sem fonte da verdade |
| Cronômetro em memória no consumer | Some se o processo cair |

**Consequências.**

- (+) O prazo sobrevive à perda do Redis e a reinícios. A precisão (~250 ms) cabe na janela de 1,5 s e na meta de T + 2 s.
- (+) O atraso do `scheduler` vira métrica mensurável sob carga no E1.
- (−) Mais um processo e uma consulta frequente ao banco. A consulta é por índice parcial e devolve poucas linhas.

---

## ADR-016 — Prazos do atendimento e ações duráveis no outbox

**Aceito em 17/11/2026.** Substitui [ADR-015](#adr-015--prazos-gravados-no-postgres-com-agendador-próprio).

O prazo para escalação precisa existir mesmo quando o agente ou broker está indisponível antes do primeiro envio. A passagem da ação do scheduler para o worker também precisa sobreviver a uma queda entre o commit no Postgres e o enqueue no Redis.

**Decisão.** O atendimento guarda o início do ciclo, a janela de envio, o aviso e o timeout. O prazo de timeout é a referência para validar a resposta sob o lock do ticket. O turno leva uma cópia do prazo no contrato com a IA. A cópia permite que o agente ignore trabalho vencido.

O `scheduler` consulta prazos vencidos a cada 250 ms. Sob o lock da linha, registra no outbox a ação com chave única e usa o próprio registro como marcador da emissão. O timeout continua consultável até a conclusão do ciclo. O Compose roda uma réplica por padrão. Se houver mais réplicas, `FOR UPDATE SKIP LOCKED` divide as linhas entre elas. As chaves únicas e a revalidação sob o lock garantem um efeito por ação.

O Sidekiq recebe o ID da ação após o commit. O worker conclui o item do outbox na mesma transação em que aplica o efeito ou registra o descarte. O publisher reoferece ações abertas após uma falha de enqueue, perda do job ou vencimento da reserva. A recuperação preserva a chave da ação e o prazo original.

**Alternativa considerada.** Enfileirar diretamente do scheduler deixa a conclusão do prazo e o enqueue em sistemas diferentes. Uma falha entre eles pode perder a ação ou enfileirá-la de novo a cada varredura.

**Consequências.** Há uma escrita durável por prazo emitido. O intervalo de 250 ms é de consulta. A latência até o efeito inclui espera por lock, fila e execução. E1 mede esse atraso sob carga, e E2 verifica recuperação e rejeição de respostas tardias. Ver [07, seção 3.4](07-arquitetura.md#34-cliente-que-escreve-enquanto-a-ia-responde-turnos).

---

## ADR-017 — Monorepo com o código em `src/`

**Status:** aceito · **Data:** 18/11/2026

**Contexto.** O ADR-011 define sete contêineres de aplicação, mas nenhum documento diz onde fica o código de cada um. Sem essa regra, cada bloco do roadmap inventaria um lugar para migrations, configuração do Redis, tópicos do Kafka e esquemas. Os serviços também precisam compartilhar os contratos (RNF-28) sem compartilhar models.

**Decisão.** Um único repositório. Todo o código que roda fica em `src/`: `platform/` (Rails, de onde saem `web`, `worker`, `consumer` e `scheduler`), `broker/`, `agent-mock/`, `channels-mock/` e `contracts/` (gem local com os JSON Schemas). Cada serviço tem o próprio `Gemfile`, `Dockerfile` e `spec/`. Fora de `src/` ficam `tests/e2e/`, `infra/` (Postgres, Kafka e observabilidade), `bench/`, `scripts/` e o CI. Os tópicos do Kafka são declarados em `infra/kafka/topics.yml` e criados por um contêiner de uso único, `kafka-init`. O detalhe de cada pasta está no [10](10-organizacao-do-repositorio.md).

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Um repositório por serviço | Projeto individual de um mês. Mudanças de contrato tocariam três repositórios e três pull requests ao mesmo tempo |
| Tudo dentro do app Rails (broker e agente como engines ou pastas do Rails) | O broker e o agente poderiam importar os models e ler o Postgres, o que viola o ADR-007 e a fronteira do agente. A separação deixaria de ser testada |
| Plataforma na raiz e serviços em subpastas | Mistura código com docs, infraestrutura e experimentos na raiz. `src/` deixa claro o que roda |
| Tópicos criados pelo `karafka topics migrate` de um dos serviços | Daria a um serviço a posse de tópicos que pertencem à integração. Um arquivo neutro em `infra/` serve a todos |

**Consequências.**

- (+) Um pull request muda contrato, produtor e consumidor juntos, e o CI testa os três.
- (+) A fronteira de rede vira fronteira de pasta: o agente não tem como acessar o banco.
- (+) Uma resposta única para "onde fica?", registrada no 10.
- (−) Quatro `Gemfile` para manter. As versões comuns (Karafka, WaterDrop, json_schemer) precisam andar juntas.
- (−) Um serviço que usa `contracts/` precisa de `src/` como contexto de build do Docker, para a imagem copiar a gem. Enquanto não usa, o contexto é a própria pasta do serviço.

---

## ADR-018 — Canais simulados no formato dos provedores reais

**Status:** aceito · **Data:** 18/11/2026 · Complementa o [ADR-012](#adr-012--canais-simulados-como-provedores-externos).

**Contexto.** O ADR-012 diz que o `channels-mock` envia webhooks "no formato de cada canal", mas não diz qual formato. A RF-02 pede o formato de cada canal documentado. Um formato inventado é mais simples, mas esconde o que muda num provedor real: o WhatsApp manda o texto aninhado em `entry[].changes[]` e só aceita texto livre dentro da janela de 24 h; o Gmail avisa por push só com um `historyId` e exige cabeçalhos de thread na resposta.

**Decisão.** O `channels-mock` imita um subconjunto fiel da Cloud API do WhatsApp e da API do Gmail, na entrada, na saída e nos status de entrega. O chat do app usa formato próprio, porque o app é da CloudWalk. Cada canal tem um adaptador de entrada (webhook → mensagem normalizada) e um de saída (resposta interna → chamada do provedor), que aplica a política do canal: tamanho do texto, janela de 24 h e thread do e-mail. O webhook cru fica em `messages.provider_payload`. Os formatos estão no [07, seção 5.0](07-arquitetura.md#50-webhooks-dos-canais-entrada-e-saída).

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Formato inventado e igual para todos os canais | O adaptador ficaria sem teste real. A troca por um provedor de verdade mudaria o adaptador inteiro, não só a configuração |
| Usar os provedores reais (sandbox da Meta e uma conta Gmail) | Exige contas, aprovação e dados reais, o que fere a LGPD e o escopo sintético (RNF-25). Fica como evolução |

**Consequências.**

- (+) O adaptador é testado contra o formato verdadeiro de cada provedor. Trocar o mock por um provedor real muda a URL e a credencial da conta.
- (+) A política de saída (4.096 caracteres, janela de 24 h, thread do e-mail) aparece já nos testes.
- (−) O mock do Gmail precisa de três rotas (push, `history.list` e `messages.get`), mais trabalho que um webhook único.
- (−) O subconjunto precisa ser mantido em dia com a documentação dos provedores. Só os campos usados entram no mock.

---

## ADR-019 — Contas dos provedores e autenticação dos webhooks de entrada

**Status:** aceito · **Data:** 18/11/2026 · Complementa o [ADR-018](#adr-018--canais-simulados-no-formato-dos-provedores-reais).

**Contexto.** O webhook de entrada (`/webhooks/:channel/:provider_account`) era aberto: quem soubesse a URL podia gravar mensagens como qualquer cliente de qualquer marca. A RNF-23 já exigia HMAC no webhook plataforma → broker, mas não dizia nada sobre a entrada dos canais. A plataforma também precisa saber, pela URL, de qual marca é a conta. Essa ligação estava num arquivo YAML, fora do banco, sem auditoria e sem chave estrangeira.

**Decisão.**

1. **A conta do provedor vem da URL e fica na tabela `provider_accounts`**: marca, canal, `slug` da URL, `phone_number_id` do WhatsApp, segredo e se está ativa. O segredo fica criptografado pelo Active Record Encryption, com as chaves no ambiente. O supervisor cadastra as contas junto com as marcas (RF-58), e a alteração entra na auditoria (RF-54, bloco 12).
2. **Toda entrada é autenticada antes do parse**, com o segredo da conta da URL. Sem assinatura válida, a resposta é `401` e nada é lido nem gravado. Cada canal usa o esquema do seu provedor:

| Canal | Esquema | Segredo na tabela |
| --- | --- | --- |
| Chat do app (CloudWalk) | `X-Helpdesk-Signature: t=<unix>,v1=<HMAC-SHA256("t.corpo")>`, janela de ±5 min. É o mesmo esquema do webhook ao broker (07, seção 5.2), implementado uma vez em `HelpdeskContracts::Signature` | Segredo do HMAC da conta |
| WhatsApp (Meta) | `X-Hub-Signature-256: sha256=<HMAC-SHA256(corpo)>` com o app secret. O `metadata.phone_number_id` do corpo precisa ser o da conta da URL | App secret |
| E-mail (Gmail via Pub/Sub) | Token OIDC do Google no `Authorization` do push, com a audiência da conta | Audiência esperada |

**A conta na URL no WhatsApp.** Por padrão a Meta envia tudo para a URL do app, mas permite uma URL própria por WhatsApp Business Account ou por número (`override_callback_uri`). A plataforma usa a URL por número. O corpo sempre traz `metadata.phone_number_id`, e o adaptador recusa o webhook se ele não for o da conta: a URL escolhe a conta e o corpo confirma.

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Contas num arquivo de configuração | Mudar exige deploy, não há auditoria nem chave estrangeira para a marca, e a tela do supervisor (bloco 12) não teria onde gravar |
| Uma URL única por canal e a conta tirada só do corpo | Funciona no WhatsApp, mas a marca passaria a depender do corpo antes de autenticar. Com a conta na URL, o segredo certo é escolhido antes de ler o corpo |
| Um só segredo para toda a plataforma | Vazar o segredo de uma marca exporia as outras. Um segredo por conta mantém o isolamento (ADR-014) |
| Esquema próprio do chat diferente do broker | Dois códigos de HMAC para manter. O do broker já tem horário e janela anti-replay |

**Consequências.**

- (+) Um webhook com o segredo de outra conta é recusado, inclusive entre marcas (E6).
- (+) Trocar um segredo ou desativar uma conta não exige deploy.
- (−) O ambiente local precisa das chaves do Active Record Encryption. Fora de produção, há valores padrão só para desenvolvimento.
- (−) O seed e o `channels-mock` precisam usar o mesmo segredo de desenvolvimento (`PROVIDER_SECRET_<CONTA>` ou `dev-secret-<conta>`).

---

## ADR-020 — Prazo da IA por turno com teto do ciclo

**Aceito em 19/11/2026.** Muda a RN-46, a RN-57 e o RNF-18. Mantém o mecanismo do [ADR-016](#adr-016--prazos-do-atendimento-e-ações-duráveis-no-outbox).

**Contexto.** A regra anterior dava 30 s desde a primeira mensagem pendente, compartilhados por todos os turnos do ciclo. No teste do bloco 03, o cliente escreveu aos 0 s e aos 20 s: o turno 2 abriu aos 21 s e teve só 8 s. O prazo punia a IA por uma demora do cliente. Além disso, a regra não separava "agente quebrado" de "agente lento": num pico em que o agente fica lento, todos os casos estourariam juntos e lotariam a fila humana justamente quando a IA mais deveria ajudar.

**Decisão.**

1. **Prazo por turno:** cada turno tem 20 s desde a sua abertura (`ai_turns.deadline_at`).
2. **Teto do ciclo:** o turno nunca passa de 60 s desde a primeira mensagem pendente (`tickets.ai_deadline_at`), que não reinicia com mensagens novas. É a garantia para o cliente.
3. **Falha definitiva escala na hora:** recusa do broker, contrato inválido ou retentativas esgotadas encerram a publicação e registram o handoff na mesma transação, sem esperar o prazo.
4. O aviso de progresso aos 15 s (RN-57) não muda.
5. **Configurável por marca.** Os tempos (janela por canal, teto da janela, prazo do turno, teto do ciclo e aviso) ficam num só lugar do código, `Turns::Policy.for(brand)`, que hoje devolve os padrões. No bloco 12, a política passa a ser lida da configuração da marca, versionada e auditada como as filas e regras (invariante 9), editada pelo supervisor com limites:
   - prazo do turno entre 5 s e 60 s;
   - teto do ciclo maior ou igual ao prazo do turno, no máximo 5 min;
   - aviso de progresso antes do teto do ciclo.

   A mudança vale só para ciclos novos: os prazos de quem já está esperando estão gravados no atendimento (`ai_deadline_at`) e no turno (`deadline_at`).

| Situação | Antes (30 s do ciclo) | Agora |
| --- | --- | --- |
| Agente responde em segundos | Resposta na hora | Igual |
| Cliente escreve aos 0 s e aos 20 s | Turno 2 com 8 s | Turno 2 com 20 s |
| Broker recusando ou fora do ar | Escala aos 30 s | Escala ao esgotar as retentativas (antes dos 20 s) |
| Agente vivo, mas lento | Escala aos 30 s | Escala aos 20 s do turno, no máximo aos 60 s do ciclo |
| Cliente que nunca para de escrever | Humano aos 30 s | Humano aos 60 s, com aviso aos 15 s |

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Manter 30 s fixos por ciclo | Turnos injustos e escalação em massa no pico por lentidão, não por falha |
| Reiniciar o prazo a cada mensagem, sem teto | Um cliente que escreve sem parar nunca seria atendido por ninguém |
| Retentar o turno uma vez antes de escalar | Duplica o trabalho de um agente que só estava lento e dobra a espera no caso de falha real |
| Tempos por variável de ambiente | Mudar exige reiniciar, vale para todas as marcas e não deixa auditoria |
| Tempos por fila ou categoria | O turno abre antes da triagem, então nem sempre há fila. Fica para quando a operação pedir |
| Medir a saúde do agente (heartbeat) para decidir | O agente real não oferece esse sinal hoje. Fica para quando a CloudWalk confirmar o que o agente expõe (07, seção 9) |

**Consequências.**

- (+) A IA sempre tem um tempo justo por turno, e a falha clara não espera prazo.
- (+) O cliente continua com espera máxima garantida e aviso aos 15 s.
- (−) No pior caso, a espera máxima do cliente sobe de 30 s para 60 s.
- (−) Dois prazos para validar em vez de um: o consumer confere o do turno, que nunca passa do teto.
- Os valores (20 s e 60 s) são proposta. Devem ser calibrados com o p95 do agente real e com o E4.
- Implementação: o bloco 03 grava o teto do ciclo e o prazo do turno a partir da `Turns::Policy`. A tela de configuração entra no bloco 12. O handoff no vencimento e na falha definitiva entra nos blocos 08 e 10.

## ADR-021 — Entrega ao canal: identidade, aceite e conciliação

**Proposto em 20/11/2026, no bloco 05. Aguarda aprovação.** Detalha a seção 3.2 e a 5.0 do [07](07-arquitetura.md). Mantém o [ADR-016](#adr-016--prazos-do-atendimento-e-ações-duráveis-no-outbox) e o [ADR-018](#adr-018--canais-simulados-no-formato-dos-provedores-reais).

**Contexto.** O bloco 05 entrega a resposta da IA ao canal de origem. O 07 pede `delivery_id` estável, ordem pelo `seq`, provedor que deduplica e recusa `seq` anterior, e conciliação quando o resultado fica incerto. Faltava decidir onde esses dados viajam, quando uma entrega conta como entregue e o que fazer quando as retentativas acabam.

**Decisão.**

1. **Identidade e ordem em cabeçalhos.** O corpo segue o formato do provedor. `Idempotency-Key` leva o `delivery_id`; `X-Conversation-Id` e `X-Conversation-Seq` levam a conversa e o `seq`; o corpo é assinado com o segredo da conta (ADR-019). O provedor devolve a mesma confirmação para a mesma chave, com `Idempotent-Replayed: true`.
2. **Aceite é entrega.** No chat, o `200` do `POST /messages` com `message_id` vale como `delivered`, com `provider_message_id` e `delivered_at`. O callback de status só muda a entrega quando traz `failed`. Todo callback aceito vira `delivery.status_received` na auditoria. Callback de uma mensagem que a plataforma ainda não registrou recebe `503`, para o provedor repetir depois do commit da confirmação.
3. **Falha certa avança, resultado incerto concilia.** `4xx` (exceto `429`) é rejeição definitiva: `failed`, e a próxima saída do atendimento segue. Esgotadas as retentativas (RN-43), a entrega vira `failed` (`provedor_indisponivel`) quando todas as tentativas foram sem efeito certo (conexão recusada, `503` ou `429` do provedor), e a fila avança. Se ao menos uma tentativa teve resultado incerto (timeout de leitura, conexão cortada depois do envio, outro `5xx`), a entrega fica em `sending`, o item do outbox é encerrado com `last_error = reconciliation_needed` e as saídas seguintes esperam a conciliação.

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| `delivery_id` e `seq` no corpo | Muda o formato do provedor (ADR-018) e não existe no provedor real |
| Esperar o callback `delivered` para avançar a fila | O e-mail não tem callback de entrega, e um callback perdido travaria a conversa |
| Toda falha esgotada vai para conciliação | Conexão recusada é não entrega certa: travaria o atendimento sem motivo, inclusive o aviso de transferência do bloco 10 |
| Toda falha esgotada vira `failed` | Um timeout depois do envio pode ter entregado: avançar mandaria a próxima resposta fora de ordem ou duplicada |

**Consequências.**

- (+) A mesma regra serve aos três canais e a um provedor real com idempotência.
- (+) Uma queda do provedor não trava o atendimento; só a dúvida real trava.
- (−) A conciliação precisa de tela e ação do analista (bloco 09). Até lá, uma conversa em conciliação para de receber saídas.
- (−) O `channels-mock` guarda o estado em memória: reiniciá-lo zera a deduplicação, e recriar o banco com o mock no ar colide nas conversas (`make reset` reinicia o mock).

## ADR-022 — Versão e prova do contexto do turno

**Proposto em 21/11/2026, no bloco 06. Aguarda aprovação.** Detalha a seção 3.4 do [07](07-arquitetura.md) e a RN-49. Mantém o [ADR-016](#adr-016--prazos-do-atendimento-e-ações-duráveis-no-outbox) e o [ADR-020](#adr-020--prazo-da-ia-por-turno-com-teto-do-ciclo).

**Contexto.** O ROADMAP pede a "versão do contexto" e que "o turno persistido corresponda ao contexto enviado", mas a documentação não dizia o que é essa versão nem como provar a correspondência. A RN-49 fala em "limite de tamanho" sem valor e em resumos de atendimentos anteriores que ainda não existem.

**Decisão.**

1. **Versão do contexto.** `tickets.context_version` começa em 0 e sobe 1, na mesma transação e com a linha travada, a cada gravação que muda o que a IA veria no próximo turno: mensagem do cliente e mensagem de saída visível. Não sobe em duplicata, rejeição, descarte, `escalate` nem `resolve` sem texto. O incremento é feito no banco (`UPDATE ... SET context_version = context_version + 1 ... RETURNING`), para não depender da cópia em memória nem do `lock_version`.
2. **Prova do contexto.** O turno grava `context_version` e `context_digest = "sha256:" + SHA-256(JSON canônico do context)`. JSON canônico: objetos com as chaves como texto, ordenadas por bytes em todos os níveis; arrays na ordem; números e textos como o `JSON.generate` do Ruby os escreve, sem espaços, UTF-8 sem escapes de não ASCII. Não é a RFC 8785: `1` e `1.0` dão digests diferentes. O `context` gravado é o mesmo objeto do evento no outbox, e o painel recalcula o digest para conferir. O banco exige versão e digest juntos.
3. **Limites do RN-49.** 16 000 caracteres de `text` nas mensagens pendentes e 32 000 no contexto inteiro (pendentes, histórico, resumo e resumos de atendimentos anteriores). O histórico perde as mais antigas até caber. Acima do limite das pendentes, o turno não abre (`contexto_excede_limite`) e o ciclo espera o handoff (bloco 10).
4. **Atendimentos anteriores até o bloco 10.** Até existir o resumo do atendimento, `previous_tickets[].summary` leva só fatos gravados (canal, data de abertura, estado, categoria), com o prefixo "Sem resumo gravado.", e a janela de 90 dias conta pela abertura do atendimento anterior.
5. **Canal sem janela.** Canal sem janela de agrupamento na política da marca é erro na ingestão: nada é gravado.

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Usar só `context_until_seq` como versão | Não muda quando a resposta da IA ou o analista escrevem, e não prova o conteúdo enviado |
| Comparar o `context` gravado com o do outbox, sem digest | Exige guardar e ler o evento inteiro para sempre; o digest é curto e serve também ao eval |
| JSON canônico pela RFC 8785 | Exige biblioteca e regras de número que o Ruby não traz; a forma própria está documentada aqui |
| Truncar mensagens pendentes grandes | A RN-49 manda mandar todas por inteiro; cortar mudaria o que o cliente disse |
| Omitir `previous_tickets` até o bloco 10 | O agente perderia o vínculo com o atendimento anterior (RN-09) sem ganho de segurança |

**Consequências.**

- (+) Dá para provar, turno a turno, o que a IA recebeu, inclusive em evals (bloco 16).
- (+) Um contexto grande não trava o agente nem estoura o modelo.
- (−) Até o bloco 10, um caso com pendentes acima do limite fica com a IA, sem turno, até o prazo do ciclo.
- (−) Os limites são proposta; devem ser calibrados com o agente real.

## ADR-023 — Evals com execução gravada e checagens determinísticas

**Proposto em 21/11/2026, no bloco 07. Aguarda aprovação.** Antecipa a parte de evals do bloco 16 e segue a seção 4 do [09](09-evolucao-da-integracao-com-ia.md#4-como-avaliar-uma-nova-versão-do-agente) ("checagens determinísticas").

**Contexto.** O bloco 07 pede o primeiro eval, o da corrida dos 3 s, com resultado esperado, observado e link para o turno. Nenhum documento dizia onde guardar o resultado nem como o eval roda.

**Decisão.**

1. **Tabela `eval_runs`**, só de inserção (07, seção 4): cenário, status, agente (modelo, versão, `config_hash`), esperado, observado, lista de checagens e o atendimento e o `trace_id` que servem de evidência.
2. **O eval roda o caminho real da plataforma**: ingestão, `scheduler`, abertura do turno e aplicação da ação, com o relógio real, num atendimento sintético da marca. As ações do agente vêm de um gabarito fixo do cenário, válido no contrato `agent_outbound` e identificado como `eval-fixture`, para que o resultado dependa só da regra da plataforma.
3. **Disparo** por comando (`bin/rails evals:run[corrida-3s]`, `make eval`), fora do `rspec`. O `rspec` testa o executor com o relógio controlado.
4. **Painel**: a aba de evals mostra cada cenário conhecido, a última execução e o histórico; cenário que nunca rodou aparece como "nunca executado".
5. **Isolamento da pilha real.** O atendimento do eval nasce marcado no commit da mensagem 1: a mensagem vem da conta de provedor de eval da marca (`<marca>-chat-eval`, `provider_accounts.evaluation = true`, inativa, criada pelo seed ou pelo eval), e a ingestão grava `tickets.evaluation = true`, que não muda depois (trigger). O worker não publica no broker o turno de um atendimento de eval (`agent_event.discarded`, `reason: eval`) nem entrega a saída dele ao canal (`deliveries.status = cancelled`, auditoria `delivery.cancelled`, `reason: eval`). O eval faz ele mesmo a volta do worker na saída e registra o desfecho em `observed.deliveries`. Uma ação de outro agente no atendimento torna a execução `error` ("cenário contaminado"), não `failed`. O eval só registra a abertura do próprio atendimento (`DispatchDue` com `brand_id` e `ticket_ids`). O executor não exercita a publicação no broker nem a entrega ao provedor: esses trechos têm testes próprios (blocos 03 e 05).

**Alternativas consideradas.**

| Alternativa | Por que não |
| --- | --- |
| Guardar o resultado só na auditoria | A auditoria é do atendimento; um eval precisa de esperado, observado e checagens consultáveis por cenário |
| Rodar o eval pelo simulador e pelo agent-mock com Kafka | Depende da latência do agente e do Compose; o resultado deixaria de ser determinístico. Fica para o bloco 16, como eval de ponta a ponta |
| Eval dentro do `rspec` | O `rspec` usa transação e relógio de teste; o eval precisa mostrar o comportamento real e ficar registrado para o painel |

**Consequências.**

- (+) O critério de aceite da corrida dos 3 s fica demonstrável no navegador, com link para a evidência.
- (+) O bloco 16 reaproveita a tabela e o executor para os outros cenários.
- (−) O eval com gabarito fixo não mede a qualidade do agente, só a regra da plataforma.
- (−) Uma execução leva alguns segundos de relógio real.
- (+) O eval passa com o `scheduler`, o worker e o agent-mock no ar, e nada do eval chega ao agente nem ao cliente.
- (−) Atendimentos de eval ficam no banco como dados sintéticos, fora do fluxo de saída. Um eval de ponta a ponta pelo simulador (bloco 16) vai precisar de outro desenho.

---

## Referências

- TAPI "Help Desk Integrado a Agentes de IA", seções 7 a 10.
- [AWS Builders' Library: estratégias de isolamento entre inquilinos em SaaS](https://aws.amazon.com/builders-library/saas-tenant-isolation-strategies/)
- [Apache Kafka 4.3: notas de atualização (apenas KRaft)](https://kafka.apache.org/43/getting-started/upgrade/)
- [Karafka: documentação](https://karafka.io/docs)
- [Redpanda: licenciamento](https://docs.redpanda.com/23.3/get-started/licenses)
- [Rails 8: Solid stack vs Redis/Sidekiq em produção](https://rubylearning.com/blog/2026/03/16/rails-8-solid-stack-vs-redis-sidekiq-production)
- [Chatwoot: stack (Rails, Vue, ActionCable, Sidekiq, Redis)](https://openapps.pro/apps/chatwoot)
- [Chatwoot no Railway: dimensionamento dos serviços](https://railway.com/deploy/chatwoot-intercom-alternative-sidekiq-worker-2fa-included--chatwoot-or-intercom-alternative-sidekiq)
- [WhatsApp Cloud API: mensagens de serviço e janela de 24 h](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/send-messages)
- [Gmail API: notificações push via Pub/Sub](https://developers.google.com/gmail/api/guides/push)
- [Gmail API: recurso `users.messages` (thread, `In-Reply-To`, `References`)](https://developers.google.com/workspace/gmail/api/v1/reference/users/messages)

## ADR-024 — Login do painel e escopo por marca

**Status:** vigente (bloco 14).

**Contexto.** O painel mostra dados de várias marcas e o analista não pode ver a marca que não é dele (RN-52, RNF-24). Até o bloco 13 o painel era aberto. RNF-26 pede senha com hash e sessão com expiração, no nível ASVS 1.

**Decisão.**

1. Login por e-mail e senha com `has_secure_password` (bcrypt) e sessão de cookie do Rails que expira em 8 h sem uso.
2. Escopo de marcas = marcas das equipes do usuário. Toda leitura do painel parte desse conjunto (invariante 6). Fora dele, `404`.
3. Perfis: `analyst` atende e vê as marcas da equipe; `supervisor` faz o mesmo e acessa DLQ e evals.
4. ActionCable só aceita conexão com sessão válida.
5. Os webhooks de entrada continuam fora do login: eles têm a assinatura do ADR-019.

**Alternativas.** Row-Level Security no Postgres (já descartada acima: exige contexto de sessão em cada job); gem Devise (mais peças do que o projeto precisa); SSO (fora do escopo, sem sistema da CloudWalk).

**Consequências.** Os seeds criam usuários com senha sintética conhecida (só dados sintéticos, RN-51). Tentativas de login erradas não revelam se o e-mail existe.
