# 13 — Roteiro de testes e validação

> **Onde estamos (25/11):** a régua foi corrigida (perfil `realista`, overhead medido na fronteira do agente) e seis
> correções estão em código (ADR-031 a 035). A rodada com todas ligadas é a próxima: `.\bench\fila-admissao.ps1`.
> Resultados e explicação no [docs/12](12-validacao-realista.md).

Série de testes a executar antes da entrega, em ordem, com o que cada um prova, o critério de aprovação e o estado
em 24/11/2026. A ordem importa: cada fase só vale se a anterior passou (carga sobre código quebrado e caos sobre um
caminho normal que já falha não provam nada). Tudo roda com o **agente simulado**; Gemini e RAG só entram depois (ADR-030).

> Limite geral: os números vêm de um notebook (14 CPUs, 7,5 GB para o Docker) com agente simulado. Provam o
> comportamento nesta configuração, não a capacidade de produção.

## Visão geral

| # | Fase | Pergunta que responde | Comando | Estado |
|---|---|---|---|---|
| 0 | Pré-voo | O ambiente subiu inteiro (agente e consumidor incluídos)? | automático em `pico.ps1` | feito |
| 1 | Testes automatizados | O código faz o que as regras de negócio pedem? | `rspec` de cada módulo | parcial |
| 2 | Pico (diagnóstico) | Onde estão os gargalos numa rajada? | `.\bench\fila-pico.ps1` | em andamento |
| 3 | Estresse | A partir de quantas msg/s a plataforma deixa de acompanhar? | `pico.ps1 -Perfil estresse` | escrito, não rodado |
| 4 | Carga (negócio) | O ritmo normal de uma operação é sustentado, com o pico incluído? | `.\bench\negocio\run.ps1 -Ajustado` | a refazer |
| 5 | Caos | Nada se perde quando algo cai? | `.\bench\chaos\run.ps1 -Cenario ...` | a refazer |
| 6 | Telas | O painel responde em tempo aceitável? | `.\bench\ui\run.ps1`, `lighthouse.ps1` | a refazer |
| 7 | Qualidade do agente | O agente simulado responde conforme os casos? | `promptfoo` (`bench/agent-quality`) | a rodar |
| 8 | Tudo de uma vez | A sequência completa funciona sem intervenção? | `.\bench\tudo.ps1` | no fim |
| 9 | Resistência (soak) | Aguenta horas sem degradar ou vazar memória? | `negocio` prolongado | fora do escopo, citar como limite |
| 10 | Gemini e RAG | A resposta gerada por modelo funciona? | `AGENT_ENGINE=gemini` | adiado até as fases 1 a 8 passarem |

## Fase 1 — Testes automatizados

Rodar a suíte inteira da plataforma (`RAILS_ENV=test`, um conjunto de cada vez no mesmo banco), mais `contracts`,
`agent-mock` e `channels-mock`.

- **Aprova se:** 0 falhas. Falha que só aparece sob carga (como `progress_notice_race_spec`, margem de 6 s) é
  investigada, não repetida até passar.
- **Estado (25/11):** plataforma 1762/0, contracts 315/0, broker 30/0, agent-mock 138/0 e channels-mock 122/0;
  nenhuma pendência na plataforma. RuboCop sem infrações nos cinco módulos, Brakeman sem alertas e 4 testes Node
  passando. Cobertura do domínio: 99,27%. Plataforma executada com Postgres real em banco de teste separado;
  duração de 17 min 14 s. Evidência local: `src/platform/tmp/codex-check-rspec.json` (arquivo temporário, fora do Git).

## Fase 2 — Pico (diagnóstico)

Perfil `pico` (~4 min): 2 msg/s, 5 msg/s e rajada de 30 msg/s por 1 min. Amostra CPU por serviço, locks do Postgres,
consultas pesadas e lag do Kafka.

- **Aprova se:** respostas da IA aplicadas na maior parte dos turnos; evento do outbox publicado bem abaixo do prazo
  do turno (20 s); outbox vazio no fim; `lost_messages` = 0.
- **Estado:** com o agente no ar, 6 de 879 turnos aplicados; outbox 11,6 s (mediano); `FOR UPDATE` do atendimento com
  ~1 015 s de espera somada. Corrigido em código (ADR-031), **efeito ainda não medido**.
- **Variáveis a comparar:** 4 workers × 8 threads e 8 workers × 2 threads.

