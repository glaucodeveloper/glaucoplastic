param(
  [ValidateSet("cpu", "vulkan", "cuda12", "cuda13")]
  [string]$Backend = "cpu",
  [switch]$SkipWebView2
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if (-not (Get-Command nim -ErrorAction SilentlyContinue)) {
  & (Join-Path $PSScriptRoot "install-nim-windows.ps1")
}

if (-not (Get-Command nim -ErrorAction SilentlyContinue)) {
  throw "Nim não está disponível nesta sessão."
}

& (Join-Path $PSScriptRoot "install-llama-runtime-windows.ps1") -Backend $Backend
& (Join-Path $PSScriptRoot "configure-qwen3-model.ps1")

if (-not $SkipWebView2) {
  & (Join-Path $PSScriptRoot "install-webview2-windows.ps1") -Silent
}

if (Get-Command nimble -ErrorAction SilentlyContinue) {
  Push-Location $Root
  try { nimble develop -y }
  finally { Pop-Location }
}

Write-Host "Bootstrap Windows concluído."
