# 04 — Requisitos funcionais (RF)

A plataforma tem 61 requisitos funcionais em 11 módulos: 44 obrigatórios (**M**), 13 importantes (**S**) e 4 desejáveis (**C**). Os obrigatórios cobrem todos os entregáveis do TAPI. Os demais entram conforme o prazo de 1 mês permitir.

Prioridade em MoSCoW (ver [README](../README.md)). A relação entre regras de negócio e RF está no [06 — RN](06-regras-de-negocio.md).

## Visão por módulo

| Módulo | IDs | M | S | C |
| --- | --- | --- | --- | --- |
| 1. Canais | RF-01 a RF-07 | 7 | 0 | 0 |
| 2. Atendimentos | RF-08 a RF-11 | 3 | 1 | 0 |
| 3. Triagem, filas e roteamento | RF-12 a RF-21 | 7 | 1 | 2 |
| 4. Atendentes e distribuição | RF-22 a RF-28 | 4 | 3 | 0 |
| 5. Integração com o agente de IA | RF-29 a RF-38 | 9 | 1 | 0 |
| 6. Handoff | RF-39 a RF-44 | 4 | 1 | 1 |
| 7. Painel do analista | RF-45 a RF-50 | 4 | 2 | 0 |
| 8. Memória e contexto | RF-51 a RF-53 | 1 | 2 | 0 |
| 9. Auditoria e rastreabilidade | RF-54 a RF-57 | 3 | 0 | 1 |
| 10. Administração e multi-marca | RF-58 a RF-60 | 1 | 2 | 0 |
| 11. Dados sintéticos | RF-61 | 1 | 0 | 0 |
| **Total** | | **44** | **13** | **4** |

---

## 1. Canais

Todo canal é **simulado**, mas entra na plataforma pelo mesmo caminho que um canal real entraria: um endpoint de entrada que recebe o payload no formato do canal.

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-01 | O sistema deve receber mensagens do **chat no app** por um endpoint de entrada. | M | Cliente |
| RF-02 | O sistema deve receber mensagens de **WhatsApp** por um endpoint que imita o webhook de um provedor (formato próprio documentado). | M | Cliente |
| RF-03 | O sistema deve receber **e-mails** simulados (remetente, assunto, corpo, anexos como metadados). | M | Cliente |
| RF-04 | O sistema deve oferecer um **simulador de cliente** (interface web ou script) para enviar e receber mensagens em cada um dos três canais. | M | Cliente |
| RF-05 | O sistema deve **normalizar** as mensagens de qualquer canal para um formato interno único (canal, remetente, conteúdo, horário, ID externo). | M | Sistema |
| RF-06 | O sistema deve **responder ao cliente pelo mesmo canal** de origem do atendimento. | M | Sistema |
| RF-07 | O sistema deve **identificar o cliente e a marca** a partir do identificador do canal (telefone, e-mail, conta do app), associando-os a um `customer_id` único. | M | Sistema |

## 2. Atendimentos

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-08 | O sistema deve **criar um atendimento** quando chegar uma mensagem de um cliente sem atendimento aberto, e **anexar a mensagem** ao atendimento aberto quando existir. | M | Sistema |
| RF-09 | O sistema deve controlar o **ciclo de vida** do atendimento pelos estados: `novo`, `em_triagem`, `com_ia`, `aguardando_humano`, `com_analista`, `aguardando_cliente`, `resolvido`, `fechado`. | M | Sistema |
| RF-10 | O sistema deve registrar em cada atendimento: marca, canal, categoria, prioridade, fila, atendente responsável e tags. | M | Sistema |
| RF-11 | O sistema deve **reabrir** um atendimento resolvido quando o cliente responder dentro de um prazo configurável. | S | Sistema |

## 3. Triagem, filas e roteamento

