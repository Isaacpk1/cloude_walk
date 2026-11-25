# Specs das mudanças dos jobs (ADR-032) e, se passarem, o teste realista (~35 min no total).
#   powershell -ExecutionPolicy Bypass -File .\bench\fila-jobs.ps1
$ErrorActionPreference = "Continue"
$dir = "bench/results/$(Get-Date -Format yyyy-MM-dd)-realista"
New-Item -ItemType Directory -Force $dir | Out-Null
Write-Host "== 1/2 specs (jobs, consumer, prazos, concorrência) =="
docker compose -p helpdesk-bench down -v --remove-orphans 2>&1 | Out-Null
docker compose run --rm -e RAILS_ENV=test web bundle exec rspec spec/jobs spec/consumers spec/concurrency spec/services/deadlines spec/services/agent_actions spec/services/turns spec/services/ingestion spec/read_models 2>&1 |
  Out-File -Encoding utf8 "$dir/specs-adr032.txt"
$resumo = Select-String -Path "$dir/specs-adr032.txt" -Pattern "examples,"
Write-Host $resumo.Line
if ($resumo.Line -notmatch " 0 failures") { Write-Host "ABORTADO: specs com falha. Veja $dir/specs-adr032.txt"; exit 1 }
Write-Host "== 2/2 realista: 8 workers x 2 threads, 4 consumidores =="
docker compose -p helpdesk-bench down -v --remove-orphans 2>&1 | Out-Null
powershell -ExecutionPolicy Bypass -File .\bench\pico.ps1 -Ajustado -Perfil realista
Write-Host "Pronto. Me avise."
