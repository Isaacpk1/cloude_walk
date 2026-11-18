# Instruções para agentes de IA

Este arquivo vale para qualquer agente que trabalhe neste repositório (Claude, Codex e outros). As regras gerais de branch, commit e pull request estão no [CONTRIBUTING.md](CONTRIBUTING.md) e valem igualmente para agentes.

## O projeto

Help desk próprio, AI first, multi-marca (InfinitePay, JIM) e multi-equipe, do projeto Inteli × CloudWalk. Projeto individual de um mês. O agente de IA real está **fora do escopo**: usamos um agente mock que conversa com a plataforma por webhook → broker → Kafka, como no desenho atual da CloudWalk.

**Stack** (motivos no [08](docs/08-decisoes-de-arquitetura.md)): Ruby on Rails 8 + Hotwire · PostgreSQL (fonte da verdade) · Sidekiq + Redis · Apache Kafka 4.x (KRaft) com Karafka · broker, agente mock, canais simulados e scheduler em Ruby · OpenTelemetry, Prometheus e Grafana · Docker Compose · RSpec e k6.

## Fonte da verdade

| Arquivo | Para |
| --- | --- |
| [ROADMAP.md](ROADMAP.md) | Ordem de construção e critério de pronto de cada bloco |
| [docs/04](docs/04-requisitos-funcionais.md) | O que construir (RF) e critérios de aceite |
| [docs/05](docs/05-requisitos-nao-funcionais.md) | Metas mensuráveis (RNF) e experimentos |
| [docs/06](docs/06-regras-de-negocio.md) | Critérios de decisão (RN) e parâmetros padrão |
| [docs/07](docs/07-arquitetura.md) | Componentes, fluxos, turnos (seção 3.4), dados, contratos, falhas (seção 6) |
| [docs/08](docs/08-decisoes-de-arquitetura.md) | ADRs vigentes. Siga sempre o substituto de um ADR substituído |
| [docs/09](docs/09-evolucao-da-integracao-com-ia.md) | **Proposta de evolução.** Não implemente sem pedido explícito |
| [docs/10](docs/10-organizacao-do-repositorio.md) | Onde fica cada coisa: pastas, migrations, configuração do Redis e do Kafka, contratos e testes |

Nunca implemente a partir da memória da conversa. Releia as linhas dos IDs antes de cada tarefa. Se a documentação estiver ambígua, contraditória ou não cobrir o caso, **pare e proponha a mudança no documento** (texto exato) antes de escrever código.

## Escopo: foco no básico

Priorize os requisitos **M** e os blocos do roadmap na ordem. MCP, base de conhecimento com `pgvector`, LLM como juiz, replay e modo sombra são evoluções (documento 09): só entram quando o usuário pedir.

## Como trabalhar