As filas e regras são **dados**, não código. Toda alteração vale para os novos atendimentos sem reinício nem deploy.

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-12 | O sistema deve fazer a **triagem automática** do atendimento, definindo categoria e prioridade (por regras de palavras-chave ou pela classificação do agente). No bloco 11 só as palavras-chave (pt-BR e inglês, com e sem contração); a classificação do agente ainda não refina a triagem. | M | Sistema |
| RF-13 | O supervisor deve poder **criar, editar, desativar e excluir filas**, definindo nome, marca, equipe, prioridade, SLA e se a IA atende primeiro. | M | Supervisor |
| RF-14 | O supervisor deve poder **criar, editar e excluir regras de roteamento** com condições combináveis (E/OU) sobre marca, canal, categoria, prioridade e tags. | M | Supervisor |
| RF-15 | O sistema deve avaliar as regras **em ordem definida pelo supervisor** e usar uma **fila padrão** quando nenhuma regra casar. | M | Sistema |
| RF-16 | Alterações em filas e regras devem **valer em tempo de execução**, sem reinício nem deploy. | M | Sistema |
| RF-17 | O sistema deve **validar a configuração**: impedir excluir fila com atendimentos abertos, regra apontando para fila inexistente ou ausência de fila padrão. | M | Sistema |
| RF-18 | O sistema deve **versionar** filas e regras, guardando quem alterou, quando e o que mudou. | M | Sistema |
| RF-19 | O sistema deve **ordenar os atendimentos dentro da fila** por prioridade e, em empate, pelo tempo restante de SLA. | S | Sistema |
| RF-20 | O supervisor deve poder **simular uma regra** antes de salvar, informando um atendimento de exemplo e vendo a fila resultante. | C | Supervisor |
| RF-21 | O supervisor deve poder **reprocessar** atendimentos já enfileirados após uma mudança de regra. | C | Supervisor |

## 4. Atendentes e distribuição

O agente de IA é um **atendente como os humanos**: tem cadastro, filas e atendimentos atribuídos a ele.

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-22 | O supervisor deve poder **cadastrar atendentes** (humanos e IA), associando-os a equipes, marcas e filas. | M | Supervisor |
| RF-23 | O sistema deve tratar o agente de IA como um **usuário do tipo bot**, que recebe atendimentos e envia mensagens pelos mesmos fluxos de um humano. | M | Agente de IA |
| RF-24 | O sistema deve **atribuir ao agente de IA** os atendimentos de filas configuradas com "IA atende primeiro". | M | Sistema |
| RF-25 | O sistema deve **atribuir automaticamente** atendimentos aos analistas disponíveis (rodízio ou menor carga), respeitando a capacidade máxima de cada um. | M | Sistema |
| RF-26 | O analista deve poder **assumir manualmente** o próximo atendimento da sua fila. | S | Analista |
| RF-27 | O analista deve poder definir sua **disponibilidade** (online, pausa, offline), que é respeitada pela distribuição. | S | Analista |
| RF-28 | Analistas e supervisores devem poder **transferir** um atendimento para outra fila ou outro analista, registrando o motivo. | S | Analista |

## 5. Integração com o agente de IA

Fluxo: plataforma → **webhook** → **broker** → tópico de entrada → agente → tópico de saída → plataforma. A entrega é "pelo menos uma vez", então todo consumidor precisa ser idempotente.

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-29 | A plataforma deve **disparar webhooks** para eventos relevantes: mensagem do cliente recebida, atendimento atribuído à IA, atendimento devolvido à IA. | M | Sistema |
| RF-30 | O **broker** deve receber o webhook, validar sua assinatura (HMAC) e publicar o evento no tópico de entrada, usando o ID da conversa como chave para preservar a ordem. | M | Sistema |
| RF-31 | A plataforma deve **consumir as respostas** do agente no tópico de saída e aplicá-las ao atendimento. | M | Sistema |
| RF-32 | O agente deve poder executar as **ações**: responder ao cliente, executar uma consulta simulada (status de transação, repasse, taxa), escalar para humano e encerrar o atendimento. | M | Agente de IA |
| RF-33 | Cada evento enviado ao agente deve conter o **contexto** do atendimento: mensagens recentes, resumo, dados do cliente, marca, categoria e prioridade. | M | Sistema |
| RF-34 | O sistema deve fazer **retentativas com backoff exponencial** em falhas de entrega e enviar à **fila de mensagens mortas (DLQ)** o que falhar após N tentativas. | M | Sistema |
| RF-35 | Todos os consumidores devem **descartar eventos duplicados** pelo `event_id` (idempotência). | M | Sistema |
| RF-36 | Se o agente não responder dentro de um **tempo limite** configurável, o sistema deve aplicar um fallback (nova tentativa ou escalação para humano). | M | Sistema |
| RF-37 | O supervisor deve poder **visualizar e reprocessar** eventos da DLQ. | S | Supervisor |
| RF-38 | O **agente mock** deve ser configurável (latência, taxa de falha, regras de resposta e de escalação) e registrar modelo, versão e configuração em cada resposta. | M | Agente de IA |

