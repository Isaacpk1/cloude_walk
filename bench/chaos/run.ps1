# Injeta uma falha durante a carga e confere que nada se perdeu (E2; ADR-029). Roda no perfil de produção.
#   .\bench\chaos\run.ps1 -Cenario kafka -DuracaoFalhaSeg 30
# Cenários: kafka (pausa o Kafka), postgres-latencia (+300 ms entre a plataforma e o Postgres),
#           redis-corte (derruba as conexões do Redis), agente-mudo (para o agente).
param(
  [ValidateSet("kafka","postgres-latencia","redis-corte","agente-mudo")][string]$Cenario = "kafka",
  [int]$DuracaoFalhaSeg = 30
)
# "Continue": o k6 escreve avisos e o resultado dos limites em stderr, e isso não pode abortar o roteiro.
$ErrorActionPreference = "Continue"
# O Toxiproxy só entra nos cenários de Postgres e Redis. Nos demais a plataforma fala direto com as dependências,
# para a latência do ack não carregar o salto extra do proxy.
$files = @("-p","helpdesk-bench","-f","docker-compose.yml","-f","docker-compose.bench.yml","-f","docker-compose.realistic.yml")
if ($Cenario -in "postgres-latencia","redis-corte") { $files += @("-f","docker-compose.chaos.yml") }
function DC { docker compose @files @args }
function Toxic { DC exec -T toxiproxy /toxiproxy-cli @args }

DC up -d --wait
$net = (DC ps -q web | ForEach-Object { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' $_ })
$run = "$(Get-Date -Format yyyyMMddHHmmss)-chaos"
$dir = "bench/results/$(Get-Date -Format yyyy-MM-dd)-chaos-$Cenario"
New-Item -ItemType Directory -Force $dir | Out-Null
$k6 = "k6-$run"

Write-Host "== carga (perfil caos: 5 msg/s por 3 min) =="
docker run -d --name $k6 --network $net -v "${PWD}/bench/k6:/scripts:ro" -v "${PWD}/${dir}:/results" `
  -e PLATFORM_URL=http://web:3000 -e PROFILE=caos -e MODE=independent -e SEED=42 -e RUN_ID=$run grafana/k6:0.54.0 run /scripts/chat_load.js | Out-Null
Start-Sleep -Seconds 40

Write-Host "== falha: $Cenario por $DuracaoFalhaSeg s =="
switch ($Cenario) {
  "kafka"             { DC pause kafka;  Start-Sleep -Seconds $DuracaoFalhaSeg; DC unpause kafka }
  "agente-mudo"       { DC stop agent-mock; Start-Sleep -Seconds $DuracaoFalhaSeg; DC start agent-mock }
  "postgres-latencia" { Toxic toxic add -t latency -a latency=300 -n lat postgres; Start-Sleep -Seconds $DuracaoFalhaSeg; Toxic toxic remove -n lat postgres }
  "redis-corte"       { Toxic toggle redis; Start-Sleep -Seconds $DuracaoFalhaSeg; Toxic toggle redis }
}
Write-Host "== falha encerrada; esperando o fim da carga =="
docker wait $k6 | Out-Null
$logfile = ("$dir/$run-k6.log").Replace("/", "\")
cmd /c "docker logs $k6 > `"$logfile`" 2>&1"
docker rm $k6 | Out-Null

Write-Host "== esperando a fila esvaziar (120 s) =="
Start-Sleep -Seconds 120
DC run --rm -T -v "${PWD}/bench:/bench:ro" -v "${PWD}/${dir}:/results" web bin/rails runner /bench/analysis/reconcile.rb $run /results/$run-k6.json | Out-File -Encoding utf8 "$dir/$run-db.json"
Get-Content "$dir/$run-db.json" -Encoding utf8
Write-Host "Evidência em $dir. Esperado: mensagens perdidas = 0 e outbox pendente = 0."
