// Experimentos E1 e E5 (docs/05, seção 2): carga no webhook do chat em modelo aberto (constant-arrival-rate), que não
// sofre de coordinated omission. Cada requisição é assinada como o provedor (X-Helpdesk-Signature, ADR-019).
//
// Perfis (PROFILE):
//   smoke       30 s a 5 msg/s. Só confere que o roteiro funciona.
//   reference   aquecimento 5 min, patamar de 30 min a 20 msg/s, rajada de 60 s a 100 msg/s e volta ao patamar (E1).
//   realista    conversas (não mensagens) chegando na taxa do docs/05: cada conversa manda de 2 a 6 mensagens
//               (média 4) com pausa de 10 a 40 s; patamar a 2,5 conversas/s (~10 msg/s do cliente, ~20 msg/s com as
//               respostas: RNF-09) e rajada a 12 conversas/s por 60 s (~50 msg/s do cliente, ~100 com respostas: RNF-10).
//               PLATEAU muda a duração do patamar (padrão 5m; o RNF-09 pede 30m).
//   estresse    degraus de 60 s a 1, 2, 4, 6, 8, 12, 16 e 24 msg/s: onde a plataforma deixa de acompanhar.
//   capacity    rampa de 10 a 100 msg/s em 10 min, para achar o ponto de saturação (E1, E5).
// Formato da carga (MODE, E5):
//   independent muitas conversas: cada mensagem de um cliente diferente.
//   burst       rajadas na mesma conversa: as mensagens se repartem entre poucos clientes (BURST_CUSTOMERS).
import http from "k6/http";
import crypto from "k6/crypto";
import { check, sleep } from "k6";
import { Counter } from "k6/metrics";
import exec from "k6/execution";

const PLATFORM = __ENV.PLATFORM_URL || "http://localhost:3000";
const ACCOUNT = __ENV.ACCOUNT || "infinitepay-chat-mock";
const SECRET = __ENV.SECRET || `dev-secret-${ACCOUNT}`;
const RUN_ID = __ENV.RUN_ID || "local";
const PROFILE = __ENV.PROFILE || "smoke";
const MODE = __ENV.MODE || "independent";
const BURST_CUSTOMERS = parseInt(__ENV.BURST_CUSTOMERS || "5", 10);
const SEED = parseInt(__ENV.SEED || "42", 10);
const TEXTS = [
  "meu repasse não caiu", "quero saber o prazo do repasse", "a maquininha não liga", "preciso da segunda via do boleto",
  "como altero meu limite", "o pix não chegou", "quero falar com um atendente",
];

const accepted = new Counter("helpdesk_accepted"); // 202: confirmada e gravada
const duplicate = new Counter("helpdesk_duplicate"); // 200: o mesmo message_id de novo
const rejected = new Counter("helpdesk_rejected"); // qualquer outro status

const profiles = {
  smoke: { warmup: [ 5, "10s" ], plateau: [ 5, "20s" ], burst: null },
  reference: { warmup: [ 20, "5m" ], plateau: [ 20, "30m" ], burst: [ 100, "60s" ] },
  capacity: { ramp: true },
  // Negócio simulado (ADR-029): ritmo de uma operação média, com um pico. Pensado para o agente realista.
  negocio: { warmup: [ 2, "1m" ], plateau: [ 5, "10m" ], burst: [ 30, "60s" ] },
  // Curto, para injetar falhas durante o patamar (bench/chaos/run.ps1).
  caos: { warmup: [ 5, "10s" ], plateau: [ 5, "3m" ], burst: null },
  // Diagnóstico de bloqueios (~4 min): o mesmo pico do negócio, sem os 10 min de patamar.
  pico: { warmup: [ 2, "20s" ], plateau: [ 5, "40s" ], burst: [ 30, "60s" ] },
  // Estresse (~8 min): degraus de 60 s a 1, 2, 4, 6, 8, 12, 16 e 24 msg/s, para achar a vazão em que a plataforma deixa
  // de acompanhar (latência do ack sobe e respostas da IA param de ser aplicadas). Cada degrau tem a sua fase (rNN).
  // Modelo de carga do docs/05 (premissas lá): a unidade é a conversa, não a mensagem.
  realista: { conversations: true, warmup: [ 1, "1m" ], plateau: [ 2.5, __ENV.PLATEAU || "5m" ], burst: [ 12, "60s" ] },
  estresse: { steps: [ 1, 2, 4, 6, 8, 12, 16, 24 ], stepDuration: "60s" },
};
const p = profiles[PROFILE];
if (!p) throw new Error(`PROFILE desconhecido: ${PROFILE}`);

// Taxa fracionária (2,5/s) vira 25 a cada 10 s. Numa conversa a iteração dura minutos: o k6 espera ela terminar
// (gracefulStop) e precisa de VUs para taxa × duração média da conversa (~80 s).
function arrival(name, rate, duration, startTime, vus) {
  const whole = Number.isInteger(rate);
  const base = { executor: "constant-arrival-rate", rate: whole ? rate : Math.round(rate * 10), timeUnit: whole ? "1s" : "10s",
                 duration, startTime, preAllocatedVUs: vus, maxVUs: vus * 4, tags: { phase: name } };
  if (p.conversations) {
    return { ...base, preAllocatedVUs: Math.ceil(rate * 80), maxVUs: Math.ceil(rate * 110), gracefulStop: "4m" };
  }
  return base;
}

