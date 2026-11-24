# 11 — Validação operacional dos blocos 17 e 18

## Escopo

Rodada de 23/11/2026, na máquina do usuário, branch `feat/17-18-validacao-operacao`, a partir de `68baab6`. Os relatórios identificam a revisão base e o conteúdo executado; não representam um commit novo. Todos os dados são sintéticos.

Requisitos: RF-13 a RF-18, RF-34 a RF-36, RF-39 a RF-48, RF-54 a RF-56, RF-60; RN-18, RN-20, RN-26, RN-30, RN-38, RN-52, RN-54 e RN-56; experimentos E2, E3, E4 e E6 do [05](05-requisitos-nao-funcionais.md). Definição dos indicadores aprovada no [ADR-025](08-decisoes-de-arquitetura.md#adr-025--indicadores-operacionais-com-população-explícita).

## Mudanças e teste vermelho

- RF-60: o painel não tinha os indicadores agregados. Os testes novos produziram **7 exemplos, 6 falhas**, pela ausência da leitura e da seção. A implementação passou com **7 exemplos, 0 falhas**. Cobrem isolamento por marca, estoque com mais de 200 casos, fila ausente, ausência de população, escalação repetida, espera e limites exatos de SLA e 24 horas.
- RF-14/RF-16: o formulário real enviava condições vazias com operador `eq`. O serviço não as ignorava, então a publicação pela tela era recusada. O teste de sistema enviou o formulário completo e falhou com erro de contrato em `/rules/0/any/0/all/1`. A correção ignora linhas sem campo e sem valor; condições parcialmente preenchidas continuam sujeitas à validação. O teste de sistema e os testes do serviço passaram: **8 exemplos, 0 falhas**.
- RN-18/RN-20: teste novo com publicação e chegada de atendimentos em sete conexões reais. Cada caso usa uma versão inteira e destino coerente; o cache já aquecido vê a nova versão e o caso antigo conserva a sua. **1 exemplo, 0 falhas**.
- Execução no Compose: o comando de testes não montava `bench`, causando quatro `LoadError` na reconciliação. O alvo `test` passou a montar essa pasta e a permitir o hostname local do Postgres para o DatabaseCleaner somente na invocação de testes. O executor dos experimentos exige um banco separado.

## Evidências automatizadas

O executor e a lista completa dos cenários ficam em [bench/validation](../bench/validation/README.md). `make validate-operation` grava `bench/results/operation/summary.json` e o relatório completo de exemplos. Os resultados separam E2, E3, E4 e E6. Os casos de concorrência usam Postgres real, sem transação de teste e com truncation; os prazos usam relógio controlado. As falhas de dependência são injetadas, sem interromper os serviços usados pelo usuário.

Resultado final: **1694 exemplos, 0 falhas, 0 pendências**, com semente 42, Ruby 4.0.10 e domínio com **99,31%** de cobertura. RuboCop: **446 arquivos, nenhuma infração**. Brakeman: **0 erros, 0 alertas**. Os quatro scripts de validação também passaram pelo RuboCop com a configuração da plataforma. O executor específico passou com **166 exemplos**: E2 = 40, E3 = 37, E4 = 54, E6 = 35. Resumo dos checks em [checks.json](../bench/results/operation/checks.json); evidências por exemplo em [summary.json](../bench/results/operation/summary.json).

E2 cobre perda de job, queda após commit da ação do scheduler, repetição da recuperação, indisponibilidade do broker, timeout no limite e recuperação visível no painel. E3 cobre edições concorrentes, propagação de versão, proteção de filas em uso e configuração pelo formulário completo. E4 cobre a última vaga, devolução por analista offline, ordem de commit, resposta antes do ACK, entrega durante handoff e broadcast após commit. E6 cobre matriz de perfis e marcas, webhooks inválidos, mascaramento de logs, conexão do ActionCable e integridade no banco.

Execução por experimento: **166 exemplos, zero falhas e zero pendências** (E2: 40; E3: 37; E4: 54; E6: 35). [Relatório por cenário](../bench/results/operation/summary.json).

Execução final completa: **1.694 exemplos, zero falhas e zero pendências**, semente 42, Postgres real em `helpdesk_test_1718`. RuboCop: **446 arquivos, sem infrações**. Brakeman: **zero erros e zero alertas de segurança**. Cobertura do domínio: **99,31%** na saída da suíte. Os [checks](../bench/results/operation/checks.json) guardam o resumo, a cobertura geral e os resultados das ferramentas. A suíte levou 198 min 33 s de relógio de parede nesta execução, compartilhando a máquina com o desenvolvimento e outros contêineres; isso não é uma medição de desempenho da plataforma.

## Observação com serviços reais

O ambiente começou com a gem `bcrypt` ausente e cinco migrations pendentes. Foram instaladas as dependências e aplicado `db:prepare`, preservando o banco. O seed idempotente completou as senhas sintéticas ausentes. Web, worker, scheduler e consumer foram reiniciados para carregar a versão atual.

Após a execução, a sonda de 3 s continuava expirando, embora o endpoint respondesse HTTP 200 em 4,76 s com limite maior. O timeout do healthcheck web local foi ajustado para 15 s, conforme [ADR-026](08-decisoes-de-arquitetura.md#adr-026--tolerância-do-healthcheck-web-no-ambiente-local). Os prazos do negócio e as metas dos RNF não foram alterados.

Após recriar somente o web, o serviço ficou **healthy**, com duas sondas consecutivas bem-sucedidas. A primeira requisição durante o boot ainda excedeu 15 s, dentro do período inicial já configurado; não foi contada como garantia de prontidão. Evidência em [web-health.json](../bench/results/operation/web-health.json).

A sonda do web também tinha um falso negativo: `curl --max-time 3` expirou, enquanto uma chamada com limite maior recebeu `200` em 4,76 s. O timeout técnico do Compose local passou para 15 s pelo [ADR-026](08-decisoes-de-arquitetura.md#adr-026--tolerância-do-healthcheck-web-no-ambiente-local). Não houve alteração de prazo de negócio.

A marca `validacao-20261123142348` foi criada só para este roteiro. No navegador, o supervisor criou uma fila humana e publicou a regra de categoria `repasses`. Nenhum serviço foi reiniciado entre a criação e a aplicação da regra.

- **Caso 7:** a primeira mensagem percorreu o broker e o Kafka; o turno recebeu ação `reply` e ficou `applied`. O roteamento gravou conjunto de regras **versão 1**, na fila padrão. O pedido seguinte de humano levou o caso à fila de escalas com motivo e resumo da plataforma disponíveis.
- **Caso 8:** após a publicação pela tela, um novo atendimento usou o conjunto de regras **versão 2** e entrou na fila humana “Repasses de validação”. A fila mostrou SLA e tempo de espera. O caso anterior preservou a versão 1.
- **Falha de canal:** o provedor simulado só reconhece as contas fixas. A conta da marca nova recebeu `404 conta_desconhecida`. A conversa e a auditoria mostraram a falha definitiva, com tentativa e ID de entrega. Esse cenário comprova a apresentação da falha, não entrega bem-sucedida.
- **Caso 9:** uma identidade sintética nova na conta conhecida da InfinitePay percorreu webhook, Kafka e agente; a ação foi aplicada e a entrega ficou **`delivered`**. Sem alterar as regras existentes da marca.
- **Repetição e assinatura:** para cada envio do emissor, a sequência foi `202`, `200` com o mesmo ID e seq, e `401` com assinatura adulterada. O banco contém uma mensagem por ID externo.
- **Indicadores:** a tela da marca isolada mostrou estoque por fila, espera, SLA, taxa por caso distinto, janela de 24 horas e ausência de dados onde não havia população.

Fotografia do banco: [live.json](../bench/results/operation/live.json). Capturas: [fila e indicadores](../bench/results/operation/painel-operacional.jpg) e [falha de entrega](../bench/results/operation/falha-entrega.jpg).

## Limites e pendências mensuráveis

- Não houve queda física de Redis nem indisponibilidade de cinco minutos no Compose do usuário. Esses cenários foram exercitados por injeção determinística nos testes. Não há medição de RTO ou de drenagem de backlog sob carga nesta rodada.
- Não foram medidos p95 do handoff, saturação ou escalabilidade. São evidências diferentes dos testes funcionais e permanecem no bloco 19.
- Broadcasts, rollback, falha do ActionCable, assinatura dos streams e escopo foram verificados no servidor; não foi medida a latência de todas as atualizações no navegador.
- RNF-31 exige duas pessoas configurando a operação em até três minutos. A navegação do agente não cumpre esse estudo de usabilidade.
- A conta da marca nova não existe no simulador de saída; isso é explícito no roteiro. A ida e volta bem-sucedida usa uma conta conhecida, com identidade sintética nova.
- A execução simultânea das suítes disputa CPU com o Compose e outros contêineres da máquina. Timeouts de healthcheck durante essa execução não são números de benchmark da plataforma.

## Revisão da arquitetura

Aplicada a skill local `cloudwalk-architecture-review`. A mudança de produto só lê dados para os indicadores e corrige o tratamento de controles vazios. Não muda contratos de mensagens, prazos, outbox, atribuição nem restrições do banco. Toda leitura nova recebe as marcas autorizadas; a seleção de filas e auditoria mantém esse filtro. Indicadores não usam a lista limitada a 200 casos. A taxa conta tickets distintos, não eventos de escalação. O painel não inventa taxa ou duração quando falta população. O ADR-025 registra a definição aprovada.

Os relatórios e o roadmap devem manter as limitações acima visíveis. Uma execução funcional não comprova uma meta de desempenho ou um estudo com duas pessoas.
