# Verificações por área

Use as seções relevantes à entrega. Busque no 07 os nomes de campos e fluxos citados abaixo e confirme os detalhes nos requisitos e ADRs vigentes.

## Ingestão, webhooks e mensageria

- Confirme que o canal recebe ACK após o commit da mensagem, da auditoria e do outbox. Reentrega do mesmo webhook preserva uma única mensagem. A deduplicação considera o escopo da marca, conta do provedor e canal.
- Verifique onde o broker valida HMAC e esquema, quando confirma a publicação e se a chave e a correlação do evento são preservadas. Retentativas mantêm o mesmo `event_id` e conteúdo. A ordem de publicação do Kafka e a ordem de negócio pelo `seq` são garantias distintas.
- Siga o consumer até a confirmação do offset. Em uma falha entre commit e ACK, a reentrega produz o mesmo efeito observável. Em payload inválido ou DLQ, confirme se alterações no atendimento exigem vínculo confiável e turno ainda válido.

## Turnos, scheduler e recuperação

- Em ingestão e aplicação, siga as operações até a mesma trava do atendimento. Confira se a mensagem 2 gravada aos 3 s invalida a resposta do turno anterior às 3,5 s, mesmo antes de o turno seguinte sair. Aplique também a ordem inversa dos commits.
- A ação deve corresponder ao turno atual elegível, ao pedido e à atribuição. Compare o `context_until_seq` com o registro persistido e a última mensagem do cliente. A segunda ação final preserva o resultado terminal da primeira.
- Confira o caso de resposta válida antes do ACK do broker. A elegibilidade nasce na transação que grava o turno e seu evento no outbox.
- O prazo de fallback pertence ao ciclo do ticket. Teste broker indisponível antes da publicação e resposta em ou após o prazo com job atrasado. O scheduler registra ação durável no outbox com chave de emissão, e o worker revalida sob o lock antes de concluir a ação. Investigue perda do job no Redis ou execução repetida de uma ação antiga.
- Para correções no contexto, verifique cobertura das mensagens pendentes, tamanho do envelope e fronteira entre resumo e histórico.

## Handoff, fila e canal de saída

- Confira o pedido explícito de humano em estados relevantes, a mudança de atribuição e a entrada na fila com o histórico acessível. A falha do resumo tem tratamento separado.
- Distinga saída pendente, em envio e terminal. No handoff, a saída da IA ainda pendente é cancelada. A saída já em envio é conciliada antes da próxima entrega. As retentativas mantêm `delivery_id` e as saídas visíveis seguem o `seq`.
- Para distribuição humana, reproduza dois workers disputando a última vaga e confirme as condições de equipe, capacidade e disponibilidade no ponto da atribuição. Examine devolução à fila e SLA quando o analista fica offline.

## Roteamento, autorização e auditoria

- Confirme a avaliação ordenada de regras e fila padrão, o versionamento e a validade em tempo de execução. Trace a decisão até a versão registrada. Verifique alterações e desativações de filas com casos em andamento.
- Teste isolamento tanto na leitura quanto na escrita. Considere IDs idênticos, workers, Kafka, ActionCable e reprocessamento da DLQ conforme as fronteiras tocadas. Prefira evidência obtida pelo ponto de entrada usado normalmente.
- Verifique se a auditoria representa as mudanças de estado com identificação e correlação suficientes e mantém dados sensíveis fora de logs e telas sem escopo.

## Painel, medições e evals

- Siga a tela até a fonte de leitura. Distinga dados sintéticos, eventos do ambiente e estados como execução ausente ou erro de coleta. Verifique vínculos entre ticket, mensagem, turno e execução.
- Confira o significado das durações e percentis. Separe agrupamento, processamento e entrega. Mostre população e janela de medição onde necessário. Verifique se timeout, descarte e erro continuam representados mesmo sem resposta final.
- Diferencie êxito da regra testada, qualidade da resposta e disponibilidade do cenário. Confira gabarito, resultado observado, versão do agente e evidência. Para replay ou modo sombra, verifique a separação dos canais e poderes de escrita.
