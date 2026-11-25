# Mede a navegação do painel no perfil de produção (porta 3300 do host; dentro da rede, http://web:3000).
#   .\bench\ui\run.ps1            (REPS=10)       .\bench\ui\run.ps1 -Reps 20
param([int]$Reps = 10, [string]$Email = "supervisora@helpdesk.test", [string]$Password = "senha-sintetica-1")
$ErrorActionPreference = "Continue"
$B = @("-p","helpdesk-bench","-f","docker-compose.yml","-f","docker-compose.bench.yml")
$net = (docker compose @B ps -q web | ForEach-Object { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' $_ })
$dir = "bench/results/$(Get-Date -Format yyyy-MM-dd)-ui"
New-Item -ItemType Directory -Force $dir | Out-Null
$out = "ui-$(Get-Date -Format HHmmss).json"
docker run --rm --network $net --ipc=host -v "${PWD}/bench:/work" -v "${PWD}/${dir}:/results" -w /work `
  -e BASE_URL=http://web:3000 -e EMAIL=$Email -e PASSWORD=$Password -e REPS=$Reps `
  mcr.microsoft.com/playwright:v1.49.1-noble sh -c "npm i --no-save --silent playwright@1.49.1 && node ui/navigation.mjs /results/$out"
Write-Host "Resultado em $dir/$out"
