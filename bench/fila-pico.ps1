# Fila única (~35 min): specs de concorrência e depois o pico em duas configurações (ADR-031).
#   powershell -ExecutionPolicy Bypass -File .\bench\fila-pico.ps1
# Para na primeira falha dos specs: não faz sentido medir o pico com testes quebrados.
$ErrorActionPreference = "Continue"
$dir = "bench/results/$(Get-Date -Format yyyy-MM-dd)-pico"
New-Item -ItemType Directory -Force $dir | Out-Null
$marca = "$dir/ORDEM-$(Get-Date -Format HHmmss).txt"

Write-Host "== 1/3 specs =="
docker compose -p helpdesk-bench down -v --remove-orphans 2>&1 | Out-Null
docker compose run --rm -e RAILS_ENV=test web bundle exec rspec spec/concurrency spec/services/turns spec/services/triage spec/services/deadlines spec/services/outbox 2>&1 |
  Out-File -Encoding utf8 "$dir/specs-adr031.txt"
$resumo = Select-String -Path "$dir/specs-adr031.txt" -Pattern "examples,"
Write-Host $resumo.Line
if ($resumo.Line -notmatch " 0 failures") { Write-Host "ABORTADO: specs com falha. Veja $dir/specs-adr031.txt"; exit 1 }

foreach ($cfg in @(@{W=4;T=8}, @{W=8;T=2})) {
  Write-Host "== pico: $($cfg.W) workers x $($cfg.T) threads =="
  Add-Content $marca "$(Get-Date -Format HH:mm:ss) inicio workers=$($cfg.W) threads=$($cfg.T)"
  docker compose -p helpdesk-bench down -v --remove-orphans 2>&1 | Out-Null
  powershell -ExecutionPolicy Bypass -File .\bench\pico.ps1 -Ajustado -Workers $cfg.W -Threads $cfg.T
  Add-Content $marca "$(Get-Date -Format HH:mm:ss) fim workers=$($cfg.W) threads=$($cfg.T)"
}
Write-Host "Pronto. Ordem das configurações em $marca. Me avise."
