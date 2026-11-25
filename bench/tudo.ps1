# Roda tudo de uma vez, com o agente simulado (Gemini desligado): testes, qualidade, falhas, negócio simulado e telas.
# Uso, na raiz do projeto:
#   .\bench\tudo.ps1                 # tudo
#   .\bench\tudo.ps1 -SemTestes      # só carga, falhas e telas (os testes já passaram)
#   .\bench\tudo.ps1 -SemCarga       # só testes e qualidade
# Não para no primeiro erro: no fim lista o que falhou. O log completo fica em bench/results/tudo-<data>.log.
param([switch]$SemTestes, [switch]$SemCarga)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force bench/results | Out-Null
$stamp = Get-Date -Format yyyyMMdd-HHmm
$log = "bench/results/tudo-$stamp.log"
$passos = "bench/results/tudo-$stamp-passos"
New-Item -ItemType Directory -Force $passos | Out-Null
Start-Transcript -Path $log | Out-Null
$falhas = @()
$inicio = Get-Date
$contador = 0
function Passo($nome, [scriptblock]$bloco) {
  $script:contador++
  $arq = "$passos/{0:00}-{1}.log" -f $script:contador, (($nome -replace '[^A-Za-z0-9]+','-').Trim('-'))
  Write-Host "`n===== $nome =====" -ForegroundColor Cyan
  $global:LASTEXITCODE = 0
  # A saída completa de cada passo vai para um arquivo próprio em UTF-8 (a transcrição do PowerShell não a guarda).
  & $bloco 2>&1 | ForEach-Object { "$_" } | ForEach-Object { $_ | Out-File -FilePath $arq -Append -Encoding utf8; $_ }
  if ($LASTEXITCODE -ne 0) { $script:falhas += $nome; Write-Host "FALHOU: $nome (código $LASTEXITCODE)" -ForegroundColor Red }
  else { Write-Host "ok: $nome" -ForegroundColor Green }
}
$env:AGENT_ENGINE = "rules"   # Gemini desligado nesta rodada

if (-not $SemTestes) {
  Passo "Ambiente de desenvolvimento" { docker compose -f docker-compose.yml -f docker-compose.fast.yml up -d --build --wait }
  Passo "RSpec da plataforma" { docker compose run --rm -v "${PWD}/bench:/bench:ro" -e RAILS_ENV=test web sh -c "bin/rails db:prepare && bundle exec rspec" }
  Passo "RSpec dos contratos" { docker run --rm -v "${PWD}/src/contracts:/contracts" -w /contracts ruby:4.0.10-slim sh -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential >/dev/null && bundle install --quiet && bundle exec rspec" }
  Passo "RSpec do broker" { docker compose run --rm --no-deps broker bundle exec rspec }
  Passo "RSpec do agente (inclui o motor Gemini com cliente falso)" { docker compose run --rm --no-deps agent-mock bundle exec rspec }
  Passo "RSpec dos canais simulados" { docker compose run --rm --no-deps channels-mock bundle exec rspec }
  Passo "RuboCop da plataforma" { docker compose run --rm web bundle exec rubocop }
  Passo "RuboCop do broker" { docker compose run --rm --no-deps broker bundle exec rubocop }
  Passo "RuboCop do agente" { docker compose run --rm --no-deps agent-mock bundle exec rubocop }
  Passo "RuboCop dos canais" { docker compose run --rm --no-deps channels-mock bundle exec rubocop }
  Passo "Brakeman" { docker compose run --rm web bundle exec brakeman -q --no-pager }
  $revisao = (git rev-parse HEAD)
  New-Item -ItemType Directory -Force bench/results/operation | Out-Null
  Passo "Validação de operação (E2, E3, E4, E6)" { docker compose run --rm --no-deps -v "${PWD}/bench:/bench:ro" -v "${PWD}/bench/results/operation:/results" -e RAILS_ENV=test -e TEST_ENV_NUMBER=_operation -e "VALIDATION_REVISION=$revisao" -e DATABASE_CLEANER_ALLOW_REMOTE_DATABASE_URL=true web sh -c "bin/rails db:prepare && ruby /bench/validation/run.rb /results" }
  Passo "Desliga o desenvolvimento (libera memória para o perfil de produção)" { docker compose down }
}

if (-not $SemCarga) {
  $chaos = @("-p","helpdesk-bench","-f","docker-compose.yml","-f","docker-compose.bench.yml","-f","docker-compose.realistic.yml")
  Passo "Perfil de produção com agente realista" { docker compose @chaos up -d --build --wait }
  Passo "Banco do experimento" { docker compose @chaos run --rm web bin/rails db:prepare; docker compose @chaos run --rm web bin/rails db:seed }
  foreach ($c in "kafka","agente-mudo","postgres-latencia","redis-corte") {
    Passo "Falha: $c" { & "$PSScriptRoot/chaos/run.ps1" -Cenario $c -DuracaoFalhaSeg 30 }
  }
  Passo "Negócio simulado (carga, observabilidade, banco e telas)" { & "$PSScriptRoot/negocio/run.ps1" }
}

Stop-Transcript | Out-Null
$min = [int]((Get-Date) - $inicio).TotalMinutes
Write-Host "`n===== RESUMO ($min min) =====" -ForegroundColor Cyan
if ($falhas.Count -eq 0) { Write-Host "Tudo passou." -ForegroundColor Green }
else { Write-Host "Falharam:" -ForegroundColor Red; $falhas | ForEach-Object { Write-Host " - $_" } }
Write-Host "Log: $log   Resultados: bench/results/   Grafana (durante o negócio): http://localhost:3101"