## 6. Handoff

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-39 | O sistema deve **escalar para humano** quando: o agente decidir, o cliente pedir explicitamente, uma regra exigir (categoria ou prioridade) ou o tempo limite do agente estourar. | M | Sistema |
| RF-40 | No handoff, o sistema deve **gerar e anexar um resumo** do caso: problema relatado, ações já tomadas pela IA e motivo da escalação. | M | Sistema |
| RF-41 | O handoff deve **preservar o histórico completo** da conversa e das ações da IA, visível ao analista. | M | Sistema |
| RF-42 | O atendimento escalado deve ir para a **fila de escalas da equipe correta**, conforme as regras de roteamento. | M | Sistema |
| RF-43 | O sistema deve **avisar o cliente** de que ele será atendido por um humano. | S | Sistema |
| RF-44 | O analista deve poder **devolver o atendimento à IA** quando o ponto que exigia humano estiver resolvido. | C | Analista |

## 7. Painel do analista

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-45 | O analista deve ver sua **fila de escalas** ordenada por prioridade e SLA, com tempo de espera de cada atendimento. | M | Analista |
| RF-46 | O analista deve poder **conversar com o cliente** em tempo real, pelo canal de origem. | M | Analista |
| RF-47 | O analista deve ver o **contexto** do atendimento: dados do cliente, resumo do handoff, histórico deste atendimento e dos anteriores. | M | Analista |
| RF-48 | O analista deve poder **resolver** o atendimento informando um motivo ou categoria de resolução. | M | Analista |
| RF-49 | O analista deve poder registrar **notas internas**, invisíveis ao cliente. | S | Analista |
| RF-50 | Analistas e supervisores devem poder **buscar e filtrar** atendimentos (cliente, marca, fila, estado, período). | S | Analista |

## 8. Memória e contexto

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-51 | O sistema deve manter o **histórico unificado do cliente** entre canais e atendimentos, a partir do `customer_id`. | M | Sistema |
| RF-52 | O sistema deve **persistir um resumo** de cada atendimento ao resolvê-lo, para uso em interações futuras. | S | Sistema |
| RF-53 | Ao abrir um novo atendimento, o sistema deve **incluir no contexto** do atendente os resumos dos atendimentos recentes do mesmo cliente. | S | Sistema |

## 9. Auditoria e rastreabilidade

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-54 | O sistema deve registrar um **evento de auditoria imutável** para: cada mensagem, decisão de triagem, decisão de roteamento (com a versão da regra aplicada), atribuição, escalação, mudança de estado e alteração de configuração. | M | Sistema |
| RF-55 | O supervisor deve poder consultar a **linha do tempo de auditoria** de um atendimento. | M | Supervisor |
| RF-56 | Cada mensagem deve carregar um **trace ID** propagado pela plataforma, broker e agente, para correlacionar logs ponta a ponta. | M | Sistema |
| RF-57 | O supervisor deve poder **exportar** a trilha de auditoria (CSV ou JSON). | C | Supervisor |

## 10. Administração e multi-marca

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-58 | O supervisor deve poder **cadastrar marcas e equipes**. Atendimentos, clientes, filas e regras pertencem sempre a uma marca. | M | Supervisor |
| RF-59 | O sistema deve ter **perfis de acesso** (supervisor, analista) e restringir o que cada usuário vê às marcas e equipes dele. | S | Sistema |
| RF-60 | O sistema deve exibir um **painel operacional** com volume por fila, tempo de espera, taxa de escalação e atendimentos fora do SLA. | S | Supervisor |

