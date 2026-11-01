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
$engineDirectory = Split-Path -Parent $PSScriptRoot
$patchPath = Join-Path $engineDirectory 'neural-ai-bridge.patch'
$vendorHeaderPath = Join-Path $engineDirectory 'vendor\chocolate-doom\src\doom\p_neural_ai_provenance.h'
$testDirectory = Join-Path $env:TEMP (
    'neural-attack-provenance-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$testHeaderPath = Join-Path $testDirectory 'p_neural_ai_provenance.h'
$testProgram = Join-Path $testDirectory 'neural_attack_provenance_test.js'

$patchLines = [System.IO.File]::ReadAllLines($patchPath)
$headerDiffStart = [Array]::IndexOf(
    $patchLines,
    'diff --git a/src/doom/p_neural_ai_provenance.h b/src/doom/p_neural_ai_provenance.h')
if ($headerDiffStart -lt 0) {
    throw 'O patch versionado não contém p_neural_ai_provenance.h.'
}

$headerHunkStart = $headerDiffStart + 1
while ($headerHunkStart -lt $patchLines.Length -and -not $patchLines[$headerHunkStart].StartsWith('@@')) {
    $headerHunkStart++
}
if ($headerHunkStart -ge $patchLines.Length) {
    throw 'O patch não contém um hunk para p_neural_ai_provenance.h.'
}

$headerLines = [System.Collections.Generic.List[string]]::new()
for ($lineIndex = $headerHunkStart + 1; $lineIndex -lt $patchLines.Length; $lineIndex++) {
    $patchLine = $patchLines[$lineIndex]
    if ($patchLine.StartsWith('diff --git ')) {
        break
    }
    if ($patchLine.StartsWith('+') -and -not $patchLine.StartsWith('+++')) {
        [void] $headerLines.Add($patchLine.Substring(1))
    }
}
if ($headerLines.Count -eq 0) {
    throw 'O patch não contém o conteúdo do header de proveniência.'
}

$patchHeader = ($headerLines -join "`n") + "`n"
Set-Content -LiteralPath $testHeaderPath -Value $patchHeader -NoNewline -Encoding ascii
if (Test-Path -LiteralPath $vendorHeaderPath) {
    $vendorHeader = [System.IO.File]::ReadAllText($vendorHeaderPath) -replace "`r`n?", "`n"
    if ($vendorHeader.TrimEnd() -cne $patchHeader.TrimEnd()) {
        throw 'O header C compilado diverge do helper versionado no patch.'
    }
}

& $emcc.Source -std=c99 -Wall -Wextra -Werror -O0 -I $testDirectory $testSource -o $testProgram
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao compilar a regressão determinística (emcc exit $LASTEXITCODE)."
}

& $node.Source $testProgram
if ($LASTEXITCODE -ne 0) {
    throw "A regressão determinística falhou (node exit $LASTEXITCODE)."
}

Write-Output "Artefato temporário: $testProgram"
