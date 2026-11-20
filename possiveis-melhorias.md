# Possíveis melhorias

Ideias que surgiram durante o desenvolvimento e **não entram no MVP agora**. Cada uma diz o problema, a ideia, quando passa a valer a pena e de onde veio. Quando uma delas for adotada, vira ADR no [08](docs/08-decisoes-de-arquitetura.md) ou entra no [roadmap](ROADMAP.md), e sai daqui.

As evoluções maiores da integração com a IA (MCP, RAG, LLM como juiz, modo sombra) já estão no [09](docs/09-evolucao-da-integracao-com-ia.md) e não se repetem aqui.

## Resumo

| # | Melhoria | Área | Quando vale | Esforço |
| --- | --- | --- | --- | --- |
| 1 | Avisar o agente que o turno foi superado | Agente / contrato | Com o agente real (LLM pago por token) | Médio |
| 2 | Processar mensagens do WhatsApp que não são texto | Canais | Quando o agente souber tratar imagem, áudio e documento | Médio |
| 3 | Resposta fora da janela de 24 h do WhatsApp | Canais | Antes de usar o WhatsApp real | Médio |
| 4 | Catálogo fechado de ferramentas em `tool_calls` | Contrato | Quando o catálogo de consultas estiver definido | Baixo |
| 5 | Métrica de turnos descartados e custo desperdiçado | Observabilidade | Junto do bloco 19 (carga) | Baixo |
| 6 | Teste de mutação automatizado | Qualidade | Se o repositório virar público, ou com licença | Baixo |
| 7 | Particionar `messages` e `audit_events` por mês | Banco | Se o E1 mostrar degradação com volume | Alto |
| 8 | Provedores reais em sandbox (Meta e Gmail) | Canais | Depois do MVP, com contas de teste | Alto |
| 9 | Deploy em servidor com Kamal | Infra | Depois do MVP | Médio |
| 10 | Ilha React no editor de regras | Front | Se o teste do RNF-31 falhar | Médio |
| 11 | Fila na porta da ingestão (webhook cru em tópico) | Ingestão / infra | Se o E1 mostrar o ack acima de 500 ms (p99) na carga de referência | Alto |

## 1. Avisar o agente que o turno foi superado

**Problema.** Na corrida dos 3 s, a mensagem nova do cliente invalida o turno 1 na plataforma, mas o agente continua processando esse turno até o fim. A resposta é descartada (RN-56). Com o mock, isso não custa nada. Com um LLM real, cada turno descartado é custo de API e capacidade do agente gasta à toa (07, seção 7: a vazão é medida em turnos).

**Ideia.** Um evento novo no contrato, por exemplo `turn.superseded`, publicado no mesmo tópico `agent.inbound` (mesma partição, por `conversation_id`), com `turn`, `event_id` do turno superado e `superseded_by_seq`. O agente que suportar cancela o processamento; o que não suportar ignora o evento (campo novo, compatível pela 07, seção 5.4).

**Quando vale.** Só com o agente real. A segurança não depende disso: a plataforma continua descartando a resposta velha de qualquer jeito.

**Pergunta para a CloudWalk.** O agente real consegue cancelar um processamento no meio? Registrar na seção 9 do 07.

**Origem.** Discussão sobre a janela de 1,5 s e a corrida dos 3 s (RN-55, RN-56, 07 seção 3.4).

## 2. Processar mensagens do WhatsApp que não são texto

**Problema.** Imagem, áudio, documento e reação passam no contrato (para não derrubar o lote), mas o adaptador só registra e não processa (07, seção 5.0). Um lojista que manda a foto do comprovante não é atendido nessa mensagem.

**Ideia.** Tratar mídia como anexo, com o mesmo formato de `content.attachments` do e-mail (só metadados), e passar para o agente. Ou responder ao cliente que o canal só aceita texto por enquanto.

**Quando vale.** Quando o agente souber usar anexos. Decisão pendente na seção 9 do 07.

## 3. Resposta fora da janela de 24 h do WhatsApp

**Problema.** A Cloud API só aceita texto livre até 24 h depois da última mensagem do cliente. Depois disso, só template aprovado. Um analista que responde um caso antigo teria a mensagem recusada.

**Ideia.** O adaptador de saída confere a janela antes de enviar. Fora dela: usar um template aprovado ("Temos uma atualização sobre seu atendimento, responda para continuar"), trocar para outro canal do mesmo cliente (RN-04) ou deixar a resposta pendente até o cliente escrever.

**Quando vale.** Antes de qualquer uso com o WhatsApp real. No mock, dá para simular a recusa para testar.

## 4. Catálogo fechado de ferramentas em `tool_calls`