## 11. Dados sintéticos

| ID | Requisito | Prior. | Ator |
| --- | --- | --- | --- |
| RF-61 | O projeto deve incluir um **gerador de dados sintéticos** (marcas, clientes, atendimentos, filas e regras), reprodutível por semente, sem nenhum dado real. | M | Sistema |

---

## Critérios de aceite dos RF críticos

São os requisitos que a avaliação do TAPI pesa diretamente. Cada critério vira um teste automatizado ou um passo da demonstração.

| RF | Critério de aceite |
| --- | --- |
| RF-13 a RF-16 | O supervisor cria uma fila e uma regra pela interface; o próximo atendimento que casa com a regra cai na nova fila, **sem reinício** de nenhum serviço. |
| RF-18 + RF-54 | A auditoria de um atendimento mostra qual regra, e em qual versão, o colocou na fila. |
| RF-29 a RF-31 | Uma mensagem enviada pelo simulador percorre webhook → broker → tópico → agente → tópico → plataforma, e a resposta aparece ao cliente com o mesmo trace ID em todos os logs. |
| RF-34 + RF-35 | Durante uma queda do agente ou broker, toda mensagem confirmada permanece no histórico e na auditoria. Na recuperação, eventos válidos podem seguir para a IA. Eventos de turnos expirados ou de atendimentos já escalados são encerrados sem nova ação. Reentregar o mesmo webhook não duplica a mensagem nem seus efeitos. |
| RF-36 | Com o mock mudo ou o broker indisponível antes da publicação do primeiro turno, o atendimento entra na fila humana até `T + 2 s` desde a primeira mensagem pendente. Com o job de timeout atrasado, uma resposta recebida a partir de `T` já não pode ser aplicada. |
| RF-39 a RF-42 | O pedido "quero falar com um atendente" encaminha o caso à fila da equipe certa, com histórico acessível desde a entrada. O resumo chega separadamente conforme a RNF-06. Repetir o pedido na fila humana não duplica o handoff. Um pedido de humano gravado durante a geração expira o turno em andamento, e a resposta atrasada é rejeitada (`handoff_pedido`). Uma resposta aplicada antes do pedido não impede a escalação, e sua entrega ainda não iniciada é cancelada (RN-38). |
| RF-51 | Um cliente que fala por WhatsApp e depois por e-mail é reconhecido como o mesmo, e o analista vê os dois atendimentos. |
| RF-31 + RF-33 (turnos, RN-56) | Com a mensagem 2 gravada aos 3 s, a resposta do turno 1 chegando aos 3,5 s e o worker do turno 2 atrasado, a resposta antiga é rejeitada e o envio seguinte contém as duas mensagens. Se a mensagem 2 for gravada depois do commit da primeira resposta, ela abre uma continuação. Uma resposta válida antes do ACK do broker pode ser aplicada. A segunda ação final do mesmo turno não altera o resultado gravado. |
| RF-06 + RF-39 + RF-43 (entrega no handoff) | Em um pedido de humano, a resposta pendente do bot é cancelada antes do envio. Se a chamada ao canal já começou, seu resultado é conciliado antes de enviar o aviso de transferência. O aviso precede as mensagens seguintes do analista. A perda do ACK do canal não gera uma segunda entrega visível. |

## Rastreabilidade com os entregáveis do TAPI

| Entregável do TAPI | RF |
| --- | --- |
| Recebimento multi-canal (simulado) | RF-01 a RF-07 |
| Filas múltiplas, configuráveis e editáveis | RF-12 a RF-21 |
| Interface de conversa cliente ↔ atendente | RF-04, RF-46 |
| Painel do analista com escalas, contexto e histórico | RF-45 a RF-50 |
| Integração via webhooks e broker | RF-29 a RF-38 |
| Triagem, priorização e distribuição IA / humano | RF-12, RF-19, RF-22 a RF-28 |
| Handoff com resumo e contexto | RF-39 a RF-44 |
| Rastreabilidade e auditoria | RF-54 a RF-57 |
| Memória e contexto entre interações | RF-33, RF-51 a RF-53 |
| Dados sintéticos | RF-61 |
