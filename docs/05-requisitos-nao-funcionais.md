# 05 — Requisitos não funcionais (RNF)

Os RNF definem **quão bem** a plataforma deve funcionar. Cada um tem uma meta numérica, um método de medição e o experimento que o comprova (ver [Experimentos](#4-experimentos-que-comprovam-os-rnf)). Prioridade em MoSCoW, como nos [RF](04-requisitos-funcionais.md).

São 33 RNF: 21 obrigatórios (**M**) e 12 importantes (**S**).

## 1. Premissas de volume

O TAPI fala em "milhares de atendimentos novos por dia, com picos sazonais", sem número. As premissas abaixo fecham essa lacuna e devem ser **validadas com a CloudWalk** no onboarding. Se mudarem, só esta tabela muda: as metas de carga derivam dela.

| Parâmetro | Valor | Origem |
| --- | --- | --- |
| Atendimentos novos por dia | ≈ 10.000 | **Derivado de dado oficial.** A IA tratou ~2,6 mi de solicitações, 75% do total da InfinitePay em 2023 (CloudWalk, 25/03/2024). Total ≈ 3,47 mi/ano ≈ 9.500/dia |
| Mensagens por atendimento (cliente + atendente) | 8 | Premissa |
| Concentração na hora de pico | 15% do dia | Premissa |
| Mensagens/s na hora de pico normal | ≈ 3,3 | 10.000 × 15% × 8 ÷ 3.600 |
| Fator de pico sazonal | 5× | Premissa |
| **Carga de referência (RNF-09)** | **20 msg/s** | ≈ 3,3 × 5, arredondado para cima |
| **Rajada (RNF-10)** | **100 msg/s por 60 s** | 5× a carga de referência |
| **Capacidade-alvo (RNF-12)** | **≥ 60 msg/s** | 3× a carga de referência |

**Sensibilidade e limites do dado.** O número de 2023 cobre só a InfinitePay no Brasil e mede "solicitações", não "atendimentos". A base cresceu desde então (3 mi de clientes, 5 mi de usuários ativos e 7 mi de usuários mensais ativos atendidos por agentes de IA, segundo a CloudWalk), então 10 mil/dia tende a ser um piso. Num cenário de **2× o volume** (20 mil/dia), o pico sazonal seria 20.000 × 15% × 8 ÷ 3.600 × 5 ≈ **33 msg/s**. A capacidade-alvo de 60 msg/s cobre esse cenário com folga de 1,8×.

**Comparação com um help desk open source.** O Chatwoot documenta que 4 cores e 4 GB atendem até 10 mil conversas/dia, e 8 cores e 8 GB até 20 mil. Acima disso, recomenda mais servidores de aplicação. O E1 usa 4 vCPU e 8 GB e compara o resultado com essa faixa.

## 2. Como ler as metas de latência

- **Percentis, nunca média.** O livro de SRE do Google avisa que a média esconde a cauda: 100 ms de média a 1.000 req/s pode conviver com requisições de ~5 s. Por isso as metas usam p50, p95 e p99.
- **Latência de sucesso e de erro separadas.** Uma resposta 500 rápida melhora a média sem melhorar nada. Os relatórios do experimento trazem as duas.
- **Modelo aberto de carga.** O gerador dispara requisições numa taxa fixa, independente de o sistema estar respondendo (executor `constant-arrival-rate` no k6). Num modelo fechado, o gerador espera a resposta antes de enviar a próxima e **subestima** a latência quando o sistema satura (*coordinated omission*).
- **O agente é descontado.** O agente é um mock com latência configurável (RF-38), então a latência fim a fim depende de um parâmetro nosso. A meta de plataforma mede o **overhead**: tempo total menos o tempo que o agente declarou ter gastado.
- **Orçamento por salto não soma percentis.** Somar p95 de cada salto não dá o p95 do total. O orçamento orienta o projeto, mas a meta vale para a medição fim a fim.

### Orçamento de latência do fluxo cliente → agente → cliente

| Salto | Meta p95 | Meta p99 |
| --- | --- | --- |
| 1. Canal → plataforma (ack da ingestão) | 200 ms | 500 ms |
| 2. Plataforma → webhook → broker → tópico | 100 ms | 250 ms |
| 3. Tópico → consumidor do agente | 100 ms | 250 ms |
| 4. Agente (mock) | **excluído** (configurável) | — |
| 5. Tópico de saída → plataforma aplica a resposta | 200 ms | 500 ms |
| 6. Plataforma → canal do cliente | 200 ms | 500 ms |
| **Overhead total medido fim a fim (RNF-03)** | **≤ 1 s** | **≤ 2,5 s** |

A soma dos p95 dos saltos dá 800 ms, o que deixa folga para o overhead de 1 s. A soma dos p99 dá 2 s, contra a meta de 2,5 s.

## 3. Requisitos

### Desempenho

| ID | Requisito | Meta / métrica | Como verificar | Prior. | Exp. |
| --- | --- | --- | --- | --- | --- |
| RNF-01 | A ingestão de mensagens (endpoints de chat, WhatsApp e e-mail) deve **confirmar o recebimento e processar depois**. | Ack HTTP: p95 ≤ 200 ms, p99 ≤ 500 ms a 20 msg/s. Nunca acima de 5 s | k6, modelo aberto, medindo do envio ao ack | M | E1 |
| RNF-02 | As APIs síncronas (painel, configuração de filas, busca) devem responder rápido. | p95 ≤ 500 ms, p99 ≤ 1 s. **Apdex (T = 500 ms) ≥ 0,94** | k6 com tráfego misto de leitura e escrita | M | E1 |
| RNF-03 | O **overhead da plataforma** na ida e volta (mensagem do cliente até a resposta do agente entregue ao canal, descontado o tempo do agente) deve ser baixo. Também é descontada a **espera intencional** da janela de agrupamento (RN-55), que é medida à parte. | p50 ≤ 300 ms, p95 ≤ 1 s, p99 ≤ 2,5 s a 20 msg/s | Timestamps por salto no `trace_id` (RNF-20). Overhead = fim a fim − tempo do agente − janela de agrupamento | M | E1 |
| RNF-04 | O salto webhook → broker → tópico de entrada deve ser rápido, incluindo a validação de HMAC. | p99 ≤ 100 ms | Timestamp de recebimento no broker e de publicação no tópico | S | E1 |
| RNF-05 | O cliente deve **perceber que foi atendido** rápido. | Indicador de recebido/digitando ≤ 1 s. Resposta final ≤ 10 s no p95, com mock a 2 s. A resposta final é a **latência percebida**: inclui a janela, os turnos superados e a entrega no canal. Aviso de progresso aos 15 s (RN-57) | Medição no simulador de cliente (RF-04), separando espera intencional, fila, processamento e entrega | S | E1 |
| RNF-06 | O **handoff** deve entrar na fila com o histórico acessível. O resumo é medido separadamente (RN-40). | Entrada na fila p95 ≤ 2 s. Resumo disponível p95 ≤ 5 s nos casos com resumo. Mede-se também a proporção de casos marcados "sem resumo". Nova mensagem no painel em p95 ≤ 1 s | Medir da decisão de escalar à aparição na fila e, separadamente, ao resumo disponível. Registrar ausência e motivo do resumo | M | E4 |
| RNF-07 | Mudanças em filas e regras devem **valer sem reinício** (RF-16). | O primeiro atendimento criado após o "salvar" usa a nova versão. Propagação p99 ≤ 5 s | Script: edita regra, cria atendimento a cada 500 ms, mede quando a versão nova passa a ser aplicada | M | E3 |
| RNF-08 | A listagem da fila de escalas deve continuar rápida com volume de dados. | p95 ≤ 300 ms com 100 mil atendimentos no banco (gerados pelo RF-61) | k6 sobre a base populada, com `EXPLAIN ANALYZE` anexado | S | E1 |

### Escalabilidade

| ID | Requisito | Meta / métrica | Como verificar | Prior. | Exp. |
| --- | --- | --- | --- | --- | --- |
| RNF-09 | A plataforma deve **sustentar o volume de referência** com estabilidade. | 20 msg/s por 30 min, com RNF-01 a RNF-03 atendidos e erros 5xx < 0,1% | k6 em rampa até 20 msg/s e patamar de 30 min. Resultado sobre os 25 min finais, descartando 5 min de aquecimento | M | E1 |
| RNF-10 | A plataforma deve **absorver uma rajada** sem perder mensagem. | 100 msg/s por 60 s: 0 mensagens perdidas, erros 5xx < 1%, fila esvaziada em ≤ 5 min após a rajada | k6 com patamar de 20 msg/s, rajada e retorno ao patamar. Mede profundidade da fila e *lag* do consumidor | M | E1 |
| RNF-11 | O **processamento deve escalar horizontalmente**. | Dobrar as réplicas de worker/consumidor aumenta a vazão sustentável em ≥ 1,6× (eficiência ≥ 80%) | Mesmo teste de capacidade com 1, 2 e 4 réplicas | S | E5 |
| RNF-12 | Deve haver **margem de capacidade** sobre a carga de referência, com o ponto de saturação documentado. | Capacidade máxima sustentável ≥ 60 msg/s (3×) antes de o p95 do RNF-03 estourar | Rampa crescente até o p95 romper a meta. Registra o ponto e o gargalo | S | E1, E5 |
| RNF-13 | A **ordem das mensagens** de uma conversa segue o `seq` persistido. Entregas visíveis respeitam essa ordem, e respostas de turnos superados são rejeitadas (RN-56). | 0 inversões na sequência visível de cada conversa e 0 ações aplicadas de turno superado | Inverter publicação e confirmações entre workers. Conferir `seq` das entregas aceitas e estado dos turnos no banco | M | E4, E5 |

### Confiabilidade

| ID | Requisito | Meta / métrica | Como verificar | Prior. | Exp. |
| --- | --- | --- | --- | --- | --- |
| RNF-14 | **Nenhuma mensagem aceita pode ser perdida.** O ack só sai depois de a mensagem estar persistida (padrão *outbox*). | 0 perdas. Cada ID de mensagem confirmado aparece uma vez no histórico e tem registro de ingestão na auditoria | Reconciliar IDs confirmados, histórico e auditoria após carga e falhas injetadas | M | E1, E2 |
| RNF-15 | O processamento deve ser **idempotente** (RF-35). | Com 20% de eventos duplicados, 0 efeitos duplicados. No máximo uma ação final por turno e uma entrega visível por `delivery_id` | Reentregar webhooks, eventos e ações agendadas. Enviar ações finais com IDs distintos para o mesmo turno e perder o ACK do canal após aceitação | M | E2, E4 |
| RNF-16 | Falhas de entrega devem ter **retentativa com backoff e DLQ** (RF-34). | Backoff exponencial com jitter (1, 2, 4, 8, 16 s), N = 5. 100% das falhas permanentes terminam na DLQ, retida por ≥ 7 dias (o mesmo prazo de reentrega do WhatsApp‡) | Agente configurado com 100% de falha: verifica tentativas, intervalos e destino final | M | E2 |
| RNF-17 | A plataforma deve **se recuperar de queda** do agente ou do broker preservando o histórico aceito. | Queda de 5 min a 20 msg/s: 0 perdas e backlog drenado em ≤ 5 min após o retorno, contando retomadas válidas e descartes auditados | Parar o contêiner, reconciliar mensagens confirmadas no Postgres e classificar os itens pendentes em retomados, superados ou expirados | M | E2 |
| RNF-18 | O **fallback por timeout** tem prazo do atendimento, contado desde a primeira mensagem pendente (RF-36, RN-46). | A partir de `T` (padrão 30 s), 0 ações tardias da IA aplicadas. Caso ainda pendente com a IA entra na fila humana até `T + 2 s` | Testar o mock mudo e o broker indisponível antes do primeiro envio. Atrasar o job de timeout e injetar uma resposta no prazo exato e outra depois dele | M | E2 |
| RNF-19 | A ingestão deve ter alta disponibilidade como **meta de projeto**. | SLO de 99,9% por mês na ingestão (orçamento de erro de 43,2 min/mês). Sem janela de manutenção planejada, porque o suporte da InfinitePay é 24/7‡. RPO = 0 para mensagem aceita. RTO ≤ 5 min por restart do contêiner | Medido apenas na janela do experimento, não em produção. O relatório deve dizer isso | S | E2 |

### Rastreabilidade e observabilidade

| ID | Requisito | Meta / métrica | Como verificar | Prior. | Exp. |
| --- | --- | --- | --- | --- | --- |
| RNF-20 | Todo evento deve carregar um **trace ID** propagado entre plataforma, broker e agente (RF-56), no padrão W3C `traceparent`. | 100% dos logs e eventos dos 6 saltos com `trace_id`. 0 órfãos | Consulta nos logs e na auditoria: eventos sem `trace_id` | M | E1, E2 |
| RNF-21 | A **auditoria** (RF-54) deve ser completa e imutável, sem pesar no caminho crítico. | 100% dos eventos do RF-54 registrados. Tabela só de inserção (`UPDATE` e `DELETE` revogados ao usuário da aplicação). Escrita da auditoria adiciona ≤ 50 ms no p95 | Teste de permissão no banco. Comparação de contagem. Medição com e sem auditoria | M | E1, E6 |
| RNF-22 | A plataforma deve expor os **quatro sinais de ouro** do Google SRE: latência, tráfego, erros e saturação. | Endpoint `/metrics` (Prometheus) com histograma de latência, req/s, taxa de erro, profundidade de fila, *lag* do consumidor e CPU/memória. Logs em JSON | Painel (Grafana ou equivalente) usado durante o experimento | S | E1 |

### Segurança e LGPD

| ID | Requisito | Meta / métrica | Como verificar | Prior. | Exp. |
| --- | --- | --- | --- | --- | --- |
| RNF-23 | Os webhooks devem ser **autenticados**: o da plataforma ao broker (RF-30) e os de entrada dos canais, com o esquema de cada provedor ([ADR-019](08-decisoes-de-arquitetura.md#adr-019--contas-dos-provedores-e-autenticação-dos-webhooks-de-entrada)). | HMAC-SHA256 sobre o corpo bruto, comparação em tempo constante, janela anti-replay de ±5 min. 100% dos inválidos rejeitados (401/403) | Testes automatizados: assinatura errada, ausente, corpo alterado, timestamp antigo | M | E6 |
| RNF-24 | As marcas devem ser **isoladas** entre si (RF-58, RF-59). | 0 acessos entre marcas na matriz perfil × marca. Todo acesso a dados filtra por marca | Teste automatizado que tenta ler e alterar dados de outra marca por API e por interface | M | E6 |
| RNF-25 | A plataforma deve respeitar a **LGPD** (restrição do TAPI). | 100% dos dados sintéticos. Telefone, e-mail e documento mascarados nos logs. Retenção configurável | Varredura de padrões de PII nos logs do experimento. Revisão do gerador (RF-61) | M | E6 |
| RNF-26 | Autenticação e autorização devem seguir práticas básicas de mercado. | Senhas com hash (argon2 ou bcrypt), sessão com expiração, perfis (RF-59), segredos fora do repositório. Alinhado ao OWASP ASVS nível 1 | Checklist ASVS L1 e varredura de dependências (Trivy ou `pip audit`), sem vulnerabilidade crítica | S | E6 |
| RNF-33 | A ingestão deve ter **limite de taxa por marca e canal**, para que o pico de uma marca não degrade as outras. | Excedente recebe HTTP 429 com `Retry-After`. Limites configuráveis. Marca sob rajada não eleva o p95 das demais em mais de 20%. Referência: Zendesk limita a API de 200 a 2.500 req/min conforme o plano‡ | Rajada de 100 msg/s em uma marca enquanto outra mantém 5 msg/s, comparando o p95 das duas | S | E2 |

### Manutenibilidade

| ID | Requisito | Meta / métrica | Como verificar | Prior. | Exp. |
| --- | --- | --- | --- | --- | --- |
| RNF-27 | Os **critérios de aceite dos RF críticos** (seção final do [04](04-requisitos-funcionais.md)) devem virar testes automatizados. | 100% automatizados e executados no CI a cada commit. Cobertura ≥ 70% no domínio (roteamento, estados, idempotência, handoff) | Pipeline de CI com relatório de cobertura | M | — |
| RNF-28 | Os **contratos** de mensagem (webhook, evento do tópico, resposta do agente) devem ser versionados e validados. | Esquema JSON versionado. 100% das mensagens validadas na entrada e na saída. Mensagem inválida vai para a DLQ | Testes de contrato com payloads válidos e inválidos | S | E2 |

### Portabilidade e reprodutibilidade

| ID | Requisito | Meta / métrica | Como verificar | Prior. | Exp. |
| --- | --- | --- | --- | --- | --- |
| RNF-29 | A plataforma deve ser **self-hosted** e subir com um comando. | `docker compose up` sobe aplicação, banco, broker, workers, agente mock e interface em ≤ 10 min numa máquina limpa, sem passo manual além do `.env`. Funciona em 4 vCPU e 8 GB (mesma classe do Chatwoot: 4 cores e 4 GB até 10 mil conversas/dia†) | Teste numa VM limpa, seguindo só o README, com tempo cronometrado | M | — |
| RNF-30 | Os **experimentos** devem ser reprodutíveis. | Um comando (`make bench`) gera dados e gráficos. Semente fixa. Hardware e versões registrados. ≥ 3 execuções por cenário, com mediana e dispersão | Segunda pessoa (ou máquina) reproduz os números dentro de ±15% | M | E1 a E6 |

### Usabilidade

| ID | Requisito | Meta / métrica | Como verificar | Prior. | Exp. |
| --- | --- | --- | --- | --- | --- |
| RNF-31 | O supervisor deve configurar filas e regras **sem código**. | Criar uma fila e uma regra e ver o efeito em ≤ 3 min, por roteiro | Teste cronometrado com roteiro e pelo menos 2 pessoas | S | E3 |
| RNF-32 | O painel do analista deve ser **ágil e direto**. | Resumo e motivo da escalação visíveis na primeira tela do caso. Histórico completo a ≤ 2 cliques. Core Web Vitals "bom": LCP ≤ 2,5 s e INP ≤ 200 ms | Lighthouse no painel com a base populada e roteiro de uso | S | E4 |

## 4. Experimentos que comprovam os RNF

O TAPI pede um experimento com hipótese, método e limitações. O **E1 é o experimento principal**. Os demais cobrem RNF que ele não alcança.

| Exp. | Nome | Hipótese | Método | RNF |
| --- | --- | --- | --- | --- |
| E1 | Carga e latência | Com a configuração de referência (4 vCPU, 8 GB), a plataforma sustenta 20 msg/s por 30 min com overhead p95 ≤ 1 s, sem perder mensagens, e absorve 100 msg/s por 60 s | k6 em modelo aberto: aquecimento, patamar, rajada e rampa até a saturação. Mock a 2 s de latência. Resultado comparado com a faixa publicada do Chatwoot | 01 a 05, 08 a 10, 12, 14, 20 a 22, 30 |
| E2 | Resiliência | Mensagens confirmadas permanecem no histórico, prazos continuam acionáveis, efeitos são únicos e o backlog é drenado em até 5 min após o retorno | Injetar 20% de duplicatas, mock mudo ou 100% falho, queda de 5 min do agente e do broker, payload inválido, perda de Redis e queda do scheduler após o commit da ação. Conferir os cenários de prazo e recuperação abaixo | 14 a 20, 28, 33 |
| E3 | Filas configuráveis | Mudanças de fila e regra valem em até 5 s, sem reinício, e a auditoria registra a versão aplicada | Script edita regras enquanto atendimentos chegam. Verifica versão aplicada e roteamento esperado | 07, 31 |
| E4 | Fluxo de handoff e turnos | Entrada na fila com histórico acessível em p95 ≤ 2 s. Resumo e cobertura medidos à parte pela RNF-06. Cada ação da IA aplicada cobre a última mensagem gravada antes do commit e ocorre no máximo uma vez por turno | Escalar por agente, pedido, regra e timeout. Variar a chegada de novas mensagens em torno do commit da resposta. Verificar a ordem de entrega e a disponibilidade da fila com a equipe humana no limite | 05, 06, 13, 15, 32 |
| E5 | Escalabilidade horizontal e capacidade do agente | Dobrar as réplicas aumenta a vazão em ≥ 1,6×, sem quebrar a ordem. A vazão de turnos acompanha partições ÷ latência do agente | Capacidade máxima com 1, 2 e 4 réplicas. Dois perfis de carga separados: muitas conversas independentes e rajadas na mesma conversa. Mede em unidades distintas (mensagens recebidas/s, turnos/s, respostas entregues/s) e identifica qual fila acumula primeiro (Redis, outbox, tópico, prazos) | 11, 12, 13 |
| E6 | Segurança e isolamento | Webhook inválido é sempre rejeitado, não há acesso entre marcas e a auditoria é imutável | Testes automatizados adversariais e varredura de PII nos logs. O isolamento entre marcas é testado também nos workers, nos eventos do Kafka, nas inscrições do ActionCable, no reprocessamento da DLQ e com IDs externos iguais em marcas diferentes | 21, 23 a 26 |

### Cenários de prazo, recuperação e handoff

- **E2, prazo sem publicação.** Derrubar o broker antes do primeiro turno ser publicado. O caso deve entrar na fila humana até `T + 2 s` com todas as mensagens confirmadas. Na recuperação, o caso permanece com humano e seus eventos expirados não reativam a IA.
- **E2, resposta tardia.** Atrasar de propósito o job de timeout. Enviar ações que seriam válidas em contexto e atribuição exatamente em `T` e depois de `T`, antes do job. Ambas são rejeitadas. Medir a entrada na fila até `T + 2 s` nos cenários de disponibilidade normal do scheduler e do worker.
- **E2, recuperação do scheduler.** Interromper o processo após gravar a ação durável e antes de enfileirar. Repetir com perda do job no Redis e com duas réplicas concorrendo pelo mesmo prazo. Confirmar um único aviso e uma única escalação para o ciclo ainda pendente. Repetir com um ciclo já encerrado e conferir que nenhum efeito é aplicado.
- **E4, limite do contexto.** Gravar a mensagem 2 aos 3 s e atrasar de propósito o worker do turno 2. A ação que chega aos 3,5 s é rejeitada e o turno seguinte contém ambas as mensagens. Inverter a ordem de commit e conferir que a mensagem 2 inicia uma continuação. Simular também uma resposta antes do ACK do broker, dois eventos de ação final para o mesmo turno e uma resposta com contexto divergente do turno salvo.
- **E4, cliente pede humano.** Com uma saída do bot pendente, verificar seu cancelamento. Com uma chamada ao canal já iniciada, perder a confirmação, retentar com o mesmo `delivery_id` e verificar a ordem visível da resposta do bot, do aviso e da primeira mensagem humana. Nos dois cenários, o caso deve chegar à fila sem esperar a entrega.
- **E4, capacidade e disponibilidade humana.** Dois workers disputam a última vaga. Só um a ocupa. Repetir com analista offline em `com_analista` e em `aguardando_cliente` e verificar o retorno à fila, a liberação da vaga e o SLA preservado.

### Limitações a declarar no relatório

- O agente é mock: a latência dele é um parâmetro, não uma medida. Por isso o foco é o overhead da plataforma.
- Tudo roda em uma máquina só. A rede entre componentes é a do Docker, mais rápida que a de produção. Os números são **limite inferior** de latência.
- O volume de referência é derivado de um dado oficial de 2023 (seção 1), mas "solicitações" não é igual a "atendimentos", o dado cobre só a InfinitePay no Brasil e não há número atual nem da JIM.
- O SLO de disponibilidade não pode ser medido em um mês de projeto. Vale como meta de projeto e como teste de recuperação.
- Os canais são simulados. WhatsApp e e-mail reais têm latência e limites próprios.

## 5. Referências de mercado

O mercado não tem um número universal de latência. Os SLOs reais são definidos por cada serviço. As metas deste documento vêm das fontes abaixo e do orçamento da seção 2. Os números de benchmark de brokers publicados por fornecedores **não foram copiados**: a comparação Kafka × Redpanda é contestada (uma análise independente de execução longa mostrou degradação de p99 de 11 ms para segundos no Redpanda). Medimos o broker que escolhermos.

| Referência | O que sustenta | Usada em |
| --- | --- | --- |
| † [Google SRE Book, cap. 6: Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) | Os quatro sinais de ouro. Percentis em vez de média. Latência de sucesso e de erro medidas separadamente | RNF-01 a 03, 22 |
| † [Nielsen Norman Group: Response Times, the 3 Important Limits](https://www.nngroup.com/articles/response-times-3-important-limits/) | 0,1 s parece instantâneo. 1 s preserva o fluxo de pensamento. 10 s é o limite de atenção | RNF-02, 05, 06 |
| † [Hookdeck: guia de webhooks do WhatsApp](https://hookdeck.com/webhooks/platforms/guide-to-whatsapp-webhooks-features-and-best-practices) | Receptor deve responder 200 em 5 a 10 s (Meta recomenda < 10 s) e processar depois. Reentrega *at-least-once* por até 7 dias, sem DLQ do lado da Meta. Deduplicar por ID. Validar `X-Hub-Signature-256` | RNF-01, 14, 15, 23 |
| † [Vanlightly: Kafka × Redpanda, testes longos](https://jack-vanlightly.com/analyses/2023/5/15/kafka-vs-redpanda-performance-part-2-long-running-tests) | Latência de broker depende de carga, duração e hardware. Não adotar número de fornecedor | RNF-04, 12 |
| † [CloudWalk: a IA e o retorno de US$ 20 mi (25/03/2024)](https://www.cloudwalk.io/newsroom/artificial-intelligence-brings-20-million-in-returns-for-cloudwalk) | "75% do total de solicitações" da InfinitePay em 2023, cerca de 2,6 mi | Seção 1 |
| † [Chatwoot: requisitos do sistema](https://developers.chatwoot.com/self-hosted/deployment/requirements) | 4 cores/4 GB até 10 mil conversas/dia. 8 cores/8 GB até 20 mil. Acima disso, mais servidores de aplicação | Seção 1, RNF-29, E1 |
| ‡ [Zendesk: rate limits](https://developer.zendesk.com/api-reference/introduction/rate-limits/) | 200 a 2.500 req/min por plano, com HTTP 429 e `Retry-After` | RNF-33 |
| ‡ [Zendesk: Integration builder FAQs](https://support.zendesk.com/hc/en-us/articles/8560379152282-Integration-builder-FAQs) | Timeout de 9 s para a API chamada pelo AI agents workspace | RNF-18 |
| ‡ [Freshdesk: webhooks em automações](https://support.freshdesk.com/support/solutions/articles/132589-using-webhooks-in-automation-rules) | Falha é retentada a cada 30 min, até 48 chamadas | RNF-16 |
| ‡ [Stripe: webhooks](https://docs.stripe.com/webhooks) | Reentrega por até 3 dias com backoff exponencial. Responder sucesso logo e adiar a lógica | RNF-01, 16 |
| ‡ [Google SRE Workbook: error budget](https://sre.google/workbook/error-budget-policy/) | Orçamento de erro = 1 − SLO. 99,9% permite 0,1% de falhas | RNF-19 |
| Apdex (Apdex Alliance) | Índice de satisfação: (satisfeitos + tolerados ÷ 2) ÷ total, com T de satisfação e 4T de tolerância. Faixa 0,94 a 1,00 é "excelente" | RNF-02 |
| Core Web Vitals (web.dev) | Limites "bom": LCP ≤ 2,5 s, INP ≤ 200 ms | RNF-32 |
| OWASP ASVS | Checklist de segurança de aplicação, nível 1 | RNF-26 |
| Documentação do k6 (executores de taxa de chegada) | Modelo aberto de carga, que evita *coordinated omission* | Seção 2, E1 |
| TAPI, seção 9 | Critérios de avaliação: robustez diante de falhas, reentregas e picos; escalabilidade frente ao volume de referência; reprodutibilidade | RNF-09 a 18, 30 |

† Abertas e conferidas ao redigir.

‡ Citadas por uma pesquisa no Perplexity (01/11/2026), **não abertas por mim**. Conferir o link e o número antes da entrega.

As demais são padrões amplamente documentados, mas **os links e números também devem ser conferidos antes da entrega**.

### Lacunas e conflitos conhecidos

- **Timeout do webhook do WhatsApp:** o Hookdeck diz 5 a 10 s e outro material de terceiros diz cerca de 20 s. Nenhum é fonte primária. A meta de ack (p99 ≤ 500 ms) fica muito abaixo dos dois.
- **Prazos de reentrega do mercado são de dias** (WhatsApp 7 dias, Stripe 3 dias, Freshdesk cerca de 24 h). Nosso backoff de segundos vale só para a tentativa automática. O prazo longo fica com a DLQ e o reprocessamento manual (RF-37).
- **Não encontrado em fonte pública:** atendimentos/dia atuais, TPV diário e picos sazonais da CloudWalk; SLA de resposta, NPS, CSAT e disponibilidade; stack (Rails, Kafka); latência p50/p95/p99 de Zendesk, Intercom, Chatwoot e Zammad; benchmark independente de Kafka, Redpanda e RabbitMQ; benchmark de PostgreSQL para paginação e auditoria; orientação da ANPD sobre retenção de logs e mascaramento. Essas metas seguem como **metas de projeto**, justificadas pelo orçamento da seção 2, e valem como perguntas para o onboarding com a CloudWalk.

## 6. Rastreabilidade com os RF

| RNF | RF relacionados |
| --- | --- |
| RNF-01, 03, 04 | RF-01 a RF-05, RF-29 a RF-31 |
| RNF-06 | RF-39 a RF-42, RF-45 |
| RNF-07, 31 | RF-13 a RF-18 |
| RNF-14 a 18 | RF-34 a RF-36 |
| RNF-20, 21 | RF-54 a RF-56 |
| RNF-23 | RF-30 |
| RNF-24 | RF-58, RF-59 |
| RNF-28 | RF-29, RF-31, RF-33 |
| RNF-30 | RF-38, RF-61 |
| RNF-33 | RF-01 a RF-03, RF-58 |
