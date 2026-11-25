# Lighthouse numa página do painel já autenticada: pega o cookie de sessão pelo login e o repassa (ADR-029).
# Uso: .\bench\ui\lighthouse.ps1 -Path /conversas
param([string]$Path = "/conversas", [string]$Email = "supervisora@helpdesk.test", [string]$Password = "senha-sintetica-1")
$ErrorActionPreference = "Continue"
$B = @("-p","helpdesk-bench","-f","docker-compose.yml","-f","docker-compose.bench.yml")
$net = (docker compose @B ps -q web | ForEach-Object { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' $_ })
$dir = "bench/results/$(Get-Date -Format yyyy-MM-dd)-ui"
New-Item -ItemType Directory -Force $dir | Out-Null
docker run --rm --network $net --ipc=host -v "${PWD}/${dir}:/results" -e EMAIL=$Email -e PASSWORD=$Password -e TARGET="http://web:3000$Path" `
  mcr.microsoft.com/playwright:v1.49.1-noble sh -c @"
set -e; cd /tmp && npm i --silent playwright@1.49.1 lighthouse@12 >/dev/null
cat > run.mjs <<'JS'
import { chromium } from 'playwright'; import lighthouse from 'lighthouse'; import { writeFileSync } from 'node:fs';
const b = await chromium.launch({ args: ['--remote-debugging-port=9222'] });
const p = await (await b.newContext()).newPage();
await p.goto('http://web:3000/entrar'); await p.fill('input[name=email]', process.env.EMAIL); await p.fill('input[name=password]', process.env.PASSWORD);
await Promise.all([p.waitForURL(u => !u.pathname.startsWith('/entrar')), p.click('input[type=submit]')]);
const r = await lighthouse(process.env.TARGET, { port: 9222, output: 'json', onlyCategories: ['performance','accessibility'], disableStorageReset: true });
writeFileSync('/results/lighthouse.json', r.report);
const a = r.lhr.audits; console.log(JSON.stringify({ desempenho: r.lhr.categories.performance.score, acessibilidade: r.lhr.categories.accessibility.score, lcp_ms: a['largest-contentful-paint'].numericValue, cls: a['cumulative-layout-shift'].numericValue, tbt_ms: a['total-blocking-time'].numericValue }, null, 2));
await b.close();
JS
node run.mjs
"@
