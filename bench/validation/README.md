# Validação dos blocos 17 e 18

## Hipótese e método

E2: a perda de jobs e as falhas do broker e do canal não apagam mensagens confirmadas nem duplicam efeitos. E3: cada roteamento usa uma versão inteira das regras; uma publicação vale para o atendimento seguinte. E4: o handoff preserva o histórico e a ordem de entrega, e dois workers não ocupam a mesma última vaga. E6: assinatura inválida e acesso a outra marca são recusados.

O executor usa RSpec com semente 42 e Postgres real. Os grupos concorrentes usam conexões separadas, sem transação de teste, com limpeza por truncation. O banco é exclusivamente `helpdesk_test_operation`. Os testes de tempo usam `travel_to` e `freeze_time`. Falhas HTTP e perda de jobs são injetadas no caminho dos serviços, jobs e consumers; não se derruba o Redis usado pelo desenvolvimento. Os testes de painel conferem conteúdo e escopo, e os de broadcast conferem commit, rollback e falha do ActionCable. O teste de sistema envia o formulário inteiro, inclusive os controles extras vazios.

```bash
make validate-operation
```

No PowerShell, na raiz, sem `make`:

```powershell
New-Item -ItemType Directory -Force bench/results/operation | Out-Null
$revision = git rev-parse HEAD
docker compose run --rm --no-deps -v "${PWD}/bench:/bench:ro" -v "${PWD}/bench/results/operation:/results" -e RAILS_ENV=test -e TEST_ENV_NUMBER=_operation -e "VALIDATION_REVISION=$revision" -e DATABASE_CLEANER_ALLOW_REMOTE_DATABASE_URL=true web sh -c "bin/rails db:prepare && ruby /bench/validation/run.rb /results"
```

O `DatabaseCleaner` aceita o hostname `postgres` somente nessa invocação de testes. O script recusa ambiente diferente de `test` e sufixo de banco diferente de `_operation`. Nunca use essa liberação com o banco de desenvolvimento.

Saídas em `bench/results/operation/`: `rspec.json` contém os exemplos completos; `summary.json` classifica os cenários por experimento, com nome, arquivo, linha e resultado. Falha, pendência ou grupo sem exemplo faz o comando sair com erro. A revisão base e o SHA-256 dos arquivos de app, configuração, testes e banco identificam o código executado, mesmo antes do commit.

## Roteiro visual e Compose real

1. Suba o Compose, aplique migrations e execute o seed idempotente. Não é necessário resetar o banco.
2. Prepare uma marca sintética separada, preservando as configurações da InfinitePay e da JIM:

   ```powershell
   docker compose run --rm --no-deps -v "${PWD}/bench:/bench:ro" web bin/rails runner /bench/validation/live_setup.rb
   ```

3. Entre como `supervisora@helpdesk.test`, com a senha sintética do README. Em `/configuracao`, escolha a marca criada. Crie uma fila humana. Antes da nova regra, envie um caso pelo script abaixo. Pela tela, publique uma regra de categoria `repasses` para a fila nova. Envie outro caso. Abra as duas conversas: a primeira conserva a versão antiga; a segunda mostra regra, versão e fila novas. Não reinicie nenhum serviço entre as publicações.
4. O emissor faz três chamadas: mensagem assinada (`202`), repetição idêntica (`200`, mesmo ID e seq) e assinatura inválida (`401`). Use a conta e o identificador da execução retornados no passo 2:

   ```powershell
   docker compose run --rm --no-deps -v "${PWD}/bench:/bench:ro" web ruby /bench/validation/live_chat.rb validacao-<run>-chat-mock acc_validacao_antes "meu repasse não caiu"
   ```

5. Peça humano na mesma identidade. Confira a fila, o motivo, o resumo e a linha do tempo. A conta nova **não é cadastrada no provedor simulado**, que só conhece as contas fixas: a saída recebe `404 conta_desconhecida`. Esse caso verifica a apresentação da falha definitiva, não a entrega bem-sucedida. Os campos de falha devem aparecer na conversa. Não amplie o contrato do simulador para mascarar essa limitação.
6. Para a ida e volta com entrega real, use uma identidade sintética nova na conta conhecida `infinitepay-chat-mock`, com o mesmo emissor. Confira `agent_event.published`, turno `applied` e entrega `delivered` no relatório. Um ACK sozinho não comprova o fluxo.
7. Na `/fila?marca=<marca de validação>`, confira indicadores, janela, numerador e denominador, espera e SLA. Faça login como analista de outra marca e confira o `404` no detalhe; os testes automatizados repetem essa matriz e verificam os streams assinados e os broadcasts.
8. Guarde a fotografia do banco com `live_report.rb`, definindo `VALIDATION_RUN` com o valor do passo 2. Os dados são somente sintéticos; não grave senhas nem segredos no relatório.

## Limitações e critérios pendentes

- Os testes de serviço não medem indisponibilidade real de cinco minutos, perda física do Redis, percentis de handoff ou consumo de CPU. E1 e E5 permanecem no bloco 19.
- RackTest não executa JavaScript. A navegação real complementa os testes, mas não substitui uma medição do tempo de atualização de todas as inscrições WebSocket.
- RNF-31 pede duas pessoas e um roteiro cronometrado de até três minutos. A execução do agente não conta como duas pessoas.
- O esquema do banco e as gems devem acompanhar a branch. Um processo saudável com código antigo não é evidência da versão nova; reinicie worker, consumer e scheduler após atualizar o código.
- Cada execução sobrescreve os relatórios automáticos; copie a pasta se quiser preservar execuções anteriores. Os casos do roteiro visual ficam no banco, identificados pela marca e pelo prefixo `validacao-`.

Resultados observados nesta rodada: [relatório de execução](../../docs/11-validacao-operacional.md).
