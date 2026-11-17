# 03 — Atores e glossário

## Atores

A plataforma tem três usuários definidos no TAPI e um quarto implícito: o supervisor, que configura as filas.

| Ator | Quem é | O que faz na plataforma |
| --- | --- | --- |
| Cliente final (lojista) | Microempreendedor de uma das marcas (InfinitePay, JIM) | Abre a solicitação por chat, WhatsApp ou e-mail; envia e recebe mensagens |
| Agente de IA (mock) | Atendente automático, usuário da plataforma | Recebe o atendimento, responde, executa uma ação simulada ou escala para humano |
| Analista humano | Atendente de suporte de uma equipe | Recebe as escalas, lê o resumo e o histórico, conclui o caso |
| Supervisor / operação | Gestor da operação de suporte | Cria e edita filas, regras de roteamento, prioridades e equipes; consulta a auditoria |

## Glossário

| Termo | Significado |
| --- | --- |
| Atendimento (ticket) | Uma solicitação de um cliente, com mensagens, estado, fila e responsável |
| Canal | Origem da solicitação: chat no app, WhatsApp ou e-mail |
| Marca (tenant) | Negócio da CloudWalk ao qual o cliente pertence (InfinitePay, JIM) |
| Equipe | Grupo de analistas responsável por um conjunto de filas |
| Fila | Agrupamento de atendimentos definido por regras (marca, equipe, categoria, prioridade) |
| Regra de roteamento | Condição configurável que decide para qual fila vai um atendimento |
| Triagem | Classificação inicial de categoria e prioridade do atendimento |
| Atendente | Quem responde o atendimento: o agente de IA ou um analista |
| Escalação / escala | Decisão de passar o atendimento da IA para um humano |
| Handoff | Transferência efetiva do atendimento, com resumo, contexto e histórico |
| Webhook | Chamada HTTP que a plataforma dispara quando ocorre um evento (por exemplo, nova mensagem) |
| Broker | Serviço que recebe os webhooks e os publica no tópico de mensageria |
| Tópico | Canal do Kafka (ou similar) por onde as mensagens chegam ao agente e as respostas voltam |
| Idempotência | Processar a mesma mensagem duas vezes sem efeito duplicado |
| Trilha de auditoria | Registro imutável de cada evento e decisão, com autor e horário |
| SLA | Prazo-alvo de primeira resposta ou de resolução |
