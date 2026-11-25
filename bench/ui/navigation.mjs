// Mede a navegação real do painel num navegador (RNF-32; ADR-029): tempo de troca de tela pelo menu (Turbo),
// carga completa com TTFB e LCP, e CLS. Saída em JSON. Uso (ver bench/ui/run.ps1):
//   BASE_URL=http://web:3000 EMAIL=... PASSWORD=... REPS=10 node ui/navigation.mjs /results/ui.json
import { chromium } from "playwright";
import { writeFileSync } from "node:fs";

const BASE = process.env.BASE_URL || "http://localhost:3300";
const EMAIL = process.env.EMAIL || "supervisora@helpdesk.test";
const PASSWORD = process.env.PASSWORD || "senha-sintetica-1";
const REPS = parseInt(process.env.REPS || "10", 10);
const OUT = process.argv[2] || "ui-result.json";
const MENU = [
  { name: "Conversas", href: "/conversas" }, { name: "Linha do tempo", href: "/linha-do-tempo" },
  { name: "Fila humana", href: "/fila" }, { name: "Qualidade da IA", href: "/evals" },
  { name: "Falhas", href: "/dlq" }, { name: "Configuração", href: "/configuracao" },
];

const pct = (values, q) => { const s = [...values].sort((a, b) => a - b); return s.length ? s[Math.max(Math.ceil(q * s.length) - 1, 0)] : null; };
const stats = (values) => ({ n: values.length, p50: pct(values, 0.5), p95: pct(values, 0.95), max: Math.max(...values) });

const browser = await chromium.launch();
const page = await (await browser.newContext()).newPage();
await page.goto(`${BASE}/entrar`);
await page.fill('input[name="email"]', EMAIL);
await page.fill('input[name="password"]', PASSWORD);
await Promise.all([page.waitForURL((url) => !url.pathname.startsWith("/entrar")), page.click('input[type="submit"]')]);

await page.addInitScript(() => {
  window.__vitals = { lcp: 0, cls: 0 };
  new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__vitals.lcp = e.startTime; }).observe({ type: "largest-contentful-paint", buffered: true });
  new PerformanceObserver((l) => { for (const e of l.getEntries()) if (!e.hadRecentInput) window.__vitals.cls += e.value; }).observe({ type: "layout-shift", buffered: true });
});

const result = { base: BASE, reps: REPS, started_at: new Date().toISOString(), pages: {} };
for (const item of MENU) {
  const turbo = [], full = [], ttfb = [], lcp = [], cls = [];
  for (let i = 0; i < REPS; i++) {
    // Troca de tela pelo menu (Turbo): do clique até o conteúdo novo estar no documento.
    await page.goto(`${BASE}/conversas`, { waitUntil: "load" });
    const link = page.locator(`nav.nav a[href="${item.href}"]`).first();
    if (!(await link.count())) { result.pages[item.name] = { error: "link do menu não encontrado (perfil sem acesso?)" }; break; }
    const t0 = Date.now();
    await link.click();
    await page.waitForURL(`**${item.href}*`);
    await page.waitForLoadState("domcontentloaded");
    turbo.push(Date.now() - t0);

    // Carga completa da página, com TTFB, LCP e CLS.
    const t1 = Date.now();
    await page.goto(`${BASE}${item.href}`, { waitUntil: "load" });
    full.push(Date.now() - t1);
    await page.waitForTimeout(300);
    const m = await page.evaluate(() => ({ ttfb: performance.getEntriesByType("navigation")[0].responseStart, ...window.__vitals }));
    ttfb.push(m.ttfb); lcp.push(m.lcp); cls.push(m.cls);
  }
  if (!result.pages[item.name]) {
    result.pages[item.name] = { troca_de_tela_ms: stats(turbo), carga_completa_ms: stats(full), ttfb_ms: stats(ttfb), lcp_ms: stats(lcp), cls: stats(cls),
      // RNF-32: LCP <= 2,5 s. Mede em ambiente local, sem rede: serve para comparar, não como Web Vitals de campo.
      lcp_ok: pct(lcp, 0.75) <= 2500 };
  }
}
result.finished_at = new Date().toISOString();
writeFileSync(OUT, JSON.stringify(result, null, 2));
console.log(JSON.stringify(Object.fromEntries(Object.entries(result.pages).map(([k, v]) => [k, v.error || { troca_p95_ms: v.troca_de_tela_ms.p95, lcp_p75_ok: v.lcp_ok, ttfb_p95_ms: v.ttfb_ms.p95 }])), null, 2));
await browser.close();
