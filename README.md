# Documentação — Help Desk CloudWalk (SRS)

Especificação de Requisitos de Software da plataforma de help desk própria, AI first, multi-marca e multi-equipe, do projeto Inteli × CloudWalk.

O [roadmap de construção](ROADMAP.md) organiza as entregas de backend e frontend em quatro semanas, com critérios de conclusão por bloco.

A skill [cloudwalk-architecture-review](.agents/skills/cloudwalk-architecture-review/SKILL.md) revisa entregas de código contra o roadmap, os requisitos e a arquitetura vigente.

## Como rodar

Pré-requisitos: Docker com Compose e `make`.

```bash
cp .env.example .env   # opcional: o make up cria se faltar
make up                # sobe postgres, redis e web, e cria o banco
make seed              # carrega os dados sintéticos (semente em SEED)
```

Abra http://localhost:3000. A tela inicial lista as conversas de exemplo.

| Comando | Para |
| --- | --- |
| `make check` | Testes, rubocop e brakeman. Precisa passar antes de abrir o pull request |
| `make logs` | Acompanha os logs |
| `make reset` | Recria o banco e carrega o seed |
| `make down` | Para o ambiente |

Para rodar sem Docker, com Postgres e Redis locais, veja a seção "Comandos" do [AGENTS.md](AGENTS.md). Onde fica cada coisa: [docs/10](docs/10-organizacao-do-repositorio.md).

## Índice

| # | Documento | Conteúdo | Status |
| --- | --- | --- | --- |
| 01 | [Visão geral](docs/01-visao-geral.md) | Problema, objetivo, pergunta norteadora | Rascunho |
| 02 | [Escopo](docs/02-escopo.md) | Dentro e fora do escopo, premissas, restrições | Rascunho |
| 03 | [Atores e glossário](docs/03-atores-e-glossario.md) | Perfis de usuário e termos do domínio | Rascunho |
| 04 | [Requisitos funcionais](docs/04-requisitos-funcionais.md) | 61 RF em 11 módulos, critérios de aceite, rastreabilidade com o TAPI | Rascunho |
| 05 | [Requisitos não funcionais](docs/05-requisitos-nao-funcionais.md) | RNF com métricas | Rascunho |
| 06 | [Regras de negócio](docs/06-regras-de-negocio.md) | 57 RN em 12 temas, parâmetros padrão e perguntas para o onboarding | Rascunho |
| 07 | [Arquitetura](docs/07-arquitetura.md) | Princípios, componentes, fluxos, modelo de dados, contratos, falhas, escalabilidade e segurança | Rascunho |
| 08 | [Decisões de arquitetura](docs/08-decisoes-de-arquitetura.md) | Stack escolhida e 18 ADRs com alternativas e consequências | Rascunho |
| 09 | [Evolução da integração com a IA](docs/09-evolucao-da-integracao-com-ia.md) | Fronteira do agente, leitura sob demanda, RAG, desempenho e avaliações | Proposta |
| 10 | [Organização do repositório](docs/10-organizacao-do-repositorio.md) | Para que serve cada pasta, onde ficam migrations, Redis, Kafka e contratos | Rascunho |

## Como contribuir

As regras de branch, commit, pull request e TDD estão no [CONTRIBUTING.md](CONTRIBUTING.md). Agentes de IA seguem também o [AGENTS.md](AGENTS.md).

## Convenções

- **IDs:** `RF-XX`, `RNF-XX` e `RN-XX`. Um ID nunca é reaproveitado; um requisito removido fica marcado como *descontinuado*.
- **Prioridade (MoSCoW):** **M** (Must, obrigatório), **S** (Should, importante), **C** (Could, desejável), **W** (Won't, fora desta entrega).
- **Rastreabilidade:** cada RF aponta para as RN que aplica, e cada RNF para o experimento que o comprova.

## Fonte

- TAPI "Help Desk Integrado a Agentes de IA" (Inteli × CloudWalk).
