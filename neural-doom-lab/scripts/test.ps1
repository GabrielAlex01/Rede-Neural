param(
    [ValidateSet('Docker', 'Windows')][string]$Mode = 'Windows',
    [switch]$IncludeHeadlessMatch
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $projectRoot
try {
    if ($Mode -eq 'Docker') {
        & docker compose -f compose.yaml run --rm database-setup
        if ($LASTEXITCODE -ne 0) { throw 'O ledger recusou repetir uma etapa SQL incompleta.' }
        & docker compose -f compose.yaml exec -T -e NN_ARCHITECTURE_NAME= backend python -m unittest discover -s backend -p 'test_*.py' -v
        if ($LASTEXITCODE -ne 0) { throw 'Testes do backend falharam.' }
        & docker compose -f compose.yaml exec -T frontend npm test
        if ($LASTEXITCODE -ne 0) { throw 'Testes do frontend falharam.' }
        & docker compose -f compose.yaml exec -T frontend npm run build
        if ($LASTEXITCODE -ne 0) { throw 'Build do frontend falhou.' }
    } else {
        $python = Join-Path $projectRoot '.venv\Scripts\python.exe'
        if (-not (Test-Path -LiteralPath $python)) { throw 'Ambiente Python ausente; execute scripts/setup.ps1 -Mode Windows.' }
        $previousArchitecture = [Environment]::GetEnvironmentVariable('NN_ARCHITECTURE_NAME', 'Process')
        try {
            $env:NN_ARCHITECTURE_NAME = ''
            & $python -m unittest discover -s backend -p 'test_*.py' -v
            $backendTestExit = $LASTEXITCODE
        } finally {
            if ($null -eq $previousArchitecture) {
                Remove-Item Env:\NN_ARCHITECTURE_NAME -ErrorAction SilentlyContinue
            } else {
                $env:NN_ARCHITECTURE_NAME = $previousArchitecture
            }
        }
        if ($backendTestExit -ne 0) { throw 'Testes do backend falharam.' }
        & npm.cmd --prefix frontend test
        if ($LASTEXITCODE -ne 0) { throw 'Testes do frontend falharam.' }
        & npm.cmd --prefix frontend run build
        if ($LASTEXITCODE -ne 0) { throw 'Build do frontend falhou.' }
    }

    & (Join-Path $PSScriptRoot 'doctor.ps1') -Mode $Mode -WaitSeconds 30
    if ($IncludeHeadlessMatch) {
        if ($Mode -eq 'Docker' -and -not (Get-Command node.exe -ErrorAction SilentlyContinue)) {
            throw 'A partida headless é executada no host com Playwright e Microsoft Edge; instale Node.js no host ou use -Mode Windows.'
        }
        if (-not (Test-Path -LiteralPath 'frontend\node_modules\playwright-core')) {
            throw 'Playwright host ausente. Execute npm ci em frontend antes da partida headless.'
        }
        $matchArchitecture = $env:NN_ARCHITECTURE_NAME
        if ([string]::IsNullOrWhiteSpace($matchArchitecture)) {
            $architectureEnvFile = if ($Mode -eq 'Docker') { '.env' } else { 'backend\.env' }
            if (Test-Path -LiteralPath $architectureEnvFile) {
                foreach ($line in [IO.File]::ReadAllLines($architectureEnvFile)) {
                    if ($line -match '^\s*NN_ARCHITECTURE_NAME\s*=\s*(.*?)\s*$') {
                        $matchArchitecture = $Matches[1].Trim().Trim('"').Trim("'")
                    }
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($matchArchitecture)) { $matchArchitecture = 'npc_teste_4_6_4' }
        $previousMatchArchitecture = [Environment]::GetEnvironmentVariable('NN_ARCHITECTURE_NAME', 'Process')
        $previousMatchSeconds = [Environment]::GetEnvironmentVariable('DOOM_MATCH_SECONDS', 'Process')
        try {
            $env:NN_ARCHITECTURE_NAME = $matchArchitecture
            $env:DOOM_MATCH_SECONDS = '30'
            & node frontend\scripts\automated-match.mjs
            $matchExit = $LASTEXITCODE
        } finally {
            if ($null -eq $previousMatchArchitecture) {
                Remove-Item Env:\NN_ARCHITECTURE_NAME -ErrorAction SilentlyContinue
            } else {
                $env:NN_ARCHITECTURE_NAME = $previousMatchArchitecture
            }
            if ($null -eq $previousMatchSeconds) {
                Remove-Item Env:\DOOM_MATCH_SECONDS -ErrorAction SilentlyContinue
            } else {
                $env:DOOM_MATCH_SECONDS = $previousMatchSeconds
            }
        }
        if ($matchExit -ne 0) { throw 'Partida headless não passou nos checks de integração.' }
    }
    Write-Output 'Testes automatizados concluídos. Testes SQL de fixture rodam uma vez no setup limpo e ficam registrados no ledger.'
} finally {
    Pop-Location
}
