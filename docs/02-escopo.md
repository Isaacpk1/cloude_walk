# 02 — Escopo

O recorte é a plataforma de help desk e a integração dela com um atendente de IA simulado. O agente real, os dados reais e os sistemas de produção ficam fora.

## Dentro do escopo

- Recebimento multi-canal **simulado**: chat no app, WhatsApp e e-mail.
- Modelo multi-marca e multi-equipe, com isolamento lógico por marca.
- Filas múltiplas, configuráveis e editáveis pela operação em tempo de execução, sem deploy.
- Triagem, priorização e distribuição entre o agente de IA e os analistas.
- Integração com o atendente via webhooks, broker e tópico de mensageria (Kafka ou similar).
- **Agente de IA mock**, determinístico ou com LLM aberto, registrando modelo, versão e configuração.
- Interface de conversa entre cliente e atendente.
- Painel do analista com fila de escalas, contexto e histórico.
- Handoff com resumo e contexto, preservando o histórico.
- Trilha de auditoria de decisões e escalações.
- Memória e contexto entre interações.
- Experimento técnico (carga e escalabilidade, distribuição de filas ou fluxo de handoff).
- Empacotamento em Docker e README completo.

## Fora do escopo

- Desenvolvimento do agente de IA real.
- Dados reais de clientes. Todos os dados serão sintéticos.
- Integração com sistemas, APIs ou ambientes de produção da CloudWalk.
- Apps móveis.
- Integração real com WhatsApp Business API ou provedores de e-mail. Os canais serão simulados.

## Premissas

- A CloudWalk fornece apenas o desenho da arquitetura atual (help desk, broker e agente).
- O contrato de mensagens com o agente é definido por este projeto, inspirado no fluxo atual: webhook → broker → tópico → agente, e o caminho inverso para as respostas.
- O volume de referência é de "milhares de atendimentos novos por dia, com picos". A meta numérica exata fica em [05 — RNF](05-requisitos-nao-funcionais.md).

## Restrições

- Obediência integral à LGPD: nenhum dado pessoal real é usado.
- Nenhum acesso a sistemas internos da CloudWalk.
- Proibido tentar identificar clientes ou casos reais a partir do material fornecido.
- Prazo de 1 mês, com projeto individual.
-