**Problema.** Hoje `tool_calls[].tool` aceita qualquer nome. Não é um risco de segurança, porque `tool_calls` é só registro e a execução passa pela API com escopo por marca (invariante 12). Mas um nome errado passa sem aviso.

**Ideia.** Um `enum` no esquema com o catálogo (ex.: `get_settlement_status`, `get_transaction_status`, `get_fee`), versionado junto do contrato.

**Quando vale.** Quando a lista de consultas do agente estiver definida (RF-32).

## 5. Métrica de turnos descartados e custo desperdiçado

**Problema.** Não sabemos quanto trabalho do agente é jogado fora pela invalidação de turnos.

**Ideia.** No Grafana: taxa de turnos `superseded` por canal e marca, tempo médio do agente gasto em turnos descartados, e a janela de agrupamento que minimiza isso sem atrasar demais a resposta. Os dados já ficam em `ai_turns` (status e `response`).

**Quando vale.** Junto dos experimentos de carga (bloco 19). Ajuda a calibrar a janela de 1,5 s / 4 s (RN-55).

## 6. Teste de mutação automatizado

**Problema.** Os testes de mutação desta etapa foram manuais (os revisores quebraram o código à mão). Assim, descobrimos testes que passavam mesmo com o código errado.

**Ideia.** Usar a gem `mutant` no CI, nas regras críticas (turnos, idempotência, isolamento).

**Quando vale.** A `mutant` é gratuita para projetos open source e paga para repositórios privados. Vale se o repositório for público.

## 7. Particionar `messages` e `audit_events` por mês

**Problema.** São as tabelas que mais crescem (07, seção 4).

**Ideia.** Particionamento nativo do Postgres por mês.

**Quando vale.** Só se o E1 mostrar degradação com volume (RNF-08). Já registrado como evolução no 07.

## 8. Provedores reais em sandbox

**Problema.** Os canais são simulados no formato real (ADR-018), mas nunca foram testados contra a Meta e o Google de verdade.

**Ideia.** Rodar os adaptadores contra o sandbox da Meta e uma conta Gmail de teste, só com dados sintéticos.

**Quando vale.** Depois do MVP. Exige contas, aprovação e cuidado com a LGPD (RNF-25).

## 9. Deploy em servidor com Kamal

**Problema.** O projeto roda só com Docker Compose numa máquina (ADR-011).

**Ideia.** Kamal, citado pelo TAPI, para deploy em servidores reais.

**Quando vale.** Depois do MVP. Já registrado como evolução no ADR-011.

## 10. Ilha React no editor de regras

**Problema.** O editor de regras de roteamento (aninhamento, arrastar e soltar) pode ficar difícil em Stimulus.

**Ideia.** Só essa tela em React, dentro do Rails. O resto continua em Hotwire.

**Quando vale.** Se o teste cronometrado do RNF-31 (criar fila e regra em até 3 min) falhar. É o plano B do ADR-002.

## 11. Fila na porta da ingestão

**Problema.** Hoje o webhook do canal (chat, WhatsApp, e-mail) só recebe o `202` depois de a mensagem estar gravada no Postgres, com deduplicação, `seq`, auditoria e outbox na mesma transação (RNF-01, RNF-14, invariante 1). A fila de reenvio é o próprio provedor: sem resposta, a Meta e o Google reenviam. Num pico muito alto, se o Postgres ficar lento, o ack pode passar do tempo que o provedor espera.

**Ideia.** Receber o webhook cru, gravar num tópico próprio (ex.: `helpdesk.channels.inbound.v1`, com `acks=all`), responder na hora e normalizar e gravar no Postgres por um consumer.

| | Hoje (gravar e responder) | Fila na porta |
| --- | --- | --- |
| O `202` significa | Mensagem já está no ticket | Mensagem guardada, ainda não processada |
| Perda | Zero (Postgres) | Zero, se o Kafka confirmar com `acks=all` |
| Complexidade | Uma etapa | Mais um consumer, mais um ponto de falha, deduplicação depois do ack |
| Pico | Limite por marca devolve `429` (RNF-33) | Absorve o pico, a fila cresce |

**Decisão (18/11/2026).** Manter como está no MVP e deixar o experimento E1 decidir. Colocar agora seria otimizar sem número.

**Quando vale.** Se o E1 mostrar o ack da ingestão acima de 500 ms (p99 do RNF-01) na carga de referência. Nesse caso, vira ADR novo no 08 e muda o texto do RNF-14 ("o ack só sai depois de a mensagem estar persistida" passaria a aceitar a persistência no tópico).

**Origem.** Pergunta do usuário durante o bloco 03: por que não há fila entre os webhooks dos canais e a plataforma.