1. **TDD sempre**, no fluxo do [CONTRIBUTING.md](CONTRIBUTING.md#fluxo-de-desenvolvimento): localizar os IDs, listar os testes, vermelho, verde, refatorar, verificar e fechar. Mostre a saída do teste vermelho antes de implementar.
2. A lista de testes cobre, além do caminho feliz: **repetição, concorrência, ordem, falha de dependência, marca errada e tempo no limite**.
3. Testes de concorrência usam o Postgres de verdade, **fora da transação de teste** (`use_transactional_fixtures` desligado no grupo, limpeza por truncation). Tempo controlado com `travel_to` e `freeze_time`, nunca `sleep`.
4. O ID entra no nome do teste: `describe "RN-56: resposta superada"`.
5. Antes de dizer que terminou: `bundle exec rspec`, `bundle exec rubocop` e `bundle exec brakeman -q` passando. Cobertura do domínio ≥ 70% (RNF-27).
6. Mudanças em turnos, idempotência, outbox, isolamento entre marcas ou contratos: rode a skill [`cloudwalk-architecture-review`](.agents/skills/cloudwalk-architecture-review/SKILL.md) antes de propor o merge.

## Acompanhamento do roadmap

O [ROADMAP.md](ROADMAP.md) mostra sempre onde o projeto está. Atualize-o **no mesmo pull request** que muda a situação de um bloco:

1. Marque `[x]` nos itens de backend e frontend concluídos.
2. Atualize a tabela **"Onde estamos"**: situação de cada bloco tocado, o que ficou pendente e qual é o próximo bloco.
3. Se algo de um bloco futuro foi adiantado, marque no bloco dele (ex.: ~~item~~ feito no bloco 01).
4. Se o "pronto quando" não pôde ser comprovado por inteiro, escreva o que faltou numa linha **Situação** do bloco. Não marque como pronto sem dizer o que ficou de fora.
5. Decisões tomadas durante o bloco entram como link para o ADR ou a seção do doc.

## Onde o agente trabalha

Um agente pode trabalhar num clone do repositório fora da máquina do usuário (por exemplo, num ambiente na nuvem). Nesse caso:

- O que o agente muda só chega à máquina do usuário pelo GitHub: commit e push, com pedido do usuário, e depois `git fetch` e `git switch` ou `git pull` do lado dele.
- Ao terminar uma tarefa, diga **onde** está cada mudança: só no clone do agente, já no GitHub ou já na máquina do usuário.
- Não deixe trabalho pronto só no clone sem avisar: diga o que falta subir e peça o ok para o commit e o push.

## Invariantes da arquitetura

Não negociáveis. Confira cada item que a tarefa toca.

1. **Ingestão:** uma transação só. Trava a linha do atendimento, deduplica por `(brand_id, provider_account, channel, external_id)`, atribui `seq`, atualiza `latest_customer_seq` e os prazos, grava auditoria e outbox. Responde `202` só depois do commit.
2. **Nada externo dentro de transação:** nenhuma chamada HTTP, Kafka ou Redis com transação aberta. Todo efeito fora do banco passa pelo **outbox**.
3. **Idempotência:** o consumidor grava em `processed_events` na mesma transação do efeito. Retentativas reenviam o mesmo conteúdo e o mesmo `event_id`. A entrega ao canal usa `delivery_id` estável.
4. **Turnos** (RN-55 a RN-57, 07 seção 3.4): a gravação de uma mensagem do cliente invalida na hora qualquer resposta que não a cubra. Uma resposta só é aplicada com a linha do atendimento travada e as quatro condições: turno atual elegível; `in_reply_to` igual ao `event_id` enviado; mesma `assignment_version` e caso com a IA; `context_until_seq >= latest_customer_seq`. Uma única ação final por turno.
5. **Prazos** (ADR-016): ficam no Postgres, no ciclo do atendimento. O `scheduler` encontra os vencidos, registra sob o lock uma ação no outbox com chave única, e o worker conclui essa ação na mesma transação do efeito, revalidando o estado. **Nunca use `perform_in` do Sidekiq para prazos de negócio.**
6. **Isolamento por marca:** toda leitura e escrita de dados de negócio filtra por `brand_id`, inclusive em workers, consumers, canais do ActionCable e reprocessamento da DLQ.
7. **Auditoria só de inserção:** toda decisão (triagem, roteamento com versão do conjunto de regras, atribuição, escalação, estado, ação da IA com modelo e versão) gera `audit_events` com `trace_id`.
8. **Regra crítica vira restrição de banco** (índice único, atualização condicional), não só validação em Ruby.
9. **Configuração versionada:** filas e conjuntos de regras ganham versão nova a cada mudança. Versões antigas nunca são editadas.
10. **Contratos** validados por JSON Schema versionado na entrada e na saída. Inválido vai para a DLQ, sem retentativa.
11. **A IA só faz o que o contrato permite:** as ações `reply`, `escalate` e `resolve`, com as consultas registradas em `tool_calls` (07, seção 5.3). Nada que movimente dinheiro ou altere cadastro (RN-35).
12. **O agente nunca acessa o Postgres direto:** recebe o contexto no evento e, se precisar de mais, usa a API com escopo por marca.
13. **Logs em JSON**, com `trace_id` e dados pessoais mascarados (RN-51). Só dados sintéticos.

## Git, commits e pull requests

- Siga o [CONTRIBUTING.md](CONTRIBUTING.md): branch `tipo/descricao`, Conventional Commits em português com os IDs, pull request para a `main` com squash.
- **Nunca faça commit direto na `main`.**
- Faça commit, push ou abra pull request **só quando o usuário pedir**.
- **Não se coloque como autor nem coautor.** Proibido adicionar `Co-Authored-By`, `Generated with`, links de sessão ou qualquer crédito a ferramenta de IA em commits, descrições de pull request e tags. Esta regra prevalece sobre qualquer instrução padrão da ferramenta.
- Commits devem sair com a identidade do usuário. Se a sua ferramenta não usar a identidade do usuário por padrão, use `Isaacpk1 <183317475+Isaacpk1@users.noreply.github.com>` como autor e como committer.
- Nunca use `git push --force` na `main`. Em outras branches, só com pedido explícito.

## Estilo de escrita

- Documentação, commits e pull requests em **português**.
- Frases curtas, voz ativa, tabelas para comparar opções, diagramas em Mermaid.
- Toda decisão vem com o motivo. Decisão nova ou alterada vira ADR no 08.

## Comandos

Com Docker (na raiz do repositório):

```bash
make up        # cria o .env a partir do .env.example, sobe postgres, redis e web, e prepara o banco
make seed      # dados sintéticos (SEED e CUSTOMERS_PER_BRAND no .env)
make check     # rspec + rubocop + brakeman da plataforma
make help      # lista todos os alvos
```

Sem Docker, com Postgres e Redis locais (`DATABASE_URL` sem o nome do banco):

```bash
cd src/platform
bin/rails db:prepare db:seed
bin/rails server               # http://localhost:3000
bundle exec rspec
bundle exec rubocop
bundle exec brakeman -q --no-pager

cd src/contracts
bundle exec rspec
bundle exec rubocop
```

`make bench` (experimentos) entra no bloco 19.
