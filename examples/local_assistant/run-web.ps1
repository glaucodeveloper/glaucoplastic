param(
  [int]$Port = 8765,
  [string]$HostAddress = "0.0.0.0",
  [string]$InputDevice = "CABLE Output"
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root
$env:LOCALAPPDATA = Join-Path $Root ".localappdata"
$env:NIMBLE_DIR = Join-Path $Root ".nimble"
New-Item -ItemType Directory -Path $env:NIMBLE_DIR -Force | Out-Null
$HomeNimble = Join-Path $HOME ".nimble"
foreach ($Name in @(
  "packages_official.json",
  "packages_temp.json",
  "official-nim-releases.json"
)) {
  $Source = Join-Path $HomeNimble $Name
  $Target = Join-Path $env:NIMBLE_DIR $Name
  if ((Test-Path $Source) -and -not (Test-Path $Target)) {
    Copy-Item -LiteralPath $Source -Destination $Target
  }
}
$env:GLAUCOPLASTIC_WEB_SERVER = "1"
$env:GLAUCOPLASTIC_WEB_HOST = $HostAddress
$env:GLAUCOPLASTIC_WEB_PORT = [string]$Port
$env:GLAUCOPLASTIC_VOICE_RECOGNITION = "system-microphone"
$env:GLAUCOPLASTIC_VOICE_INPUT_DEVICE = $InputDevice
$env:GLAUCOPLASTIC_FFMPEG_BINARY = "ffmpeg"
if (-not $env:GLAUCOPLASTIC_WHISPER_MODEL) {
  $env:GLAUCOPLASTIC_WHISPER_MODEL = Join-Path $Root ".runtime\whisper.cpp\models\ggml-base.bin"
}
if (-not $env:GLAUCOPLASTIC_WHISPER_BINARY) {
  foreach ($Candidate in @(
    (Join-Path $Root ".runtime\whisper.cpp\build\bin\Release\whisper-cli.exe"),
    (Join-Path $Root ".runtime\whisper.cpp\build\bin\whisper-cli.exe")
  )) {
    if (Test-Path $Candidate) { $env:GLAUCOPLASTIC_WHISPER_BINARY = $Candidate; break }
  }
}
Write-Host "Local Assistant: http://127.0.0.1:$Port"
Write-Host "Microfone: $InputDevice"
nim c -r -d:glaucoplasticHeadless --path:..\..\src .\assistant_consumer.nim
