# Como contribuir

Regras de branch, commit, pull request e documentação do Help Desk CloudWalk. Valem para pessoas e para agentes de IA. As regras específicas de agentes estão em [AGENTS.md](AGENTS.md).

## Princípios

1. **A documentação é a fonte da verdade.** O código segue `docs/`. Se o comportamento precisa mudar, a documentação muda **no mesmo pull request**, antes ou junto do código.
2. **TDD.** Nenhum código de produção sem um teste que falhou antes por ele. O fluxo está na seção [Fluxo de desenvolvimento](#fluxo-de-desenvolvimento).
3. **Pequeno e rastreável.** Branches curtas, commits pequenos e sempre ligados a um requisito (RF, RN, RNF) ou decisão (ADR).
4. **Foco no básico.** Primeiro o que o [ROADMAP](ROADMAP.md) e os requisitos **M** exigem. As propostas do [09](docs/09-evolucao-da-integracao-com-ia.md) (MCP, RAG, LLM como juiz, modo sombra) só entram depois, se houver tempo.

## Branches

- A `main` é sempre estável: testes, lint e análise de segurança verdes. **Ninguém faz commit direto na `main`.** Toda mudança entra por pull request.
- Crie a branch a partir da `main` atualizada:

  ```bash
  git switch main && git pull
  git switch -c tipo/descricao-curta
  ```

- **Nome:** `tipo/descricao-curta-em-kebab-case`, com o mesmo `tipo` dos commits. Inclua o bloco do roadmap quando houver.

  | Exemplo | Uso |
  | --- | --- |
  | `feat/02-ingestao-outbox` | Funcionalidade nova (bloco 02 do roadmap) |
  | `fix/turno-superado-aceito` | Correção de defeito |
  | `test/corrida-dos-turnos` | Só testes |
  | `docs/adr-017-base-de-conhecimento` | Só documentação |
  | `refactor/avaliador-de-regras` | Refatoração sem mudar comportamento |
  | `chore/compose-kafka` | Infraestrutura, dependências, CI |
  | `exp/e1-carga-referencia` | Scripts e resultados de experimento |

- Uma branch resolve **um** assunto. Viva no máximo alguns dias. Se crescer, divida.
- Depois do merge, a branch é apagada.

## Commits

Seguimos [Conventional Commits](https://www.conventionalcommits.org/pt-br/v1.0.0/), em português.

```
tipo(escopo): resumo no imperativo, minúsculo, sem ponto [IDs]

Corpo opcional: o porquê da mudança, não o como. Quebra em ~72 colunas.

Refs: RF-31, RN-56, ADR-016
```

**Tipos:** `feat`, `fix`, `test`, `docs`, `refactor`, `perf`, `chore`, `ci`, `exp`.

**Escopos:** `ingestao`, `canais`, `broker`, `agente`, `consumer`, `turnos`, `scheduler`, `filas`, `roteamento`, `handoff`, `painel`, `auditoria`, `marcas`, `outbox`, `infra`, `bench`, `docs`. Se nenhum servir, omita o escopo.

**Exemplos:**

```
feat(ingestao): grava mensagem, auditoria e outbox na mesma transação [RF-08, RNF-14]
fix(turnos): rejeita resposta que não cobre latest_customer_seq [RN-56]
test(turnos): cobre corrida da mensagem 2 aos 3 s [RN-56]
docs(adr): registra base de conhecimento com pgvector [ADR-017]
```

**Regras:**

- **Um commit, uma mudança lógica.** Teste e código que o faz passar podem ir juntos.
- **Todo commit fica verde:** `bundle exec rspec`, `bundle exec rubocop` e `bundle exec brakeman -q` passam. Não suba commit com teste vermelho.
- **Autoria humana.** O autor do commit é a pessoa que desenvolve o projeto. **Não adicione `Co-Authored-By`, `Generated with` nem qualquer crédito a ferramentas de IA** em commits, pull requests ou tags. Ferramentas de IA podem ajudar, mas não assinam.
- Nada de segredos: `.env`, chaves e tokens nunca entram. Use `.env.example` com valores fictícios.
- Só dados sintéticos (LGPD). Nenhum dado real de cliente, nem em teste, nem em fixture, nem em log.

## Pull requests

- **Título:** no mesmo formato do commit principal.
- **Descrição:**

  ```markdown
  ## O quê
  Resumo da mudança em 1 a 3 frases.

  ## Por quê
  Requisitos e decisões atendidos: RF-xx, RN-xx, RNF-xx, ADR-xx. Bloco do ROADMAP: xx.

  ## Como testar
  Comandos e passos para ver funcionando.

  ## Checklist
  - [ ] Testes escritos antes do código (TDD) e passando
  - [ ] rubocop e brakeman sem erros
  - [ ] Invariantes da arquitetura conferidos (AGENTS.md)
  - [ ] Documentação atualizada, se o comportamento mudou
  - [ ] Sem segredos e sem dados reais
  ```

- **Merge:** *squash and merge*, com a mensagem final no formato de commit. Só com o CI verde.
- Mudanças em turnos, idempotência, outbox, isolamento entre marcas ou contratos passam pela skill de revisão [`cloudwalk-architecture-review`](.agents/skills/cloudwalk-architecture-review/SKILL.md) antes do merge.

## Documentação

- Os documentos ficam em `docs/`, numerados. O índice está no [README](README.md).
- **IDs nunca são reaproveitados.** Um requisito removido fica marcado como *descontinuado*.
- **Decisão nova ou alterada vira ADR** no [08](docs/08-decisoes-de-arquitetura.md). Um ADR aceito não é editado: um novo ADR o substitui, e o antigo é marcado como *substituído*.
- Parâmetros de negócio novos entram na tabela de parâmetros do [06](docs/06-regras-de-negocio.md).
- Diagramas em Mermaid, dentro do próprio Markdown.
- Estilo: português, frases curtas, tabelas para comparar, IDs entre crases ou em negrito quando ajudarem a busca.

## Fluxo de desenvolvimento

Para cada tarefa:

1. **Localizar:** identificar os IDs envolvidos e ler as linhas no 04 a 08, a seção do 07 que descreve o fluxo e as falhas relacionadas (07, seção 6).
2. **Listar os testes** em Dado/Quando/Então, cada um com o ID que o exige. Além do caminho feliz, cobrir: repetição, concorrência, ordem, falha de dependência, marca errada e tempo no limite.
3. **Vermelho:** um teste por vez, falhando pelo motivo certo.
4. **Verde:** o mínimo de código para passar.
5. **Refatorar** com tudo verde e conferir os invariantes do [AGENTS.md](AGENTS.md).
6. **Verificar** a suíte completa, o lint e a análise de segurança.
7. **Fechar:** atualizar a documentação, se for o caso, commitar e abrir o pull request.

O ID vai no nome do teste (`describe "RN-56: resposta superada"`), para `grep -rn "RN-56" spec/` mostrar a cobertura de cada regra.

## Versões

Ao fim de cada semana do roadmap, uma tag na `main`: `semana-1`, `semana-2`, `semana-3`, `semana-4`. A entrega final recebe também `v1.0.0`.
