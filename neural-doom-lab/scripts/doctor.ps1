param(
    [ValidateSet('Docker', 'Windows')][string]$Mode = 'Windows',
    [ValidateRange(1, 300)][int]$WaitSeconds = 15
)

$ErrorActionPreference = 'Stop'
$frontendUrl = 'http://127.0.0.1:5173/'
$backendUrl = 'http://127.0.0.1:8000/health'
$deadline = (Get-Date).AddSeconds($WaitSeconds)
do {
    $apiHealthy = $false
    $webHealthy = $false
    try {
        $api = Invoke-WebRequest -UseBasicParsing -Uri $backendUrl -TimeoutSec 3
        $apiHealthy = $api.StatusCode -eq 200 -and $api.Content -match '"status"\s*:\s*"ok"'
    } catch { }
    try {
        $web = Invoke-WebRequest -UseBasicParsing -Uri $frontendUrl -TimeoutSec 3
        $webHealthy = $web.StatusCode -eq 200 -and $web.Content -match 'Neural Doom Lab'
    } catch { }
    if ($apiHealthy -and $webHealthy) { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)

if (-not $apiHealthy) { throw 'FastAPI/MySQL não confirmou saúde. A resposta não contém credenciais.' }
if (-not $webHealthy) { throw 'Frontend Vite não respondeu com a página esperada.' }
Write-Output 'FastAPI com consulta MySQL SELECT 1: saudável.'
Write-Output 'Frontend respondendo em HTTP 200.'
Write-Output 'A conexão do navegador usa o hostname da página para chegar ao WebSocket.'
