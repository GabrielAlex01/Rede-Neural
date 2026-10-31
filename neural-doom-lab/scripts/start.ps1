param(
    [ValidateSet('Docker', 'Windows')][string]$Mode = 'Windows',
    [ValidateSet('127.0.0.1', '0.0.0.0')][string]$BindAddress = '127.0.0.1'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $projectRoot
try {
    if ($Mode -eq 'Docker') {
        if (-not (Test-Path -LiteralPath '.env')) { throw 'Arquivo local .env ausente. Execute scripts/setup.ps1 -Mode Docker.' }
        & docker compose -f compose.yaml up -d mysql
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao iniciar o MySQL do Compose.' }
        & docker compose -f compose.yaml run --rm database-setup
        if ($LASTEXITCODE -ne 0) { throw 'Instalação SQL recusada/interrompida; nenhum volume foi removido.' }
        & docker compose -f compose.yaml up -d --build backend frontend
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao iniciar backend/frontend.' }
        Write-Output 'Serviços Docker iniciados; os dados permanecem no volume mysql_data.'
        return
    }

    $python = Join-Path $projectRoot '.venv\Scripts\python.exe'
    $vite = Join-Path $projectRoot 'frontend\node_modules\vite\bin\vite.js'
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'backend\.env'))) { throw 'backend/.env ausente. Execute scripts/setup.ps1 -Mode Windows.' }
    if (-not (Test-Path -LiteralPath $python) -or -not (Test-Path -LiteralPath $vite)) { throw 'Dependências locais ausentes. Execute scripts/setup.ps1 -Mode Windows.' }

    foreach ($port in @(8000, 5173)) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listener) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2 | Out-Null
                if ($port -eq 8000) { Write-Output 'Backend Neural Doom já responde na porta 8000.'; continue }
            } catch {
                if ($port -eq 5173) {
                    try { Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:5173/' -TimeoutSec 2 | Out-Null; Write-Output 'Frontend já responde na porta 5173.'; continue } catch { }
                }
                throw "A porta $port já está ocupada por outro processo. Nenhum processo foi encerrado."
            }
        }
    }

    $runtimeDirectory = Join-Path $projectRoot '.runtime'
    $logsDirectory = Join-Path $runtimeDirectory 'logs'
    New-Item -ItemType Directory -Path $logsDirectory -Force | Out-Null
    $pidsPath = Join-Path $runtimeDirectory 'pids.json'
    $known = if (Test-Path -LiteralPath $pidsPath) { Get-Content -Raw $pidsPath | ConvertFrom-Json } else { [pscustomobject]@{} }

    $backendProcess = $null
    if (-not (Get-NetTCPConnection -State Listen -LocalPort 8000 -ErrorAction SilentlyContinue)) {
        $backendArgs = "-m uvicorn backend.main:app --host $BindAddress --port 8000"
        $backendProcess = Start-Process -FilePath $python -ArgumentList $backendArgs -WorkingDirectory $projectRoot -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logsDirectory 'backend.stdout.log') -RedirectStandardError (Join-Path $logsDirectory 'backend.stderr.log')
        $known | Add-Member -NotePropertyName BackendPid -NotePropertyValue $backendProcess.Id -Force
        $known | Add-Member -NotePropertyName BackendExe -NotePropertyValue $python -Force
    }

    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $node) { throw 'node.exe não está no PATH.' }
    $frontendProcess = $null
    if (-not (Get-NetTCPConnection -State Listen -LocalPort 5173 -ErrorAction SilentlyContinue)) {
        $frontendArgs = '"{0}" --host {1} --port 5173 --strictPort' -f $vite, $BindAddress
        $frontendProcess = Start-Process -FilePath $node.Source -ArgumentList $frontendArgs -WorkingDirectory (Join-Path $projectRoot 'frontend') -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logsDirectory 'frontend.stdout.log') -RedirectStandardError (Join-Path $logsDirectory 'frontend.stderr.log')
        $known | Add-Member -NotePropertyName FrontendPid -NotePropertyValue $frontendProcess.Id -Force
        $known | Add-Member -NotePropertyName NodeExe -NotePropertyValue $node.Source -Force
        $known | Add-Member -NotePropertyName ViteScript -NotePropertyValue $vite -Force
    }
    $known | ConvertTo-Json | Set-Content -LiteralPath $pidsPath -Encoding UTF8

    try {
        & (Join-Path $PSScriptRoot 'doctor.ps1') -Mode Windows -WaitSeconds 60 | Out-Null
    } catch {
        & (Join-Path $PSScriptRoot 'stop.ps1') -Mode Windows | Out-Null
        throw 'Os serviços locais não ficaram saudáveis; os processos iniciados por este script foram encerrados. Consulte .runtime/logs.'
    }

    if ($BindAddress -eq '127.0.0.1') {
        Write-Output 'Jogo pronto: http://127.0.0.1:5173'
    } else {
        $hostAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceOperationalStatus -eq 'Up' } | Select-Object -First 1 -ExpandProperty IPAddress
        if ($hostAddress) { Write-Output "Jogo na rede local: http://${hostAddress}:5173" } else { Write-Output 'Jogo pronto em http://<IP-do-notebook>:5173' }
        Write-Output 'A porta 8000 serve o WebSocket; o banco permanece acessível apenas pelo notebook.'
    }
} finally {
    Pop-Location
}
