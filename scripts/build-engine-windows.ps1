# build-engine-windows.ps1
# Builds a universal PyInstaller bundle for Windows amd64.
# Handles both en and zh in a single bundle (mirrors macOS build).
#
# Output:
#   assets/engine-windows-amd64-onnx.zip

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$EngineScript = Join-Path $RepoRoot "engine\kokoro_engine.py"
$EngineDir = Join-Path $RepoRoot "engine"
$AssetsDir = Join-Path $RepoRoot "assets"

Write-Host ""
Write-Host "-- Building universal ONNX engine / windows amd64 --"

$VenvDir     = Join-Path $EngineDir ".venv-onnx-amd64"
$DistDir     = Join-Path $EngineDir "dist-amd64-onnx"
$OutArchive  = Join-Path $AssetsDir "engine-windows-amd64-onnx.zip"

# Create venv
python -m venv $VenvDir
$pip         = Join-Path $VenvDir "Scripts\pip.exe"
$pyinstaller = Join-Path $VenvDir "Scripts\pyinstaller.exe"

& $pip install --quiet --upgrade pip
& $pip install --quiet pyinstaller

# Core TTS dependencies
& $pip install --quiet "kokoro-onnx>=0.4.0" soundfile numpy

# Chinese G2P: misaki[zh]>=0.9.0 for ZHG2P + jieba + pypinyin_dict
& $pip install --quiet "misaki[zh]>=0.9.0" ordered-set pypinyin_dict

# PyInstaller build
if (Test-Path $DistDir) { Remove-Item -Recurse -Force $DistDir }
& $pyinstaller `
    --noconfirm `
    --onedir `
    --name kokoro_engine `
    --collect-data kokoro_onnx `
    --collect-data misaki `
    --collect-all jieba `
    --collect-data ordered_set `
    --collect-all pypinyin_dict `
    --collect-data language_tags `
    --collect-data espeakng_loader `
    --collect-data phonemizer `
    --distpath $DistDir `
    --workpath (Join-Path $EngineDir "build-amd64-onnx") `
    --specpath $EngineDir `
    $EngineScript

# Package as zip
New-Item -ItemType Directory -Force $AssetsDir | Out-Null
if (Test-Path $OutArchive) { Remove-Item -Force $OutArchive }
Write-Host "  Packaging -> $OutArchive"
Compress-Archive -Path (Join-Path $DistDir "kokoro_engine") -DestinationPath $OutArchive
$Size = [math]::Round((Get-Item $OutArchive).Length / 1MB, 1)
Write-Host "  OK ${Size}MB  $OutArchive"

# Cleanup
Remove-Item -Recurse -Force $DistDir
Remove-Item -Recurse -Force (Join-Path $EngineDir "build-amd64-onnx") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "OK Windows engine bundle built: $OutArchive"
