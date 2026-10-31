param(
    [ValidateSet('Docker', 'Windows')][string]$Mode = 'Docker',
    [ValidateRange(1, 65535)][int]$MySqlPort = 3306,
    [string]$InstallerLoginPath = 'neural-doom-installer-20261024',
    [string]$InstallerDefaultsFile = '',
    [string]$MySqlExePath = '',
    [ValidateSet('127.0.0.1', '0.0.0.0')][string]$BindAddress = '127.0.0.1',
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $projectRoot
try {
    if ($Mode -eq 'Docker') {
        $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
        if (-not $docker) { $docker = Get-Command docker -ErrorAction SilentlyContinue }
        if (-not $docker) { throw 'Docker CLI não encontrado. Use -Mode Windows com MySQL Server local.' }
        & $docker.Source info --format '{{.ServerVersion}}' *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'Docker CLI existe, mas o daemon não está acessível. Inicie Docker Desktop e repita; nenhum container foi alterado.'
        }

        $dockerEnvPath = Join-Path $projectRoot '.env'
        if (-not (Test-Path -LiteralPath $dockerEnvPath)) {
            $rngBytes = New-Object byte[] 32
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            try { $rng.GetBytes($rngBytes) } finally { $rng.Dispose() }
            $rootPassword = [BitConverter]::ToString($rngBytes).Replace('-', '').ToLowerInvariant()
            $appBytes = New-Object byte[] 6
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            try { $rng.GetBytes($appBytes) } finally { $rng.Dispose() }
            $appToken = [BitConverter]::ToString($appBytes).Replace('-', '').ToLowerInvariant()
            $appPasswordBytes = New-Object byte[] 32
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            try { $rng.GetBytes($appPasswordBytes) } finally { $rng.Dispose() }
            $appPassword = [BitConverter]::ToString($appPasswordBytes).Replace('-', '').ToLowerInvariant()
            $lines = New-Object string[] 10
            $lines[0] = 'MYSQL_ROOT_PASSWORD=' + $rootPassword
            $lines[1] = 'NN_DB_USER=neural_doom_app_' + $appToken
            $lines[2] = 'NN_DB_PASSWORD=' + $appPassword
            $lines[3] = 'NN_ARCHITECTURE_NAME=genetic_v2_ref46_20261031'
            $lines[4] = 'MYSQL_HOST_PORT=13306'
            $lines[5] = 'MYSQL_BIND_ADDRESS=127.0.0.1'
            $lines[6] = 'DOOM_API_PORT=8000'
            $lines[7] = 'DOOM_WEB_PORT=5173'
            $lines[8] = 'DOOM_BIND_ADDRESS=' + $BindAddress
            $lines[9] = 'VITE_AI_WEBSOCKET_URL='
            $temporaryEnv = $dockerEnvPath + '.tmp'
            [IO.File]::WriteAllLines($temporaryEnv, [string[]]$lines, [Text.UTF8Encoding]::new($false))
            if ([IO.File]::ReadAllLines($temporaryEnv).Count -ne 10) { throw 'Falha ao preparar o .env Docker local.' }
            Move-Item -LiteralPath $temporaryEnv -Destination $dockerEnvPath
        } else {
            $names = [IO.File]::ReadAllLines($dockerEnvPath) | ForEach-Object {
                if ($_ -match '^\s*([A-Z_]+)\s*=') { $Matches[1] }
            }
            foreach ($required in @('MYSQL_ROOT_PASSWORD', 'NN_DB_USER', 'NN_DB_PASSWORD')) {
                if ($names -notcontains $required) { throw "O arquivo local .env está sem $required; ele foi preservado." }
            }
        }

        & $docker.Source compose -f compose.yaml up -d mysql
        if ($LASTEXITCODE -ne 0) { throw 'Não foi possível iniciar MySQL no Compose.' }

        $mysqlReady = $false
        for ($attempt = 0; $attempt -lt 90; $attempt++) {
            $containerId = & $docker.Source compose -f compose.yaml ps -q mysql 2>$null
            if ($containerId) {
                $health = & $docker.Source inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $containerId.Trim() 2>$null
                if ($health -eq 'healthy') { $mysqlReady = $true; break }
                if ($health -eq 'exited' -or $health -eq 'dead') { throw 'O container MySQL encerrou; consulte docker compose logs mysql (sem compartilhar credenciais).' }
            }
            Start-Sleep -Seconds 2
        }
        if (-not $mysqlReady) { throw 'MySQL do Compose não ficou saudável em 180 segundos.' }

        & $docker.Source compose -f compose.yaml run --rm database-setup
        if ($LASTEXITCODE -ne 0) { throw 'A instalação SQL no volume Compose falhou; nenhuma exclusão ou recriação de volume foi tentada.' }
        & $docker.Source compose -f compose.yaml up -d --build backend frontend
        if ($LASTEXITCODE -ne 0) { throw 'Backend/frontend não iniciaram pelo Compose.' }
        if (-not $NoStart) {
            & (Join-Path $PSScriptRoot 'doctor.ps1') -Mode Docker -WaitSeconds 90
        }
    } else {
        $service = Get-Service -Name 'MySQL80' -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running' -and $MySqlPort -eq 3306) {
            try { Start-Service -Name 'MySQL80' } catch { throw 'MySQL80 está parado e não pôde ser iniciado com as permissões atuais. Não alterei a configuração do serviço.' }
        }
        & (Join-Path $PSScriptRoot 'Install-Database.ps1') `
            -InstallerLoginPath $InstallerLoginPath `
            -InstallerDefaultsFile $InstallerDefaultsFile `
            -MySqlExePath $MySqlExePath `
            -MySqlPort $MySqlPort
        if ($LASTEXITCODE -ne 0) { throw 'Instalação SQL interrompida.' }

        $python = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
        $node = Get-Command node.exe -ErrorAction SilentlyContinue
        if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
        $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
        if (-not $python -or -not $node -or -not $npm) { throw 'Windows precisa de Python 3.10+, Node.js/npm e MySQL Server 8.0.46+; nenhum instalador global foi executado.' }

        $versionText = & $python.Source --version 2>&1
        if ($versionText -notmatch 'Python (\d+)\.(\d+)') { throw 'Não foi possível identificar a versão do Python.' }
        if ([int]$Matches[1] -lt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -lt 10)) { throw 'Python 3.10 ou mais novo é necessário.' }
        $venvPython = Join-Path $projectRoot '.venv\Scripts\python.exe'
        if (-not (Test-Path -LiteralPath $venvPython)) {
            & $python.Source -m venv (Join-Path $projectRoot '.venv')
            if ($LASTEXITCODE -ne 0) { throw 'Falha ao preparar o ambiente virtual Python local.' }
        }
        & $venvPython -m pip install --disable-pip-version-check -r backend\requirements.lock
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao instalar dependências Python fixadas.' }
        & $npm.Source ci --prefix frontend --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao instalar dependências frontend do package-lock.' }

        if (-not $NoStart) {
            & (Join-Path $PSScriptRoot 'start.ps1') -Mode Windows -BindAddress $BindAddress
            & (Join-Path $PSScriptRoot 'doctor.ps1') -Mode Windows -WaitSeconds 60
        }
    }
    Write-Output 'Preparação concluída. Os dados SQL usam volume persistente e o script não remove schemas/volumes.'
} finally {
    Pop-Location
}
