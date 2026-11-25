// RNF-14/RNF-30: executa o gerador real com as fronteiras do k6 simuladas; não envia tráfego.
import { readFileSync } from "node:fs";
import { Script, createContext } from "node:vm";
import { test } from "node:test";
import assert from "node:assert/strict";

function generator(mode, runId) {
  const sent = [];
  const context = createContext({
    __ENV: { MODE: mode, RUN_ID: runId },
    http: { post: (_url, body) => { sent.push(JSON.parse(body)); return { status: 202 }; } },
    crypto: { hmac: () => "signature" }, check: () => {},
    Counter: class { add() {} },
    exec: { scenario: { name: "warmup", iterationInTest: 0 } },
  });
  const source = readFileSync(new URL("./chat_load.js", import.meta.url), "utf8")
    .replace(/^import .*;\r?\n/gm, "")
    .replace("export const options", "const options")
    .replace("export default function ()", "function sendMessage()")
    .replace("export function handleSummary", "function handleSummary");
  new Script(source).runInContext(context);
  return { sent, send(phase, iteration = 0) {
    context.exec.scenario = { name: phase, iterationInTest: iteration };
    new Script("sendMessage()").runInContext(context);
  } };
}

test("RNF-14: duas fases não reutilizam o mesmo message_id", () => {
  const g = generator("independent", "run1");
  g.send("warmup"); g.send("plateau");
  assert.equal(new Set(g.sent.map(x => x.message_id)).size, 2);
});

test("RNF-30: conversas independentes são distintas entre fases e execuções", () => {
  const a = generator("independent", "run1");
  const b = generator("independent", "run2");
  for (const g of [a, b]) { g.send("warmup"); g.send("plateau"); }
  assert.equal(new Set([...a.sent, ...b.sent].map(x => x.account_id)).size, 4);
});

test("RN-55: burst reutiliza cliente entre fases, mas isola execuções", () => {
  const a = generator("burst", "run1"); const b = generator("burst", "run2");
  a.send("warmup"); a.send("plateau"); b.send("warmup");
  assert.equal(a.sent[0].account_id, a.sent[1].account_id);
  assert.notEqual(a.sent[0].account_id, b.sent[0].account_id);
});
