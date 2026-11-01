param(
    [string]$InstallerLoginPath = 'neural-doom-installer-20261024',
    [string]$InstallerDefaultsFile = '',
    [string]$MySqlExePath = '',
    [ValidateRange(1, 65535)][int]$MySqlPort = 3306
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$planPath = Join-Path $PSScriptRoot 'database-install-plan.tsv'
$appEnvPath = Join-Path $projectRoot 'backend\.env'
$gameSchema = 'neural_doom_local_game_20261024'
$testSchema = 'neural_doom_local_sql_test_20261024'
$installationId = 'neural-doom-lab-portable-v1'

if (-not $MySqlExePath) {
    $mysqlCommand = Get-Command mysql.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($mysqlCommand) {
        $MySqlExePath = $mysqlCommand.Source
    } else {
        $candidates = @(
            (Join-Path $env:ProgramFiles 'MySQL\MySQL Server 8.0\bin\mysql.exe'),
            (Join-Path $env:ProgramFiles 'MySQL\MySQL Server 8.4\bin\mysql.exe')
        )
        $MySqlExePath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
}
if (-not $MySqlExePath -or -not (Test-Path -LiteralPath $MySqlExePath)) {
    throw 'mysql.exe não encontrado. Instale MySQL Server 8.0.46 ou informe -MySqlExePath.'
}
if (-not (Test-Path -LiteralPath $planPath)) { throw 'Plano de instalação ausente no clone.' }

function Get-InstallerArguments {
    $args = [System.Collections.Generic.List[string]]::new()
    if ($InstallerDefaultsFile) {
        if (-not (Test-Path -LiteralPath $InstallerDefaultsFile)) {
            throw 'O arquivo privado de opções do instalador não foi encontrado.'
        }
        $args.Add('--defaults-extra-file=' + $InstallerDefaultsFile)
    } else {
        if (-not $InstallerLoginPath) { throw 'Informe um login-path de instalação ou -InstallerDefaultsFile.' }
        $args.Add('--login-path=' + $InstallerLoginPath)
    }
    $args.Add('--protocol=TCP')
    $args.Add('--host=127.0.0.1')
    $args.Add('--port=' + $MySqlPort)
    $args.Add('--connect-timeout=5')
    $args.Add('--batch')
    $args.Add('--raw')
    $args.Add('--skip-column-names')
    return ,$args.ToArray()
}

function Invoke-MySqlQuery([string]$Query, [string]$Database = '') {
    $args = Get-InstallerArguments
    if ($Database) { $args += '--database=' + $Database }
    $args += '--execute=' + $Query
    $output = & $MySqlExePath @args 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "mysql.exe retornou erro $exitCode ao consultar o servidor. $($output -join ' ')"
    }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Invoke-MySqlInput([string]$Sql, [string]$Database = '') {
    $args = Get-InstallerArguments
    if ($Database) { $args += '--database=' + $Database }
    $output = $Sql | & $MySqlExePath @args 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "mysql.exe retornou erro $exitCode ao aplicar SQL. $($output -join ' ')"
    }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-SchemaExists([string]$Schema) {
    return (Invoke-MySqlQuery "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$Schema'") -eq '1'
}

function Test-OwnedSchema([string]$Schema) {
    if (-not (Get-SchemaExists $Schema)) { return $false }
    $markerCount = Invoke-MySqlQuery "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$Schema' AND table_name='neural_doom_lab_installation'"
    if ($markerCount -ne '1') { return $false }
    return (Invoke-MySqlQuery "SELECT COUNT(*) FROM neural_doom_lab_installation WHERE installation_id='$installationId' AND singleton=1" $Schema) -eq '1'
}

function New-RandomHex([int]$ByteCount) {
    $bytes = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Read-AppEnv {
    $values = @{}
    if (-not (Test-Path -LiteralPath $appEnvPath)) { return $values }
    foreach ($line in [IO.File]::ReadAllLines($appEnvPath)) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') {
            $values[$Matches[1]] = $Matches[2]
        }
    }
    return $values
}

# Inspect both target names before creating either. A pre-existing, unmarked
# schema is never adopted or modified by this installer.
$schemaStates = @{}
foreach ($schema in @($gameSchema, $testSchema)) {
    $exists = Get-SchemaExists $schema
    $owned = $exists -and (Test-OwnedSchema $schema)
    if ($exists -and -not $owned) {
        throw "O schema $schema existe sem a marca desta instalação. Nenhum schema foi alterado. Use outro servidor isolado ou faça uma revisão manual."
    }
    $schemaStates[$schema] = @{ Exists = $exists; Owned = $owned }
}

$appEnv = Read-AppEnv
$createdAppCredentials = $false
if (-not $appEnvPath -or -not (Test-Path -LiteralPath $appEnvPath)) {
    $token = New-RandomHex 6
    $password = New-RandomHex 32
    $appEnv = @{
        NN_DB_HOST = '127.0.0.1'
        NN_DB_PORT = [string]$MySqlPort
        NN_DB_USER = "neural_doom_app_$token"
        NN_DB_PASSWORD = $password
        NN_DB_NAME = $gameSchema
        NN_ARCHITECTURE_NAME = 'genetic_v2_ref46_20261031'
    }
    $envLines = New-Object string[] 6
    $envLines[0] = 'NN_DB_HOST=' + $appEnv.NN_DB_HOST
    $envLines[1] = 'NN_DB_PORT=' + $appEnv.NN_DB_PORT
    $envLines[2] = 'NN_DB_USER=' + $appEnv.NN_DB_USER
    $envLines[3] = 'NN_DB_PASSWORD=' + $appEnv.NN_DB_PASSWORD
    $envLines[4] = 'NN_DB_NAME=' + $appEnv.NN_DB_NAME
    $envLines[5] = 'NN_ARCHITECTURE_NAME=' + $appEnv.NN_ARCHITECTURE_NAME
    $temporaryEnv = $appEnvPath + '.tmp'
    [IO.File]::WriteAllLines($temporaryEnv, [string[]]$envLines, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::ReadAllLines($temporaryEnv).Count -ne 6) { throw 'Falha ao preparar backend/.env local; nenhum banco foi alterado.' }
    Move-Item -LiteralPath $temporaryEnv -Destination $appEnvPath
    $createdAppCredentials = $true
} elseif ($appEnv.NN_DB_NAME -ne $gameSchema -or $appEnv.NN_DB_PORT -ne [string]$MySqlPort) {
    throw 'backend/.env aponta para outro schema ou porta; o arquivo foi preservado e nenhum banco foi instalado.'
}

foreach ($key in @('NN_DB_USER', 'NN_DB_PASSWORD')) {
    if (-not $appEnv.ContainsKey($key) -or -not $appEnv[$key]) { throw "backend/.env não contém $key; o arquivo foi preservado." }
}
$generatedUsername = $appEnv.NN_DB_USER -match '^neural_doom_app_[0-9a-f]{12}$'
$mysqlVersionCheck = Invoke-MySqlQuery 'SELECT VERSION()'
if ($mysqlVersionCheck -notmatch '^8\.0\.46(?:[.-]|$)') { throw "Versão MySQL não validada: esperado 8.0.46, encontrado $mysqlVersionCheck." }
if ($createdAppCredentials -or $generatedUsername) {
    if ((Invoke-MySqlQuery 'SELECT @@GLOBAL.general_log') -ne '0') {
        throw 'general_log global está ativo. A instalação parou antes de criar schemas/contas para evitar registrar credenciais; nenhuma configuração global foi modificada.'
    }
}

foreach ($schema in @($gameSchema, $testSchema)) {
    if (-not $schemaStates[$schema].Exists) {
        Invoke-MySqlInput "CREATE DATABASE $schema CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
        Invoke-MySqlInput @"
CREATE TABLE neural_doom_lab_installation (
  singleton TINYINT NOT NULL PRIMARY KEY,
  installation_id VARCHAR(64) NOT NULL,
  installed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
INSERT INTO neural_doom_lab_installation (singleton, installation_id) VALUES (1, '$installationId');
CREATE TABLE neural_doom_lab_setup_steps (
  step_key VARCHAR(100) NOT NULL PRIMARY KEY,
  state ENUM('running','complete') NOT NULL,
  checksum CHAR(64) NOT NULL,
  applied_at TIMESTAMP NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;
"@ $schema
    } else {
        $stepsCount = Invoke-MySqlQuery "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$schema' AND table_name='neural_doom_lab_setup_steps'"
        if ($stepsCount -ne '1') { throw "O schema $schema está marcado, mas falta o ledger de instalação; pare para revisão." }
    }
}

$plan = foreach ($line in [IO.File]::ReadAllLines($planPath)) {
    if (-not $line -or $line.TrimStart().StartsWith('#')) { continue }
    $parts = $line.Split('|')
    if ($parts.Length -ne 3) { throw 'Formato inválido no plano de instalação SQL.' }
    [pscustomobject]@{ Target = $parts[0]; Step = $parts[1]; Path = $parts[2] }
}

foreach ($entry in $plan) {
    $schema = if ($entry.Target -eq 'game') { $gameSchema } elseif ($entry.Target -eq 'test') { $testSchema } else { throw 'Destino desconhecido no plano SQL.' }
    if ($entry.Step -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Nome de etapa inválido no plano SQL.' }
    $sqlPath = Join-Path $projectRoot ($entry.Path -replace '/', '\')
    if (-not (Test-Path -LiteralPath $sqlPath)) { throw "Arquivo SQL não existe no clone: $($entry.Path)" }
    $checksum = (Get-FileHash -LiteralPath $sqlPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $row = Invoke-MySqlQuery "SELECT CONCAT(state,'|',checksum) FROM neural_doom_lab_setup_steps WHERE step_key='$($entry.Step)'" $schema
    if ($row -eq "complete|$checksum") {
        Write-Output "Já instalado: $($entry.Target)/$($entry.Step)"
        continue
    }
    if ($row.StartsWith('complete|')) { throw "O conteúdo da etapa $($entry.Target)/$($entry.Step) mudou após instalação; não reapliquei." }
    if ($row.StartsWith('running|')) { throw "A etapa $($entry.Target)/$($entry.Step) teve falha parcial; não tentei recuperá-la nem apagar dados." }
    if ($row) { throw "Estado inesperado para $($entry.Target)/$($entry.Step)." }

    Invoke-MySqlInput "INSERT INTO neural_doom_lab_setup_steps (step_key,state,checksum) VALUES ('$($entry.Step)','running','$checksum')" $schema | Out-Null
    $sql = [IO.File]::ReadAllText($sqlPath)
    Invoke-MySqlInput $sql $schema | Out-Null
    Invoke-MySqlInput "UPDATE neural_doom_lab_setup_steps SET state='complete', applied_at=CURRENT_TIMESTAMP WHERE step_key='$($entry.Step)' AND state='running' AND checksum='$checksum'" $schema | Out-Null
    Write-Output "Instalado: $($entry.Target)/$($entry.Step)"
}

if ($createdAppCredentials -or $generatedUsername) {
    $appUser = $appEnv.NN_DB_USER
    $appPassword = $appEnv.NN_DB_PASSWORD
    if ($appUser -notmatch '^[a-zA-Z0-9_]+$' -or $appPassword -notmatch '^[0-9a-fA-F]+$') {
        throw 'As credenciais geradas/localizadas não têm o formato local seguro esperado.'
    }
    $userExists = Invoke-MySqlQuery "SELECT COUNT(*) FROM mysql.user WHERE user='$appUser' AND host='127.0.0.1'"
    if ($userExists -eq '0') {
        $userSql = "CREATE USER '$appUser'@'127.0.0.1' IDENTIFIED BY '$appPassword';`nGRANT EXECUTE ON $gameSchema.* TO '$appUser'@'127.0.0.1';"
        Invoke-MySqlInput $userSql | Out-Null
    } else {
        Invoke-MySqlInput "GRANT EXECUTE ON $gameSchema.* TO '$appUser'@'127.0.0.1'" | Out-Null
    }
}

$mysqlVersion = Invoke-MySqlQuery 'SELECT VERSION()'
Write-Output "MySQL ${mysqlVersion}: instalação conferida em $gameSchema e $testSchema."
Write-Output 'A conta local gerada recebe somente EXECUTE no schema do jogo.'
