# Diagnóstico das falhas da rodada de 24/11: atualiza o lock (gem redis), reconstrói as imagens e roda só os testes
# que falharam, gravando a saída completa de cada um em bench/results/diagnostico/ (UTF-8).
#   .\bench\diagnostico.ps1
$ErrorActionPreference = "Continue"
$dir = "bench/results/diagnostico"
New-Item -ItemType Directory -Force $dir | Out-Null
Remove-Item "$dir/*" -ErrorAction SilentlyContinue
$env:COMPOSE_PARALLEL_LIMIT = 2
function Rodar($nome, [scriptblock]$bloco) {
  Write-Host "== $nome ==" -ForegroundColor Cyan
  & $bloco 2>&1 | ForEach-Object { "$_" } | ForEach-Object { $_ | Out-File -FilePath "$dir/$nome.log" -Append -Encoding utf8 }
  "exit=$LASTEXITCODE" | Out-File -FilePath "$dir/$nome.log" -Append -Encoding utf8
  Write-Host "   exit=$LASTEXITCODE  ($dir/$nome.log)"
}
Rodar "00-lock-gem-redis"   { docker compose run --rm --no-deps web bundle lock }
Rodar "01-build"            { docker compose -f docker-compose.yml -f docker-compose.fast.yml up -d --build --wait }
Rodar "02-contratos"        { docker run --rm -v "${PWD}/src/contracts:/contracts" -w /contracts ruby:4.0.10-slim sh -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential >/dev/null && bundle install --quiet && bundle exec rspec" }
Rodar "03-agente"           { docker compose run --rm --no-deps agent-mock bundle exec rspec }
Rodar "04-canais"           { docker compose run --rm --no-deps channels-mock bundle exec rspec }
Rodar "05-plataforma"       { docker compose run --rm -v "${PWD}/bench:/bench:ro" -e RAILS_ENV=test web sh -c "bin/rails db:prepare && bundle exec rspec" }
Write-Host "Pronto. Avise o Claude: ele lê os arquivos em $dir."
