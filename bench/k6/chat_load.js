// Experimentos E1 e E5 (docs/05, seção 2): carga no webhook do chat em modelo aberto (constant-arrival-rate), que não
// sofre de coordinated omission. Cada requisição é assinada como o provedor (X-Helpdesk-Signature, ADR-019).
//
// Perfis (PROFILE):
//   smoke       30 s a 5 msg/s. Só confere que o roteiro funciona.
//   reference   aquecimento 5 min, patamar de 30 min a 20 msg/s, rajada de 60 s a 100 msg/s e volta ao patamar (E1).
//   capacity    rampa de 10 a 100 msg/s em 10 min, para achar o ponto de saturação (E1, E5).
// Formato da carga (MODE, E5):
//   independent muitas conversas: cada mensagem de um cliente diferente.
//   burst       rajadas na mesma conversa: as mensagens se repartem entre poucos clientes (BURST_CUSTOMERS).
import http from "k6/http";
import crypto from "k6/crypto";
import { check } from "k6";
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
};
const p = profiles[PROFILE];
if (!p) throw new Error(`PROFILE desconhecido: ${PROFILE}`);

function arrival(name, rate, duration, startTime, vus) {
  return { executor: "constant-arrival-rate", rate, timeUnit: "1s", duration, startTime, preAllocatedVUs: vus, maxVUs: vus * 4, tags: { phase: name } };
}

function buildScenarios() {
  if (p.ramp) {
    return { ramp: { executor: "ramping-arrival-rate", startRate: 10, timeUnit: "1s", preAllocatedVUs: 100, maxVUs: 400,
                     stages: [ { target: 100, duration: "10m" } ], tags: { phase: "ramp" } } };
  }
  const seconds = (d) => (d.endsWith("m") ? parseInt(d) * 60 : parseInt(d));
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

export const options = {
  scenarios: buildScenarios(),
  thresholds: {
    // RNF-01: ack p95 <= 200 ms e p99 <= 500 ms; RNF-09: erros 5xx < 0,1%.
    "http_req_duration{phase:plateau}": [ "p(95)<200", "p(99)<500" ],
    "http_req_failed{phase:plateau}": [ "rate<0.001" ],
    helpdesk_rejected: [ "count==0" ],
  },
  summaryTrendStats: [ "min", "med", "p(90)", "p(95)", "p(99)", "max", "count" ],
};

function customerFor(i) {
  const n = MODE === "burst" ? i % BURST_CUSTOMERS : i;
  return `bench_${SEED}_${n}`;
}

export default function () {
  const i = exec.scenario.iterationInTest;
  const customer = customerFor(i);
  const body = JSON.stringify({
    message_id: `bench_${RUN_ID}_${i}`, account_id: `acc_${customer}`, customer_ref: `ref_${customer}`,
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