function buildScenarios() {
  if (p.ramp) {
    return { ramp: { executor: "ramping-arrival-rate", startRate: 10, timeUnit: "1s", preAllocatedVUs: 100, maxVUs: 400,
                     stages: [ { target: 100, duration: "10m" } ], tags: { phase: "ramp" } } };
  }
  const seconds = (d) => (d.endsWith("m") ? parseInt(d) * 60 : parseInt(d));
  if (p.steps) {
    const steps = {};
    p.steps.forEach((rate, index) => {
      const name = `r${String(rate).padStart(2, "0")}`;
      steps[name] = arrival(name, rate, p.stepDuration, `${index * seconds(p.stepDuration)}s`, 50);
    });
    return steps;
  }
  const scenarios = { warmup: arrival("warmup", p.warmup[0], p.warmup[1], "0s", 50) };
  let at = seconds(p.warmup[1]);
  scenarios.plateau = arrival("plateau", p.plateau[0], p.plateau[1], `${at}s`, 50);
  at += seconds(p.plateau[1]);
  if (p.burst) {
    scenarios.burst = arrival("burst", p.burst[0], p.burst[1], `${at}s`, 200);
    at += seconds(p.burst[1]);
    scenarios.recovery = arrival("recovery", p.plateau[0], "2m", `${at}s`, 50);
  }
  return scenarios;
}

// No estresse cada degrau ganha um limiar sempre verdadeiro, só para o k6 exportar a latência por degrau no resumo.
const stepThresholds = {};
(p.steps || []).forEach((rate) => { stepThresholds[`http_req_duration{phase:r${String(rate).padStart(2, "0")}}`] = [ "max>=0" ]; });

export const options = {
  scenarios: buildScenarios(),
  thresholds: {
    ...stepThresholds,
    // RNF-01: ack p95 <= 200 ms e p99 <= 500 ms; RNF-09: erros 5xx < 0,1%.
    "http_req_duration{phase:plateau}": [ "p(95)<200", "p(99)<500" ],
    "http_req_failed{phase:plateau}": [ "rate<0.001" ],
    helpdesk_rejected: [ "count==0" ],
  },
  summaryTrendStats: [ "min", "med", "p(90)", "p(95)", "p(99)", "max", "count" ],
};

function customerFor(i) {
  const n = MODE === "burst" ? i % BURST_CUSTOMERS : i;
  const phase = MODE === "burst" ? "shared" : exec.scenario.name;
  return `bench_${RUN_ID}_${SEED}_${phase}_${n}`;
}

// Pseudoaleatório reprodutível pela semente (mulberry32): a mesma SEED gera as mesmas conversas.
function random(key) {
  let t = (SEED * 1000003 + key) >>> 0;
  t = (t + 0x6d2b79f5) >>> 0;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}

const FOLLOWUPS = [
  "ainda não entendi", "pode verificar de novo?", "já faz dois dias", "obrigado", "e quanto tempo demora?",
  "o número do pedido é 48213", "isso resolve?", "certo, vou aguardar",
];

function send(customer, messageId, text) {
  const body = JSON.stringify({ message_id: messageId, account_id: `acc_${customer}`, customer_ref: `ref_${customer}`,
                                text, sent_at: new Date().toISOString() });
  const t = Math.floor(Date.now() / 1000);
  const signature = `t=${t},v1=${crypto.hmac("sha256", SECRET, `${t}.${body}`, "hex")}`;
  const res = http.post(`${PLATFORM}/webhooks/chat/${ACCOUNT}`, body, {
    headers: { "Content-Type": "application/json", "X-Helpdesk-Signature": signature },
  });
  if (res.status === 202) accepted.add(1);
  else if (res.status === 200) duplicate.add(1);
  else rejected.add(1);
  check(res, { "ack 202": (r) => r.status === 202 });
}

// Uma conversa: primeira mensagem do catálogo, depois 1 a 5 continuações com pausa de 10 a 40 s (o cliente lendo a
// resposta e digitando). Todas do mesmo cliente, então caem no mesmo atendimento.
function conversation() {
  const i = exec.scenario.iterationInTest;
  const phase = exec.scenario.name;
  const customer = `bench_${RUN_ID}_${SEED}_${phase}_${i}`;
  const key = (phase.length * 7919 + i) * 16;
  const total = 2 + Math.floor(random(key) * 5);
  send(customer, `bench_${RUN_ID}_${phase}_${i}_0`, TEXTS[i % TEXTS.length]);
  for (let m = 1; m < total; m++) {
    sleep(10 + random(key + m) * 30);
    send(customer, `bench_${RUN_ID}_${phase}_${i}_${m}`, FOLLOWUPS[Math.floor(random(key + 8 + m) * FOLLOWUPS.length)]);
  }
}

export default function () {
  if (p.conversations) return conversation();
  const i = exec.scenario.iterationInTest;
  const customer = customerFor(i);
  const body = JSON.stringify({
    message_id: `bench_${RUN_ID}_${exec.scenario.name}_${i}`, account_id: `acc_${customer}`, customer_ref: `ref_${customer}`,
    text: TEXTS[i % TEXTS.length], sent_at: new Date().toISOString(),
  });
  const t = Math.floor(Date.now() / 1000);
  const signature = `t=${t},v1=${crypto.hmac("sha256", SECRET, `${t}.${body}`, "hex")}`;
  const res = http.post(`${PLATFORM}/webhooks/chat/${ACCOUNT}`, body, {
    headers: { "Content-Type": "application/json", "X-Helpdesk-Signature": signature },
  });
  if (res.status === 202) accepted.add(1);
  else if (res.status === 200) duplicate.add(1);
  else rejected.add(1);
  check(res, { "ack 202": (r) => r.status === 202 });
}

export function handleSummary(data) {
  const out = __ENV.SUMMARY_FILE || `/results/${RUN_ID}-k6.json`;
  return { [out]: JSON.stringify({ run_id: RUN_ID, profile: PROFILE, mode: MODE, seed: SEED, metrics: data.metrics }, null, 2) };
}
