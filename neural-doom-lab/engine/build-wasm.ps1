param(
    [string]$FreedoomWad = (Join-Path $PSScriptRoot 'assets\freedoom2.wad'),
    [string]$ChocolateDoomSource = (Join-Path $PSScriptRoot 'vendor\chocolate-doom')
)

$ErrorActionPreference = 'Stop'
$requiredEmscriptenVersion = '4.0.14'
$upstreamCommit = '3e0cd5dc0cd0d5b6788100a2fbc1cdd4ce014b35'
$sourceRoot = $ChocolateDoomSource
$patchPath = Join-Path $PSScriptRoot 'neural-ai-bridge.patch'
$buildRoot = Join-Path $PSScriptRoot 'build\wasm'
$outputRoot = Join-Path $PSScriptRoot '..\frontend\public\engine'

if ([string]::IsNullOrWhiteSpace($env:EMSDK) -or -not (Test-Path -LiteralPath $env:EMSDK)) {
    throw 'Ative o Emscripten SDK antes de executar este script.'
}
$env:EMSDK_NODE = Join-Path $env:EMSDK 'node\24.19.0_64bit\node.exe'
$env:EMSDK_PYTHON = Join-Path $env:EMSDK 'python\3.13.3_64bit\python.exe'
$env:EM_CONFIG = Join-Path $env:EMSDK '.emscripten'
$env:PATH = "$env:EMSDK;$env:EMSDK\upstream\emscripten;$env:PATH"
foreach ($command in @('emcc', 'emcmake', 'cmake', 'ninja', 'git')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Comando não encontrado no PATH: $command"
    }
}
$emccVersion = (emcc --version 2>&1 | Select-Object -First 1) -join ''
if ($emccVersion -notmatch "\b$([regex]::Escape($requiredEmscriptenVersion))\b") {
    throw "Use Emscripten $requiredEmscriptenVersion para reproduzir este build (detectado: $emccVersion)."
}
foreach ($runtimePath in @($env:EMSDK_NODE, $env:EMSDK_PYTHON, $env:EM_CONFIG)) {
    if (-not (Test-Path -LiteralPath $runtimePath)) {
        throw "Runtime do Emscripten não encontrado: $runtimePath"
    }
}
if (-not (Test-Path -LiteralPath $FreedoomWad)) {
    throw "Coloque uma cópia licenciada de freedoom2.wad em: $FreedoomWad"
}

if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot '.git'))) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $sourceRoot) -Force | Out-Null
    git clone https://github.com/chocolate-doom/chocolate-doom.git $sourceRoot
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao clonar Chocolate Doom.' }
    git -C $sourceRoot fetch --depth 1 origin $upstreamCommit
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao obter o commit fixado de Chocolate Doom.' }
    git -C $sourceRoot switch --detach $upstreamCommit
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao selecionar o commit fixado.' }
}

$actualCommit = (git -C $sourceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $upstreamCommit) {
    throw "Chocolate Doom precisa estar no commit $upstreamCommit (atual: $actualCommit)."
}

git -C $sourceRoot apply --reverse --check -- $patchPath 2>$null
if ($LASTEXITCODE -ne 0) {
    git -C $sourceRoot apply --check -- $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'O patch não se aplica corretamente ao código-fonte.' }
    git -C $sourceRoot apply -- $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao aplicar o patch do bridge.' }
}

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$resolvedWad = (Resolve-Path -LiteralPath $FreedoomWad).Path
$linkFlags = "-sALLOW_MEMORY_GROWTH=1 -sASYNCIFY=1 -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=ChocolateDoomModule -sEXPORTED_RUNTIME_METHODS=callMain,FS --preload-file `"$resolvedWad@/iwads/freedoom2.wad`""
$configureArgs = @(
    '-S', $sourceRoot,
    '-B', $buildRoot,
    '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_EXECUTABLE_SUFFIX:STRING=.js',
    '-DENABLE_SDL2_MIXER=OFF',
    '-DENABLE_SDL2_NET=OFF',
    "-DCMAKE_EXE_LINKER_FLAGS=$linkFlags"
)

emcmake cmake @configureArgs
if ($LASTEXITCODE -ne 0) { throw 'Falha ao configurar o build WebAssembly.' }

cmake --build $buildRoot --target chocolate-doom --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar Chocolate Doom.' }

$builtRoot = Join-Path $buildRoot 'src'
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
foreach ($name in @('chocolate-doom.js', 'chocolate-doom.wasm', 'chocolate-doom.data')) {
    $builtFile = Join-Path $builtRoot $name
    if (-not (Test-Path -LiteralPath $builtFile)) { throw "Artefato ausente: $builtFile" }
    Copy-Item -LiteralPath $builtFile -Destination (Join-Path $outputRoot $name) -Force
}

Write-Output "Bundle atualizado em $outputRoot"
