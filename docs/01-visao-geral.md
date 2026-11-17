# 01 — Visão geral

O objetivo é construir um help desk próprio, self-hosted e AI first para a CloudWalk. O agente de IA atua nele como atendente de primeiro nível, e o analista humano entra por escalação.

## Problema

O help desk atual é de terceiros. Ele é lento, apresenta defeitos recorrentes e não permite priorizar features. Também não se adapta à operação multi-marca (InfinitePay, JIM) e multi-equipe. A CloudWalk não controla a própria plataforma de atendimento.

Hoje, um broker consome as mensagens do help desk via webhooks e as repassa ao agente de IA por um tópico Kafka. As respostas fazem o caminho inverso.

## Objetivo

Entregar uma plataforma que:

- receba solicitações de chat no app, WhatsApp e e-mail;
- distribua os casos em filas configuráveis pela operação;
- integre o agente de IA via webhooks e broker;
- ofereça ao analista humano um painel com escalas, contexto e histórico;
- registre a auditoria de cada decisão de atendimento e de escalação;
- escale para milhares de atendimentos novos por dia, com picos sazonais.

## Pergunta norteadora

> Como construir uma plataforma de help desk própria, AI first, multi-equipe e multi-marca, que integre agentes de IA como atendentes de ponta a ponta, distribua os casos em filas configuráveis e escale para o volume da operação com priorização e handoff humano adequados?

## Formato

- Projeto individual, Inteli × CloudWalk.
- Duração estimada de 1 mês.
- Datas de onboarding e entrega final: a definir.
