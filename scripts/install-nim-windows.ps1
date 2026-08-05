param(
  [switch]$SkipIfPresent
)

$ErrorActionPreference = "Stop"

if (Get-Command nim -ErrorAction SilentlyContinue) {
  if ($SkipIfPresent) { return }
  Write-Host "Nim já instalado: $(& nim --version | Select-Object -First 1)"
  return
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw @"
Nim não foi encontrado e o WinGet não está disponível.
Instale a distribuição x86_64 pelo instalador oficial do Nim e execute este
bootstrap novamente.
"@
}

Write-Host "==> Instalando Nim pelo catálogo WinGet"
$wingetArguments = @(
  "install",
  "--exact",
  "--id", "nim.nim",
  "--accept-package-agreements",
  "--accept-source-agreements"
)
& winget @wingetArguments

if ($LASTEXITCODE -ne 0) {
  throw "Falha ao instalar Nim pelo WinGet."
}

$possiblePaths = @(
  (Join-Path $HOME ".nimble\bin"),
  (Join-Path $env:LOCALAPPDATA "Programs\Nim\bin"),
  "C:\Nim\bin"
)
foreach ($candidate in $possiblePaths) {
  if (Test-Path $candidate) {
    $env:Path = "$candidate;$env:Path"
  }
}

if (-not (Get-Command nim -ErrorAction SilentlyContinue)) {
  throw "Nim foi instalado, mas ainda não está no PATH desta sessão. Abra um novo PowerShell e execute novamente."
}

Write-Host "Nim instalado: $(& nim --version | Select-Object -First 1)"
