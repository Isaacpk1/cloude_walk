# Roadmap de construção do Help Desk CloudWalk

Plano de quatro semanas para um projeto individual. Os 20 blocos indicam a ordem de execução. Alguns cabem no mesmo dia e outros podem ocupar mais de um. O objetivo é terminar cada semana com um fluxo que possa ser demonstrado no navegador.

Referências do projeto: [escopo](docs/02-escopo.md), [requisitos funcionais](docs/04-requisitos-funcionais.md), [requisitos não funcionais e experimentos](docs/05-requisitos-nao-funcionais.md) e [arquitetura](docs/07-arquitetura.md).

## Onde estamos

| Bloco | Situação | Observação |
| --- | --- | --- |
| 01. Ambiente e dados iniciais | **Feito** | Compose validado com `make up` |
| 02. Entrada e gravação de uma mensagem | **Feito** | Compose validado com `make up`, com o `channels-mock`. Canal implementado: chat do app (WhatsApp e e-mail no bloco 15) |
| 03. Publicação no broker e Kafka | **Feito** | Validado em 19/11/2026 com o Compose completo no Docker Desktop (Windows): turnos publicados no Kafka real, turno superado pela mensagem nova e `401` com assinatura inválida. Turno aberto pelo `scheduler` no fim da janela do chat, sem atalho, e prazo da IA do [ADR-020](docs/08-decisoes-de-arquitetura.md#adr-020--prazo-da-ia-por-turno-com-teto-do-ciclo) |
| 06. Agrupamento de mensagens | Adiantado em parte | A ingestão já grava `seq` e `latest_customer_seq` com a linha travada e invalida o turno que não cobre a mensagem nova (bloco 03). O turno existe (`ai_turns`). A janela e o teto de 4 s do chat entram no bloco 03. Falta a versão do contexto, a janela dos demais canais e a tela |
| 04 em diante | A fazer | Próximo: **04. Agente mock e ação de retorno** |

Decisões tomadas durante o bloco 03: respostas do broker (`401` sem publicar, `422` com o corpo na DLQ, `503` para nova tentativa) e colunas `attempts` e `last_error` no outbox ([07, seções 4 e 5.2](docs/07-arquitetura.md#52-webhook-plataforma--broker-e-evento-em-agentinbound)); tópicos declarados em `infra/kafka/topics.yml` ([docs/10, seção 3.7](docs/10-organizacao-do-repositorio.md#37-infra--infraestrutura-sem-código-de-negócio)); `traceparent` obrigatório no webhook para o broker: sem ele, `422` e DLQ (RF-56, [07, seção 5.2](docs/07-arquitetura.md#52-webhook-plataforma--broker-e-evento-em-agentinbound)); formato da mensagem na DLQ vira esquema `dead_letter` no bloco 09. **Recusado o atalho** de abrir o turno a cada mensagem: o bloco 03 adianta a janela de agrupamento só do chat (bloco 06) e um scheduler mínimo só para abrir o turno (bloco 08), o caminho do [07, seção 3.1](docs/07-arquitetura.md#31-ida-e-volta-com-o-agente-caminho-feliz): a ingestão grava `dispatch_due_at`, o `scheduler` grava a abertura no outbox quando ele vence e o worker monta o turno com todas as mensagens pendentes. A fila na porta da ingestão ficou para depois do E1 (`possiveis-melhorias.md`, item 12). Prazo da IA revisto: 20 s por turno, teto de 60 s por ciclo e escalação imediata em falha definitiva, com os tempos centralizados em `Turns::Policy` e configuráveis por marca no bloco 12 ([ADR-020](docs/08-decisoes-de-arquitetura.md#adr-020--prazo-da-ia-por-turno-com-teto-do-ciclo)).

Decisões tomadas durante o bloco 02: contas dos provedores na tabela `provider_accounts`, com segredo criptografado, e webhook de entrada autenticado antes do parse ([ADR-019](docs/08-decisoes-de-arquitetura.md#adr-019--contas-dos-provedores-e-autenticação-dos-webhooks-de-entrada)); `account_id` do chat identifica o cliente ([07, seção 5.0](docs/07-arquitetura.md#50-webhooks-dos-canais-entrada-e-saída)); auditoria imutável também por trigger ([07, seção 4](docs/07-arquitetura.md#índices-e-restrições-que-carregam-regra-de-negócio)); o simulador do cliente nasce no `channels-mock`, como manda o [docs/10](docs/10-organizacao-do-repositorio.md#34-srcchannels-mock--provedores-e-simulador).

Decisões tomadas durante o bloco 01: organização do repositório ([ADR-017](docs/08-decisoes-de-arquitetura.md#adr-017--monorepo-com-o-código-em-src), [docs/10](docs/10-organizacao-do-repositorio.md)), canais no formato real dos provedores ([ADR-018](docs/08-decisoes-de-arquitetura.md#adr-018--canais-simulados-no-formato-dos-provedores-reais)) e o conteúdo das ações do agente (07, seção 5.3).

## Como desenvolver o backend e o painel juntos

- **Começar pela tela de conversa.** Enquanto a integração é construída, usar exemplos sintéticos que representem mensagem recebida, turno em andamento, resposta aplicada e escalação. Marcar a origem dos dados na tela e ligar cada evento à fonte real assim que ela ficar disponível no ambiente local.
- **Manter um formato de leitura estável.** A tela usa uma representação própria que pode ser alimentada por exemplos sintéticos ou pelos registros do sistema. O adaptador do backend reúne o histórico, a auditoria e as medições, preservando os contratos entre plataforma, broker e agente.
- **Testar cada entrega em dois lugares.** O teste automatizado verifica a regra, com relógio controlado quando houver prazos e corridas. O navegador mostra o resultado e permite abrir a mensagem, o turno ou a execução que o produziu.

### O que o painel precisa conseguir mostrar

- **Conversa.** Mensagens na ordem do `seq`, status da entrega, responsável atual e histórico de escalação. Um turno pode cobrir mais de uma mensagem. Mostrar quais mensagens entraram naquele turno.
- **Linha do tempo.** Associar eventos a atendimento, mensagem e turno por seus identificadores e pelo `trace_id`, quando disponível. Mostrar recebimento, gravação, espera intencional, publicação, execução do agente, aplicação ou descarte e entrega ao canal. Calcular duração com os tempos coletados pelo sistema. A atualização pode começar periódica e evoluir para Hotwire com ActionCable.
- **Métricas.** Mostrar p50 e p95 da latência com intervalo, quantidade de amostras e origem dos dados. Mostrar também a taxa de erros, timeouts e turnos superados, com denominadores explícitos. A tela de conversa detalha a execução e o Grafana dá a visão agregada dos experimentos de carga.
- **Evals.** Cada resultado identifica o cenário, a execução, a versão do agente, o esperado, o observado, o status e, quando houver, o link para a conversa ou o turno que serve de evidência. Se o cenário nunca rodou, mostrar esse estado explicitamente.

## Semana 1 — Um repasse de ponta a ponta

### 01. Ambiente e dados iniciais

- [x] **Backend:** confirmar que o engine do Docker está disponível, criar o scaffold Rails e subir o mínimo de serviços pelo Compose. Criar migrações iniciais e um seed reprodutível com uma marca, fila, cliente sintético e usuário do tipo bot.
- [x] **Frontend:** criar a navegação inicial no Rails e as telas de conversa e linha do tempo com dados sintéticos identificados.
- **Pronto quando:** o ambiente sobe e a conversa de exemplo abre no navegador após carregar o seed. **Referências** RF-22, RF-23, RF-58, RF-61, RNF-29.
- **Situação:** comprovado com Postgres e Redis locais e validado com `make up` no Docker.

### 02. Entrada e gravação de uma mensagem

- [x] **Backend:** implementar o primeiro canal simulado, normalizar o envelope, identificar marca e cliente, criar ou localizar o ticket e gravar mensagem, auditoria e outbox na mesma transação. Confirmar após o commit.
- [x] **Frontend:** adicionar o formulário do simulador. Substituir o evento de recebimento da demonstração pela mensagem gravada e mostrar se ela foi confirmada.
- **Pronto quando:** enviar pelo navegador cria uma mensagem visível no ticket, e reenviar o mesmo ID externo preserva uma única mensagem. **Referências** RF-01, RF-04, RF-05, RF-07, RF-08, RF-10, RF-54, RNF-14.
- **Situação:** comprovado com Postgres local, a plataforma em `:3000` e o `channels-mock` em `:4000`: duas mensagens confirmadas (`202`) no mesmo ticket, com `seq` 1 e 2, e o reenvio respondido como duplicado (`200`). Canal implementado: chat do app. WhatsApp e e-mail ficam no bloco 15. O webhook do chat já exige assinatura (`401` sem ela), e o simulador tem a opção de enviar com assinatura inválida. Validado também com `make up` no Docker, com o `channels-mock`. Fica para outros blocos: assinatura do WhatsApp (`X-Hub-Signature-256` e conferência do `phone_number_id`) e do Gmail (token do Pub/Sub) junto com os adaptadores do bloco 15; reabertura em 72 h (RN-08, RF-11) e pedido explícito de humano na ingestão (RN-34, bloco 10).

### 03. Publicação no broker e Kafka

- [x] **Backend:** ~~definir os esquemas JSON dos eventos~~ (feito no bloco 01, `src/contracts/v1`), publicar o outbox com assinatura HMAC, validar no broker e confirmar a publicação no Kafka. Propagar o rastreio e usar a conversa como chave da partição.
- [x] **Frontend:** acrescentar a etapa de publicação e mostrar a origem de um erro ao escolher o evento na linha do tempo.
- [x] **Backend (adiantado dos blocos 06 e 08):** a ingestão grava `first_pending_at` e `dispatch_due_at` com a janela do chat (1,5 s, teto de 4 s, RN-55); um `scheduler` mínimo encontra os `dispatch_due_at` vencidos e grava a abertura do turno no outbox com chave única (ADR-016); o worker trava o atendimento, revalida o prazo e monta o turno com todas as mensagens pendentes. Remove a abertura direta pelo `message.received`.
- **Pronto quando:** a mensagem do simulador gera um evento válido no tópico de entrada, visível pela sua correlação. Um webhook mal assinado é rejeitado. **Referências** RF-29, RF-30, RF-33, RF-56, RNF-23, RNF-28.
- **Situação:** comprovado em 19/11/2026 com `docker compose up` completo (Docker Desktop no Windows): `kafka`, `kafka-init`, `broker`, `worker`, `scheduler`, `web` e `channels-mock`. Mensagens do simulador viraram eventos em `helpdesk.agent.inbound.v1` (mesma partição por conversa, offsets 0 e 1), com o mesmo `trace_id` da mensagem; mensagem nova marcou o turno anterior como superado e abriu outro com todas as pendentes; envio com assinatura inválida recebeu `401` sem gravar nada. Tempos medidos (ambiente de desenvolvimento): scheduler abaixo de 250 ms do fim da janela, abertura do turno ~430 ms e publicação ~300 ms depois, ingestão com o atendimento travado por 20 a 60 ms. Ajustes feitos na validação: `.ruby-version` copiado nas imagens do broker e do `channels-mock`; `start_period` no healthcheck do `web`; log do Rails na saída do contêiner e worker e scheduler sem recarga automática (a pasta montada do Windows somava 1,5 a 3 s por passo); healthcheck do `worker` e do `scheduler` por arquivo de sinal de vida; tela da conversa lendo `ai_turns`; fim da janela nunca antes da gravação. Fica para depois: DLQ da plataforma, tabela `dead_letters` e escalação pela RN-45 (bloco 09); handoff no vencimento do prazo e na falha definitiva da publicação ([ADR-020](docs/08-decisoes-de-arquitetura.md#adr-020--prazo-da-ia-por-turno-com-teto-do-ciclo), blocos 08 e 10), que também deve limpar `dispatch_due_at` dos ciclos descartados; aviso de progresso (bloco 08); janela dos demais canais (bloco 06); atribuição ao bot pela triagem (bloco 11). Até o bloco 11, todo caso que não está com um humano vai para a IA.

### 04. Agente mock e ação de retorno

- [ ] **Backend:** consumir o evento, consultar um repasse sintético e devolver uma ação com identificação do turno, versão, configuração, resultado e tempo da consulta. Implementar o consumer de retorno e validar a correlação com o pedido.
- [ ] **Frontend:** mostrar a consulta e a ação recebida, com a duração da execução do mock.
- **Pronto quando:** é possível abrir o turno e conferir as mensagens enviadas e a ação resultante. **Referências** RF-31, RF-32, RF-33, RF-38.

### 05. Entrega ao canal e primeira demonstração

- [ ] **Backend:** gravar a entrega no outbox, enviar ao canal de origem com `delivery_id` estável e guardar a confirmação.
- [ ] **Frontend:** distinguir ação recebida, resposta aplicada e resposta entregue. Mostrar o tempo total no simulador.
- **Pronto quando:** escrever “meu repasse não caiu” no navegador produz uma resposta visível pelo canal simulado e rastreável até a mensagem original. **Referências** RF-06, RF-31, RF-35, RF-56, RNF-05.

## Semana 2 — Turnos, falhas e handoff

### 06. Agrupamento de mensagens e contexto do turno

- [ ] **Backend:** gravar ~~sequência~~ (feito no bloco 02: `seq` e `latest_customer_seq`) e versão do contexto no atendimento. A tabela `ai_turns` e a invalidação do turno na ingestão já existem (bloco 03). Implementar a janela de agrupamento e o teto de espera dos demais canais (~~chat e montagem do turno com todas as mensagens pendentes~~ adiantados no bloco 03).
- [ ] **Frontend:** mostrar a fase de agrupamento e quais mensagens entraram em cada turno. Adicionar um cenário no simulador que envia a segunda mensagem aos 3 s.
- **Pronto quando:** uma rajada agrupa as mensagens conforme a política do canal, e o turno persistido corresponde ao contexto enviado. **Referências** RF-09, RF-29, RF-33, RN-49, RN-55.

### 07. Validade da resposta e idempotência

- [ ] **Backend:** validar turno, `in_reply_to`, atribuição, prazo e contexto sob o lock do atendimento. Preservar o resultado quando a mesma ação é repetida ou chega uma segunda ação para o mesmo turno.
- [ ] **Frontend:** mostrar turno superado e motivo da rejeição na linha do tempo, com links entre as mensagens e os turnos. Exibir o primeiro eval do cenário dos 3 s, com resultado esperado, observado e link para o turno.
- **Pronto quando:** a resposta antiga que chega aos 3,5 s é rejeitada após o commit da mensagem 2, mesmo com o turno seguinte atrasado. Testar também a ordem de commit inversa e a resposta válida antes do ACK do broker. **Referências** RF-31, RF-35, RF-54, RN-56.

### 08. Scheduler, aviso e prazo do atendimento

- [ ] **Backend:** implementar o scheduler apoiado no Postgres e no outbox (~~scheduler mínimo e abertura de turno~~ adiantados no bloco 03). Registrar o aviso de progresso e o fallback com chaves que permitam reexecução segura. Verificar o prazo do ticket mesmo sem publicação confirmada.
- [ ] **Frontend:** mostrar o prazo do atendimento, o aviso de progresso e o motivo do timeout. Incluir perfis rápido, lento e sem resposta no simulador.
- **Pronto quando:** uma resposta recebida a partir de `T` é rejeitada mesmo antes do job de timeout, e uma queda do broker antes do primeiro envio encaminha o caso para a fila humana. **Referências** RF-36, RN-46, RN-57, RNF-18, ADR-016.

### 09. Retentativas, DLQ e recuperação

- [ ] **Backend:** implementar retentativas com backoff, DLQ e retomada dos itens ainda abertos. Criar o esquema `dead_letter` em `src/contracts/v1` para a mensagem da DLQ (decisão do bloco 03). Encerrar eventos superados ou expirados conforme a política de recuperação. Injetar queda após o commit da ação do scheduler e perda da confirmação do provedor.
- [ ] **Frontend:** mostrar tentativas e desfecho do evento na linha do tempo. Exibir o motivo da falha em cada etapa e a condição de entrega em conciliação.
- **Pronto quando:** mensagens confirmadas continuam no histórico após a falha, eventos antigos não reativam a IA e a confirmação perdida não gera uma segunda resposta visível. **Referências** RF-34, RF-35, RNF-14 a RNF-17.

### 10. Handoff e primeira fila humana

- [ ] **Backend:** ligar os gatilhos de escalação a uma fila humana do seed, gravar motivo e histórico, completar o resumo quando disponível e tratar saídas pendentes ou em conciliação.
- [ ] **Frontend:** mostrar o caso na fila humana com motivo, histórico e estado do resumo. Permitir acompanhar o aviso de transferência no simulador.
- **Pronto quando:** pedir humano durante uma consulta invalida o turno, o caso aparece na fila e a sequência de mensagens respeita a política de entrega do [07](docs/07-arquitetura.md#32-escalação-e-handoff). **Referências** RF-39 a RF-43, RNF-06.

## Semana 3 — Operação, canais e equipes

### 11. Triagem e roteamento configurável

- [ ] **Backend:** implementar triagem, prioridade, avaliação ordenada de regras E/OU e fila padrão. Registrar a regra e a versão aplicadas e respeitar filas de atendimento exclusivamente humano.
- [ ] **Frontend:** exibir categoria, prioridade e explicação do roteamento no detalhe do atendimento.
- **Pronto quando:** ao variar os dados sintéticos do ticket, o caso segue a primeira regra aplicável ou cai na fila padrão e a decisão aparece na auditoria. **Referências** RF-12, RF-14, RF-15, RF-18, RF-24, RF-54.

### 12. Configuração pelo supervisor

- [ ] **Backend:** completar cadastro de marcas, equipes, atendentes, filas e regras. Validar alterações concorrentes, proteger referências a filas e aplicar novas versões em tempo de execução. Configuração versionada dos tempos da IA por marca (janela por canal, prazo do turno, teto do ciclo e aviso), lida por `Turns::Policy.for(brand)`, com os limites do [ADR-020](docs/08-decisoes-de-arquitetura.md#adr-020--prazo-da-ia-por-turno-com-teto-do-ciclo).
- [ ] **Frontend:** implementar formulários de configuração com validação e mensagens de erro visíveis. Mostrar a versão da regra em uso. Incluir os tempos da IA da marca.
- **Pronto quando:** o supervisor cria ou altera uma regra pelo navegador e o próximo atendimento segue a nova configuração, com a decisão rastreável. **Referências** RF-13 a RF-18, RF-22, RF-58, RNF-07.

### 13. Distribuição humana e SLA

- [ ] **Backend:** atribuir automaticamente a analistas elegíveis sem exceder capacidade. Implementar ordenação da fila, preservação de SLA e devolução à fila quando o analista fica offline pelo prazo da RN-31.
- [ ] **Frontend:** mostrar responsável, tempo de espera, prioridade, SLA e capacidade na fila. Dar destaque aos casos que exigem atenção.
- **Pronto quando:** dois workers disputam a última vaga e só um consegue ocupá-la, e um analista offline devolve o caso à fila preservando o SLA. **Referências** RF-19, RF-25, RF-27, RF-45, RF-60.

### 14. Atendimento pelo analista e autorização

- [ ] **Backend:** proteger a leitura e a escrita por marca, equipe e perfil. Implementar resposta humana, resolução com motivo e consulta ao histórico. Aplicar o mesmo escopo às atualizações em tempo real.
- [ ] **Frontend:** completar a tela de atendimento humano, com fila, resumo, histórico e controles para responder e resolver. Conectar as atualizações por Hotwire e ActionCable.
- **Pronto quando:** o analista recebe o caso, responde e resolve no navegador. Uma conta de outra marca não consegue abrir o detalhe nem receber seus eventos. **Referências** RF-45 a RF-48, RF-55, RF-59, RNF-24.

### 15. Demais canais simulados e histórico unificado

- [ ] **Backend:** implementar os adaptadores restantes de chat, WhatsApp e e-mail, conforme o canal usado no primeiro fluxo. Normalizar entradas, preservar a identidade dentro da marca e entregar pelo canal de origem. Manter políticas de turno e contexto por canal.
- [ ] **Frontend:** permitir escolher o canal no simulador e mostrar os atendimentos anteriores do mesmo cliente no painel do analista.
- **Pronto quando:** o mesmo cliente sintético conversa por WhatsApp e e-mail, aparece no histórico unificado e recebe cada resposta no canal de origem. **Referências** RF-01 a RF-07, RF-47, RF-51, RN-49, RN-55.

## Semana 4 — Evals, experimentos e entrega

### 16. Casos de avaliação e aba de evals

- [ ] **Backend:** transformar contextos e respostas simuladas de ferramentas em casos com gabarito. Cobrir triagem, roteamento, repasse, contexto do turno e handoff. Registrar execução, agente, esperado, observado e referência ao trace.
- [ ] **Frontend:** mostrar os resultados em uma aba de evals, com filtros por cenário e resultado e um caminho do erro até o turno correspondente.
- **Pronto quando:** rodar um cenário correto e outro com falha intencional gera resultados diferentes, e o painel aponta o evento que explica a falha. **Referências** RNF-27, RNF-30 e [09 — Avaliação](docs/09-evolucao-da-integracao-com-ia.md#4-como-avaliar-uma-nova-versão-do-agente).

### 17. Resiliência, handoff e isolamento

- [ ] **Backend:** rodar E2, E4 e E6. Cobrir Redis perdido, broker indisponível, timeout, falha de entrega, disputa de vaga e acesso indevido entre marcas. Corrigir os desvios que impedem os critérios de aceite.
- [ ] **Frontend:** conferir como a fila, a conversa e a auditoria ficam durante as falhas e depois da recuperação. Validar tanto o painel quanto as inscrições de atualização.
- **Pronto quando:** as execuções registram quais critérios passaram e quais ficaram pendentes, com evidência por cenário. **Referências** E2, E4, E6.

### 18. Configuração e uso pela operação

- [ ] **Backend:** rodar o E3 com alterações de regras enquanto chegam atendimentos. Verificar versão aplicada, atualização em tempo de execução e proteção de filas em uso.
- [ ] **Frontend:** validar o roteiro do supervisor e a fila do analista. Completar os indicadores de volume, espera, SLA e escalação com os dados já coletados.
- **Pronto quando:** o avaliador consegue configurar a operação e conferir por que um atendimento foi roteado para uma fila específica. **Referências** E3, RF-13 a RF-18, RF-60, RNF-31.

### 19. Carga e leitura de desempenho

- [ ] **Backend:** rodar E1 e E5 com semente, configuração e taxas registradas. Rodar num perfil próprio, com `RAILS_ENV=production`, código carregado na imagem e sem a pasta `src/platform` montada: no Docker Desktop do Windows, a pasta montada acrescentou ~1,5 s por passo (worker e transação da ingestão) no teste do bloco 03, e os números não representariam a plataforma. Medir latência por etapa, fila, throughput, perdas e proporção de turnos superados. Comparar conversas independentes com rajadas na mesma conversa.
- [ ] **Frontend:** ligar percentis e contagens aos dados da execução. Mostrar a janela medida e permitir comparar um caso individual com a visão agregada no Grafana.
- **Pronto quando:** é possível explicar de onde vem a latência e qual componente acumula fila primeiro, com os números reproduzíveis e as limitações registradas. **Referências** E1, E5, RNF-03, RNF-09 a RNF-13, RNF-22.

### 20. Entrega reproduzível e roteiro da demo

- [ ] **Backend:** validar o Compose em ambiente limpo, conferir seed, migrations e comandos de teste, registrar limitações e revisar a cobertura dos requisitos obrigatórios.
- [ ] **Frontend:** ensaiar a demo completa. Abrir o simulador, reproduzir a corrida dos 3 s, pedir humano, responder pela fila e abrir o resultado do eval correspondente.
- **Pronto quando:** outra pessoa consegue subir o projeto pelo README e repetir o roteiro usando o navegador, com dados sintéticos e resultados identificáveis. **Referências** RNF-27, RNF-29, RNF-30.

## Ordem de corte se o prazo apertar

Preservar o fluxo de mensagem, os contratos, as regras de turno, o handoff, o isolamento entre marcas e o roteiro que demonstra tudo isso. Conferir os requisitos marcados como **M** no [04](docs/04-requisitos-funcionais.md) antes de aumentar a superfície do painel. Simplificar a apresentação primeiro, mantendo uma lista de conversas, a linha do tempo e a aba de evals com evidência. As metas de latência e escala devem ser apresentadas com os números que os experimentos produzirem.

API de leitura extra, RAG, MCP, LLM como juiz e modo sombra seguem os gatilhos descritos no [09 — Evolução da integração com a IA](docs/09-evolucao-da-integracao-com-ia.md#5-ordem-proposta-de-evolução).
