# Specs do controle de admissão (ADR-035) e das mudanças anteriores e, se passarem, o teste realista (~35 min).
#   powershell -ExecutionPolicy Bypass -File .\bench\fila-admissao.ps1
$ErrorActionPreference = "Continue"
$dir = "bench/results/$(Get-Date -Format yyyy-MM-dd)-realista"
New-Item -ItemType Directory -Force $dir | Out-Null
Write-Host "== 1/2 specs =="
docker compose -p helpdesk-bench down -v --remove-orphans 2>&1 | Out-Null
docker compose run --rm -e RAILS_ENV=test web bundle exec rspec spec/services/outbox spec/services/handoff spec/jobs spec/consumers spec/concurrency spec/services/deadlines spec/services/agent_actions spec/read_models 2>&1 |
  Out-File -Encoding utf8 "$dir/specs-adr035.txt"
$resumo = Select-String -Path "$dir/specs-adr035.txt" -Pattern "examples,"
Write-Host $resumo.Line
if ($resumo.Line -notmatch " 0 failures") { Write-Host "ABORTADO: specs com falha. Veja $dir/specs-adr035.txt"; exit 1 }
Write-Host "== 2/2 realista com admissão (48 no agente), Puma em cluster e 192 partições =="
docker compose -p helpdesk-bench down -v --remove-orphans 2>&1 | Out-Null
powershell -ExecutionPolicy Bypass -File .\bench\pico.ps1 -Ajustado -Perfil realista
Write-Host "Pronto. Me avise."