## Fase 3 — Estresse

Perfil `estresse` (~8 min): degraus de 60 s a 1, 2, 4, 6, 8, 12, 16 e 24 msg/s.

- **Aprova se:** o degrau em que o ack passa de 200 ms (p95) ou as respostas somem está documentado como a capacidade
  da configuração. Não há "passou ou não passou": o produto é o número do ponto de quebra.
- **Estado:** perfil escrito, nunca executado.

## Fase 4 — Carga (negócio)

Perfil `negocio` (~16 min): 2 msg/s por 1 min, 5 msg/s por 10 min, rajada de 30 msg/s por 1 min e 2 min de recuperação.

- **Aprova se (RNF-01, RNF-09):** ack p95 ≤ 200 ms e p99 ≤ 500 ms no patamar; erros 5xx < 0,1%; 0 mensagens perdidas;
  respostas da IA entregues dentro do prazo do turno; outbox vazio no fim.
- **Estado:** rodadas anteriores tiveram o pipeline quebrado; só vale depois de a fase 2 melhorar.

## Fase 5 — Caos

Quatro cenários com `.\bench\chaos\run.ps1 -Cenario <nome> -DuracaoFalhaSeg 30`:

| Cenário | Falha injetada | Esperado |
|---|---|---|
| `kafka` | Kafka pausado | Outbox acumula e drena depois; nada perdido |
| `agente-mudo` | Agente parado | Turnos expiram e o caso vai para humano (RN-46) |
| `postgres-latencia` | +300 ms até o Postgres | Degrada sem corromper; recupera |
| `redis-corte` | Conexões do Redis cortadas | Sidekiq reconecta; jobs não se perdem |

- **Aprova se:** `lost_messages` = 0 e nenhuma duplicata de resposta em todos os cenários.
- **Estado:** resultados antigos são de rodadas inválidas; repetir depois da fase 4.

## Fase 6 — Telas

Playwright (troca de tela, TTFB, LCP, CLS) e Lighthouse na página autenticada (`/conversas`).

- **Aprova se:** dentro dos limites do RNF-32.
- **Estado:** scripts prontos; rodar com o pipeline funcionando.

## Fase 7 — Qualidade do agente

Casos de `bench/agent-quality/cases.yaml`, asserções determinísticas, sem LLM como juiz (docs/09).

## Fase 8 — Tudo de uma vez

`.\bench\tudo.ps1` (aceita `-SemTestes` e `-SemCarga`). Não para no primeiro erro e lista no fim o que falhou; o log fica
em `bench/results/tudo-<data>.log`. Serve de prova de que a sequência completa roda do zero.

## Plano de correção (25/11)

Diagnóstico: os dois lados têm problema. **O teste** cria um atendimento novo por mensagem, sem pausa do cliente,
e a rajada do `pico` (30 atendimentos/s) passa da rajada do requisito (~12/s). **O sistema** gasta ~12 s (mediano) de
overhead por turno, contra a meta de p95 ≤ 1 s (RNF-03), por três causas medidas: disputa pela linha do atendimento,
threads demais por processo (GVL) e todos os eventos na mesma fila.

