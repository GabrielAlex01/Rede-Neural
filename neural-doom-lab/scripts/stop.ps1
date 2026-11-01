param([ValidateSet('Docker', 'Windows')][string]$Mode = 'Windows')

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $projectRoot
try {
    if ($Mode -eq 'Docker') {
        & docker compose -f compose.yaml stop frontend backend mysql
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao parar um serviço Compose.' }
        Write-Output 'Serviços parados. O volume mysql_data foi preservado.'
        return
    }

    $pidsPath = Join-Path $projectRoot '.runtime\pids.json'
    if (-not (Test-Path -LiteralPath $pidsPath)) { Write-Output 'Nenhum processo Neural Doom registrado.'; return }
    $known = Get-Content -Raw $pidsPath | ConvertFrom-Json
    $targets = @()
    if ($known.BackendPid -and $known.BackendExe) {
        $targets += [pscustomobject]@{
            Pid = [int]$known.BackendPid
            Exe = [string]$known.BackendExe
            Marker = 'uvicorn backend.main:app'
            Port = 8000
            PythonLauncher = $true
        }
    }
    if ($known.FrontendPid -and $known.NodeExe -and $known.ViteScript) {
        $targets += [pscustomobject]@{
            Pid = [int]$known.FrontendPid
            Exe = [string]$known.NodeExe
            Marker = [string]$known.ViteScript
            Port = 5173
            PythonLauncher = $false
        }
    }
    foreach ($target in $targets) {
        $candidateIds = @([int]$target.Pid)
        $listeners = Get-NetTCPConnection -State Listen -LocalPort $target.Port -ErrorAction SilentlyContinue
        foreach ($listener in $listeners) {
            $candidateIds += [int]$listener.OwningProcess
        }

        foreach ($candidateId in ($candidateIds | Sort-Object -Unique)) {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId = $candidateId" -ErrorAction SilentlyContinue
            if (-not $process) { continue }
            $commandLine = [string]$process.CommandLine
            $projectMatches = $commandLine.IndexOf($projectRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
            $markerMatches = $commandLine -like "*$($target.Marker)*"
            $exeMatches = [string]::Equals([string]$process.ExecutablePath, $target.Exe, [StringComparison]::OrdinalIgnoreCase)
            if ($target.PythonLauncher) {
                # Windows venv launchers may leave Uvicorn running in a child
                # process whose ExecutablePath is the base Python installation.
                $exeMatches = $exeMatches -or ($commandLine.IndexOf($target.Exe, [StringComparison]::OrdinalIgnoreCase) -ge 0)
            }

            if ($exeMatches -and $markerMatches -and $projectMatches) {
                Stop-Process -Id $candidateId -Force
                Write-Output "Processo Neural Doom $candidateId encerrado."
            } elseif ($candidateId -eq $target.Pid) {
                Write-Output "PID $candidateId não corresponde ao executável e clone registrados; preservado."
            }
        }
    }
    Remove-Item -LiteralPath $pidsPath -Force
    Write-Output 'MySQL Server local não foi parado e os dados não foram removidos.'
} finally {
    Pop-Location
}
