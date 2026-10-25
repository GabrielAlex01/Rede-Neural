param(
    [Parameter(Mandatory = $true)]
    [string] $LoginPath,
    [string] $Schema = 'neural_doom_local_sql_test_20261024',
    [ValidateSet(
        'npc_teste_4_6_4',
        'npc_exp_4_32_4',
        'npc_exp_4_64_4',
        'npc_exp_4_64_32_64_4',
        'npc_exp_4_128_64_128_4',
        'npc_exp_4_256_128_64_4',
        'npc_exp_4_512_4'
    )]
    [string] $Architecture = 'npc_exp_4_128_64_128_4',
    [ValidateRange(1, 8)]
    [int] $Clients = 4,
    [ValidateRange(1, 100)]
    [int] $DecisionsPerClient = 10
)

$ErrorActionPreference = 'Stop'
if ($Schema -notmatch '^neural_doom_local_sql_test_[A-Za-z0-9_]+$') {
    throw 'O benchmark concorrente só pode escrever em um schema neural_doom_local_sql_test_* isolado.'
}

$mysqlCommand = Get-Command mysql.exe -ErrorAction SilentlyContinue
if ($mysqlCommand) {
    $mysqlPath = $mysqlCommand.Source
} else {
    $mysqlPath = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe'
    if (-not (Test-Path -LiteralPath $mysqlPath)) {
        throw 'mysql.exe não encontrado no PATH nem no local padrão do MySQL Server 8.0.'
    }
}

$selectedSchema = & $mysqlPath "--login-path=$LoginPath" "--database=$Schema" `
    --batch --skip-column-names --execute='SELECT DATABASE();' 2>$null
if ($LASTEXITCODE -ne 0 -or $selectedSchema.Trim() -ne $Schema) {
    throw 'A conexão não selecionou o schema de teste informado.'
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$jobs = for ($worker = 1; $worker -le $Clients; $worker++) {
    Start-Job -ArgumentList @(
        $mysqlPath, $LoginPath, $Schema, $Architecture, $worker, $DecisionsPerClient
    ) -ScriptBlock {
        param($mysqlExe, $loginPath, $schema, $architecture, $workerId, $decisionCount)

        $sql = [System.Text.StringBuilder]::new()
        [void] $sql.Append('SET @session_id = UUID();')
        for ($index = 1; $index -le $decisionCount; $index++) {
            $npcId = "load-$workerId-$index"
            [void] $sql.Append(
                "SET @run_id=NULL; SET @action=NULL; SET @confidence=NULL; " +
                "CALL sp_nn_decide_for_architecture('$architecture', @session_id, '$npcId', " +
                '1, 80, 100, 900, 1, 0, @run_id, @action, @confidence);'
            )
        }

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $output = & $mysqlExe "--login-path=$loginPath" "--database=$schema" `
            --batch --raw --skip-column-names "--execute=$($sql.ToString())" 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        $watch.Stop()
        if ($exitCode -ne 0) {
            throw "Worker $workerId failed while calling the SQL decision procedure. $output"
        }

        [pscustomobject]@{
            worker = $workerId
            decisions = $decisionCount
            elapsed_ms = $watch.ElapsedMilliseconds
            decisions_per_second = [Math]::Round($decisionCount / $watch.Elapsed.TotalSeconds, 2)
        }
    }
}

$jobs | Wait-Job | Out-Null
$results = @($jobs | Receive-Job)
$timer.Stop()
$failedJobs = @($jobs | Where-Object { $_.State -ne 'Completed' })
$jobs | Remove-Job -Force
if ($failedJobs.Count -gt 0 -or $results.Count -ne $Clients) {
    throw 'Uma ou mais conexões concorrentes falharam; confira a mensagem SQL acima.'
}

$results | Sort-Object worker |
    Select-Object worker, decisions, elapsed_ms, decisions_per_second |
    Format-Table -AutoSize
$clientTimes = @($results | Sort-Object elapsed_ms | ForEach-Object { $_.elapsed_ms })
$p95Index = [Math]::Max(0, [Math]::Ceiling($clientTimes.Count * 0.95) - 1)
$overallDecisions = $Clients * $DecisionsPerClient
Write-Output ("schema=$Schema arquitetura=$Architecture conexoes=$Clients decisões=$overallDecisions " +
    "tempo_total_ms=$($timer.ElapsedMilliseconds) " +
    "throughput_total=$([Math]::Round($overallDecisions / $timer.Elapsed.TotalSeconds, 2))_decisoes_s " +
    "p95_conclusao_cliente_ms=$($clientTimes[$p95Index])")
