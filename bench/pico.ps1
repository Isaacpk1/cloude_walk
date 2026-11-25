# Diagnóstico curto do pico (~6 min): sobe a carga "pico" e, ao lado, amostra os bloqueios do Postgres a cada 2 s.
#   .\bench\pico.ps1            (agente e capacidade como no negocio; -Ajustado liga docker-compose.tuned.yml)
param([switch]$Ajustado, [int]$Workers = 8, [int]$Threads = 2, [int]$Consumidores = 4, [string]$Perfil = "pico")
$ErrorActionPreference = "Continue"
$files = @("-p","helpdesk-bench","-f","docker-compose.yml","-f","docker-compose.bench.yml","-f","docker-compose.realistic.yml",
           "-f","docker-compose.observability.yml","-f","docker-compose.dbprofile.yml")
if ($Ajustado) { $files += @("-f","docker-compose.tuned.yml") }
$files += @("-f","docker-compose.scale.yml")
# -Threads: threads de job por processo do worker (o pool do banco leva +2). Poucas threads por processo evitam que quem
# segura o lock do atendimento fique parado esperando a vez no GVL.
$env:WORKER_THREADS = "$Threads"; $env:WORKER_DB_POOL = "$($Threads + 2)"
# O estresse dura ~8 min (o pico ~4): os amostradores precisam cobrir a carga e os 2 min de espera.
# Os amostradores cobrem a carga e os 2 min de espera: pico ~4 min, estresse ~8, realista ~13 (com PLATEAU=5m).
$minutos = @{ pico = 6; estresse = 10; realista = 16 }[$Perfil]; if (-not $minutos) { $minutos = 10 }
$voltasLocks = [int]($minutos * 25); $voltasCpu = [int]($minutos * 14)
function DC { docker compose @files @args }
function DCIn { $input | docker compose @files @args }
$dir = "bench/results/$(Get-Date -Format yyyy-MM-dd)-$Perfil"
New-Item -ItemType Directory -Force $dir | Out-Null
$run = "$(Get-Date -Format yyyyMMddHHmmss)-$Perfil"

# Um serviço de observabilidade que falha (porta ocupada, por exemplo) não pode derrubar o resto: sem agent-mock e consumer
# o teste mede só a ingestão e todo turno expira. Por isso: sobe, completa o que faltar e CONFERE antes de disparar a carga.
DC up -d --build --scale worker=$Workers --scale consumer=$Consumidores
$essenciais = @("postgres","redis","kafka","web","worker","scheduler","consumer","agent-mock","channels-mock")
DC up -d --scale worker=$Workers --scale consumer=$Consumidores $essenciais
Write-Host "Aguardando os serviços essenciais ficarem prontos (até 3 min)..."
$limite = (Get-Date).AddMinutes(3)
do {
  Start-Sleep -Seconds 5
  $rodando = @(DC ps --services --filter status=running)
  $faltam = @($essenciais | Where-Object { $_ -notin $rodando })
} while ($faltam.Count -gt 0 -and (Get-Date) -lt $limite)
if ($faltam.Count -gt 0) { Write-Host "ABORTADO: não estão rodando: $($faltam -join ', '). O resultado seria inválido (sem agente = 0 respostas)."; DC ps; exit 1 }
Write-Host "OK: todos os serviços essenciais rodando."
Get-Content bench/db/enable.sql | DCIn exec -T postgres psql -U helpdesk -d helpdesk_benchmark | Out-Null
$net = (DC ps -q web | ForEach-Object { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' $_ })
$amostrador = Start-Job -ArgumentList $files, "$PWD", "$dir/$run-locks.txt", $voltasLocks -ScriptBlock {
  param($files, $cwd, $saida, $voltas)
  Set-Location $cwd
  1..$voltas | ForEach-Object {
    Get-Content bench/db/locks.sql | docker compose @files exec -T postgres psql -U helpdesk -d helpdesk_benchmark | Out-File -Append -Encoding utf8 $saida
    Start-Sleep -Seconds 2
  }
}
$stats = Start-Job -ArgumentList "$PWD", "$dir/$run-cpu.txt", $voltasCpu -ScriptBlock {
  param($cwd, $saida, $voltas)
  Set-Location $cwd
  1..$voltas | ForEach-Object {
    docker stats --no-stream --format "{{.Name}};{{.CPUPerc}};{{.MemUsage}}" | Where-Object { $_ -like "helpdesk-bench-*" } | Out-File -Append -Encoding utf8 $saida
    Start-Sleep -Seconds 3
  }
}
Write-Host "== carga (perfil $Perfil) =="
docker run --rm --network $net -v "${PWD}/bench/k6:/scripts:ro" -v "${PWD}/${dir}:/results" `
  -e PLATFORM_URL=http://web:3000 -e PROFILE=$Perfil -e PLATEAU=$env:PLATEAU -e MODE=independent -e SEED=42 -e RUN_ID=$run grafana/k6:0.54.0 run /scripts/chat_load.js
Write-Host "== 2 min para a fila andar =="
Start-Sleep -Seconds 120
Stop-Job $amostrador, $stats; Remove-Job $amostrador, $stats -Force
Get-Content bench/db/pendentes.sql | DCIn exec -T postgres psql -U helpdesk -d helpdesk_benchmark | Out-File -Encoding utf8 "$dir/$run-pendentes.txt"
Get-Content "$dir/$run-pendentes.txt" -Encoding utf8
DC run --rm -T -v "${PWD}/bench:/bench:ro" -v "${PWD}/${dir}:/results" web bin/rails runner /bench/analysis/reconcile.rb $run /results/$run-k6.json | Out-File -Encoding utf8 "$dir/$run-db.json"
DC logs --tail 60 worker consumer scheduler agent-mock 2>&1 | Out-File -Encoding utf8 "$dir/$run-logs.txt"
# Onde está o gargalo: consultas pesadas, fila do Kafka e latência real do agente
Get-Content bench/db/slow_queries.sql | DCIn exec -T postgres psql -U helpdesk -d helpdesk_benchmark | Out-File -Encoding utf8 "$dir/$run-consultas.txt"
DC exec -T kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups 2>&1 | Out-File -Encoding utf8 "$dir/$run-kafka-lag.txt"
Get-Content bench/db/turnos_por_minuto.sql | DCIn exec -T postgres psql -U helpdesk -d helpdesk_benchmark | Out-File -Encoding utf8 "$dir/$run-turnos.txt"
Write-Host "Evidências em $dir"
