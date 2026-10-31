param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if (-not (Get-Command emcc -ErrorAction SilentlyContinue)) {
    if (-not [string]::IsNullOrWhiteSpace($env:EMSDK)) {
        $environmentScript = Join-Path $env:EMSDK 'emsdk_env.ps1'
        if (Test-Path -LiteralPath $environmentScript) {
            & $environmentScript
        }
    }
}

$emcc = Get-Command emcc -ErrorAction SilentlyContinue
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $emcc -or -not $node) {
    throw 'Ative Emscripten 4.0.14 e Node.js antes de executar este teste.'
}

$testSource = Join-Path $PSScriptRoot 'neural_attack_provenance_test.c'
$testDirectory = Join-Path $env:TEMP (
    'neural-attack-provenance-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$testProgram = Join-Path $testDirectory 'neural_attack_provenance_test.js'

& $emcc.Source -std=c99 -Wall -Wextra -Werror -O0 $testSource -o $testProgram
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao compilar a regressão determinística (emcc exit $LASTEXITCODE)."
}

& $node.Source $testProgram
if ($LASTEXITCODE -ne 0) {
    throw "A regressão determinística falhou (node exit $LASTEXITCODE)."
}

Write-Output "Artefato temporário: $testProgram"
