# Negócio simulado de ponta a ponta (ADR-029): agente com latência e falhas realistas, carga de uma operação média
# com um pico, observabilidade ligada, consultas lentas do banco e navegação do painel medida.
#   .\bench\negocio\run.ps1            (~16 min: 1 min de aquecimento, 10 min de patamar, 1 min de pico, 2 min de recuperação)
param([switch]$Ajustado)
$ErrorActionPreference = "Continue"
$files = @("-p","helpdesk-bench","-f","docker-compose.yml","-f","docker-compose.bench.yml","-f","docker-compose.realistic.yml",
           "-f","docker-compose.observability.yml","-f","docker-compose.dbprofile.yml")
if ($Ajustado) { $files += @("-f","docker-compose.tuned.yml") }
$sufixo = if ($Ajustado) { "negocio-ajustado" } else { "negocio" }
function DC { docker compose @files @args }
# Entrada por pipe só chega ao programa externo se a função a repassar ($input); sem isso o psql espera o teclado.
function DCIn { $input | docker compose @files @args }

DC up -d --build --wait
DC run --rm web bin/rails db:prepare
DC run --rm web bin/rails db:seed
Get-Content bench/db/enable.sql | DCIn exec -T postgres psql -U helpdesk -d helpdesk_benchmark

$net = (DC ps -q web | ForEach-Object { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' $_ })
$run = "$(Get-Date -Format yyyyMMddHHmmss)-$sufixo"
$dir = "bench/results/$(Get-Date -Format yyyy-MM-dd)-$sufixo"
New-Item -ItemType Directory -Force $dir | Out-Null
Write-Host "Grafana: http://localhost:3001  (painel 'Help desk: sinais de ouro')"

Write-Host "== carga =="
docker run --rm --network $net -v "${PWD}/bench/k6:/scripts:ro" -v "${PWD}/${dir}:/results" `
  -e PLATFORM_URL=http://web:3000 -e PROFILE=negocio -e MODE=independent -e SEED=42 -e RUN_ID=$run grafana/k6:0.54.0 run /scripts/chat_load.js
Write-Host "== esperando a fila esvaziar (5 min, meta da RNF-10) =="
Start-Sleep -Seconds 300

Write-Host "== reconciliação =="
DC run --rm -T -v "${PWD}/bench:/bench:ro" -v "${PWD}/${dir}:/results" web bin/rails runner /bench/analysis/reconcile.rb $run /results/$run-k6.json | Out-File -Encoding utf8 "$dir/$run-db.json"
Get-Content "$dir/$run-db.json" -Encoding utf8
Write-Host "== consultas lentas do banco =="
Get-Content bench/db/slow_queries.sql | DCIn exec -T postgres psql -U helpdesk -d helpdesk_benchmark | Out-File -Encoding utf8 "$dir/$run-sql.txt"
Get-Content "$dir/$run-sql.txt" -Encoding utf8
Write-Host "== navegação do painel =="
& "$PSScriptRoot/../ui/run.ps1"
Write-Host "Evidências em $dir"