| Etapa | O que fazer | Como saber que deu certo |
|---|---|---|
| A. Régua certa (**feito**) | Perfil `realista` no k6: conversas na taxa do docs/05, ~4 mensagens por conversa com pausa; premissas declaradas | Roda e reconcilia sem perdas |
| B. Linha de base (**feito, 25/11**) | Carga de referência (RNF-09) com o perfil realista, na configuração atual | Overhead e ack por fase registrados como "antes" |
| C. Filas por urgência (**código, ADR-032**) | `OutboxJob` escolhe `critical`, `timers` ou `low` pelo tipo do evento; teste do mapeamento | Outbox do caminho do cliente cai; handoff segue no prazo (RN-46) |
| D. Processos, não threads (**código, ADR-032**) | 8 processos × 2 threads como padrão do worker | Igual ou melhor que o pico de 24/11 (outbox 1,3 s) |
| E. Tentar e sair (**lock_timeout no job; descarte de obsoleto e transação curta ainda não**) | Trava sem espera (NOWAIT/advisory): ocupado, o job volta em ~200 ms; obsoleto é descartado sem travar; transação curta no `Turns::Open` e `AgentActions::Apply` | Amostras de `Lock` perto de 0; overhead perto da meta; suíte de concorrência verde |
| F. Remedir (**parcial: ADR-032 medido; ADR-033 a 035 a medir**) | Referência e rajada (RNF-09, RNF-10) com o perfil realista | Comparação antes × depois, mesma configuração |
| E2. Controle de admissão (**código, ADR-035**) | Fila do agente na plataforma, prazo mais próximo primeiro, aviso aos 5 s, handoff `agente_sem_vaga` | Patamar: fila da integração perto de 0. Rajada: nada perdido, turno sem vaga tratado em segundos |
| G. Entrada HTTP, se preciso (**Puma em cluster, ADR-033**) | Mais processos do Puma; depois vários `web` com balanceador; por último a fila na porta (melhorias #11) | Só se o ack passar de 200 ms (p95) na referência |
| H. Escalar | Mais processos de worker; autoescala pela idade do item mais antigo da `critical` | Vazão sobe com réplicas (RNF-11) |
| I. Restante do roteiro | Suíte completa, estresse, `negocio`, caos, telas, qualidade, `tudo.ps1` | Fases 1 a 8 acima |
| J. Documentar | ADRs, docs/12, ROADMAP, relatório de 5 seções | Antes × depois e limites declarados |

**Medição na fronteira do agente (25/11; RNF-03 e ADR-034).** Overhead da plataforma = tempo fim a fim − processamento declarado pelo agente − janela de agrupamento. A fila até o agente conta como plataforma. As fronteiras **ida** (janela fechada → publicação no Kafka), **agente** (publicação → resposta no Kafka) e **volta** (resposta no Kafka → aplicação → entrega) ajudam a localizar a demora; só ida + volta não basta para aprovar a RNF-03. O campo `fronteiras_ms.overhead_com_fila` do `reconcile.rb` inclui a fila e desconta o `timing.agent_ms`. Para o aceite, separar o patamar da rajada e declarar as amostras sem resposta entregue.

Regra: uma mudança por vez, medida no mesmo perfil, antes de passar para a próxima.

## Regras para ler os resultados

1. **Pré-voo primeiro.** Sem `agent-mock` e `consumer` no ar todo turno expira e o resultado não vale.
2. **Um ambiente por vez.** Não rodar dois stacks nem duas suítes no mesmo banco ao mesmo tempo.
3. **Antes e depois.** Cada correção de desempenho registra o número anterior e o novo, no mesmo perfil.
4. **Não afirmar além da evidência.** "Gargalo resolvido" só depois de o pico repetido mostrar a melhora.
5. **Limites declarados.** Notebook, agente simulado, rodada única: o relatório diz isso.

## Registro de execuções

| Data | Fase | Configuração | Resultado | Evidência |
|---|---|---|---|---|
| 24/11 | 2 pico | 1 worker, sem agente no ar | inválido (porta 3001 derrubou o agente) | `bench/results/2026-11-24-pico` |
| 24/11 | 2 pico | 4 workers, sem agente | outbox drenado; 0 respostas (agente ausente) | idem |
| 24/11 | 2 pico | 4 workers, com agente | 6/879 aplicados; gargalo no lock do atendimento | idem |
| 24/11 | 2 pico | 4 workers × 8 threads, com ADR-031 | 52/1270 aplicados; ack mediano 8,2 s (era 22,7 s); 0 rejeitados (eram 361); outbox 9,1 s | `20261124233906-pico-*` |
| 24/11 | 2 pico | 8 workers × 2 threads, com ADR-031 | 121/1276 aplicados; outbox 1,3 s (era 11,6 s); overhead da plataforma 11,7 s (era 36 s); amostras de lock 61 (eram 197) | `20261124234823-pico-*` |
| 25/11 | B realista (linha de base) | 8 × 2, agente 3–12 s, 48 de concorrência | 0 perdas; 0 rejeitadas; publicação ao agente 0,12 s (mediano); 364/2191 aplicados; resposta volta em ~21 s com o agente gastando ~7,7 s; ack do patamar p95 33 s | `2026-11-25-realista/20261125002602-*` |
| 25/11 | F realista | ADR-031 e 032; 8 × 2 workers, 4 consumidores | specs 775/0; ida + volta mediano 1,6 s, p95 5,6 s (meta p95 ≤ 1 s); agente (caixa-preta) 15,3 s contra 6,0 s que ele informa; ack do patamar p95 39,6 s e 1,3% de falha (pior); 373/2247 aplicados | `2026-11-25-realista/20261125011435-*` |
