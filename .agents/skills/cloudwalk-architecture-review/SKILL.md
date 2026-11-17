---
name: cloudwalk-architecture-review
description: Revise código, diffs e entregas de outros agentes no Help Desk CloudWalk contra a arquitetura, os requisitos, os ADRs e o bloco do roadmap solicitado. Use para verificar aderência antes de integrar mudanças de backend, frontend, agente mock ou infraestrutura.
---

# Revisar uma entrega do Help Desk CloudWalk

Encontre a raiz do projeto pelos arquivos `ROADMAP.md` e `docs/07-arquitetura.md`. Use a arquitetura vigente na base da entrega. Se o diff também mudar a especificação, compare as duas versões e confirme se a tarefa autorizou a mudança de arquitetura. Avalie uma alteração de especificação sem autorização clara como proposta separada.

## Delimite a entrega

1. Leia a tarefa original, o bloco correspondente do `ROADMAP.md` e o diff. Use a base indicada pelo usuário quando houver. Examine arquivos novos no escopo mesmo quando o diff do Git não os inclui. Em repositório sem commits, inspecione os arquivos da entrega diretamente.
2. Abra as seções pertinentes de `docs/07-arquitetura.md` e procure os RF, RNF, RN e ADR aplicáveis nos documentos 04, 05, 06 e 08. O roadmap define a sequência de implementação. Verifique o status do ADR e siga seu substituto quando houver. Trate o documento 09 como proposta de evolução, salvo quando a tarefa incluir alguma dessas extensões.
3. Use [Verificações por área](references/checks.md) para escolher os cenários relevantes. Se a entrega combinar áreas, siga o fluxo até a próxima fronteira para encontrar problemas de integração. Investigue mudanças fora do escopo apenas quando tiverem efeito demonstrável sobre a entrega ou um requisito existente.

## Verifique pelo caminho real

- Siga o ponto de entrada usado pelo cliente, analista, scheduler ou consumidor. Confirme onde o código decide, qual transação ou operação materializa a decisão, e de onde a interface lê o resultado.
- Para achados de concorrência ou retry, descreva a sequência mínima que quebra a garantia. Compare os dois lados da fronteira em mudanças de contrato. Para UI, verifique a conexão com a fonte declarada e a diferença entre evento de demonstração e evento observado.
- Rode as verificações existentes mais próximas do risco quando o ambiente permitir. Registre a execução e os resultados. Se Docker, dependências ou serviço estiverem indisponíveis, indique quais garantias ficaram pendentes de execução. Uma inspeção estática pode sustentar um achado concreto.
- Se a entrega de outro agente afirmar que um teste passou, use o teste, os logs ou a execução reproduzível como evidência. Trate a descrição da entrega como uma pista para localizar a mudança.
- Se documentos aplicáveis entrarem em conflito, cite ambos e diga qual comportamento observou. Separe uma lacuna de especificação de um defeito reproduzido no código.

## Entregue a revisão

Comece pelos achados acionáveis, por gravidade. Para cada achado, informe impacto, condição que o provoca, arquivo e linha afetados, referência ao requisito ou decisão violada e a menor correção ou teste que provaria o comportamento. Use comentários inline quando forem úteis para revisão do diff.

Use **Correções necessárias** para uma divergência concreta que compromete o escopo. Use **Conforme no escopo verificado** quando a evidência sustentar a entrega. Use **Verificação pendente** para as garantias que ainda dependem de teste, dados ou esclarecimento. Liste os testes executados e os limites que importam para a decisão de integrar.

Em uma tarefa de revisão, devolva os achados e preserve os arquivos avaliados. Quando o usuário também pedir a correção, faça a menor mudança que resolve a divergência e verifique o caminho afetado.

Exemplo de invocação:

```text
$cloudwalk-architecture-review Revise as mudanças do agente de backend para o bloco 07 do ROADMAP.md. Priorize validade do turno e idempotência.
```
