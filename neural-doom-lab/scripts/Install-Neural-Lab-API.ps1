param(
    [string]$InstallerLoginPath = 'neural-doom-installer-20261024',
    [string]$MySqlExePath = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$migration17Path = Join-Path $projectRoot 'database\migrations\17_neural_lab_inspection.sql'
$migration18Path = Join-Path $projectRoot 'database\migrations\18_neural_lab_playable_selection.sql'
$targets = @(
    'neural_doom_local_game_20261024',
    'neural_doom_local_sql_test_20261024'
)

if (-not $MySqlExePath) {
    $mysqlCommand = Get-Command mysql.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($mysqlCommand) {
        $MySqlExePath = $mysqlCommand.Source
    } else {
        $MySqlExePath = Join-Path $env:ProgramFiles 'MySQL\MySQL Server 8.0\bin\mysql.exe'
    }
}
if (-not (Test-Path -LiteralPath $MySqlExePath)) { throw 'mysql.exe não encontrado.' }
if (-not (Test-Path -LiteralPath $migration17Path)) { throw 'Migration 17 ausente no clone.' }
if (-not (Test-Path -LiteralPath $migration18Path)) { throw 'Migration 18 ausente no clone.' }
if (-not $InstallerLoginPath) { throw 'Informe o login-path local do instalador.' }

function Invoke-TargetQuery([string]$Schema, [string]$Query) {
    $result = & $MySqlExePath "--login-path=$InstallerLoginPath" --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=5 "--database=$Schema" --batch --raw --skip-column-names "--execute=$Query" 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $diagnostic = (($result | ForEach-Object { [string]$_ }) -join ' ').Trim()
        throw "A verificação de leitura falhou (mysql.exe $exitCode) no schema de destino ${Schema}: $diagnostic. Nenhuma alteração foi feita nesta fase."
    }
    return (($result | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Invoke-TargetMigration([string]$Schema, [string]$Sql, [int]$Version) {
    $result = $Sql | & $MySqlExePath "--login-path=$InstallerLoginPath" --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=5 "--database=$Schema" --batch --raw 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Migration $Version falhou no schema $Schema. Nenhum outro schema foi selecionado."
    }
    return (($result | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

$labRoutineNames = @(
    'sp_nn_lab_list_architectures',
    'sp_nn_lab_architecture_layers',
    'sp_nn_lab_list_genomes',
    'sp_nn_lab_run_activations',
    'sp_nn_lab_genome_weights'
)

# Validate both destinations before applying either one. This accepts an
# existing, unmarked database only for this additive migration and does not
# adopt it into or rewrite the general installation ledger.
foreach ($schema in $targets) {
    $query = "SELECT CONCAT(DATABASE(), '|', VERSION(), '|', (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name IN ('nn_engine_session','nn_session_npc','nn_decision_run','nn_decision_activation','nn_genome_evaluation_v2','nn_neuron_io','nn_genome_weight','nn_layer')), '|', (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = DATABASE() AND routine_name IN ('sp_nn_create_configurable_architecture','sp_nn_create_seeded_population','sp_nn_decide_for_architecture')), '|', (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = DATABASE() AND routine_name IN ('sp_nn_lab_list_architectures','sp_nn_lab_architecture_layers','sp_nn_lab_list_genomes','sp_nn_lab_run_activations','sp_nn_lab_genome_weights')));"
    $state = Invoke-TargetQuery $schema $query
    $parts = $state.Split('|')
    if (
        ($parts.Count -ne 5) -or
        ($parts[0] -ne $schema) -or
        ($parts[1] -ne '8.0.46') -or
        ($parts[2] -ne '8') -or
        ($parts[3] -ne '3') -or
        (($parts[4] -ne '0') -and ($parts[4] -ne '5'))
    ) {
        throw "Schema $schema não corresponde ao Neural Doom instalado ou contém estado parcial da migration. Nenhum schema foi alterado nesta fase."
    }
    Write-Output "Pré-verificado: $schema (MySQL 8.0.46; migration 17 $($parts[4])/5 procedures)."
}

$migration17Sql = [IO.File]::ReadAllText($migration17Path)
$migration18Sql = [IO.File]::ReadAllText($migration18Path)
foreach ($schema in $targets) {
    $existingLabRoutines = Invoke-TargetQuery $schema @"
SELECT COUNT(*) FROM information_schema.routines
WHERE routine_schema = DATABASE() AND routine_name IN (
  'sp_nn_lab_list_architectures','sp_nn_lab_architecture_layers',
  'sp_nn_lab_list_genomes','sp_nn_lab_run_activations',
  'sp_nn_lab_genome_weights'
);
"@
    if ($existingLabRoutines -eq '0') {
        Invoke-TargetMigration $schema $migration17Sql 17 | Out-Null
        Write-Output "Migration 17 instalada: $schema (somente procedures de inspeção)."
    }
    Invoke-TargetMigration $schema $migration18Sql 18 | Out-Null
    $routineCount = Invoke-TargetQuery $schema @"
SELECT COUNT(*) FROM information_schema.routines
WHERE routine_schema = DATABASE() AND routine_name IN (
  'sp_nn_lab_list_architectures','sp_nn_lab_architecture_layers',
  'sp_nn_lab_list_genomes','sp_nn_lab_run_activations',
  'sp_nn_lab_genome_weights','sp_nn_select_session_genome_v2'
);
"@
    if ($routineCount -ne '6') { throw "A migration 18 não foi confirmada no schema $schema." }
    Write-Output "Migration 18 instalada: $schema (catálogo jogável e seleção explícita de genoma)."
}
