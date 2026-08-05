param(
  [string]$Repo = $(
    if ($env:GLAUCOPLASTIC_MODEL_REPO) { $env:GLAUCOPLASTIC_MODEL_REPO }
    elseif ($env:HF_REPO) { $env:HF_REPO }
    else { "unsloth/gemma-4-E4B-it-GGUF" }
  ),
  [string]$File = $(
    if ($env:GLAUCOPLASTIC_MODEL_FILE) { $env:GLAUCOPLASTIC_MODEL_FILE }
    elseif ($env:HF_FILE) { $env:HF_FILE }
    else { "gemma-4-E4B-it-Q4_K_M.gguf" }
  ),
  [string]$ModelDir = $(
    if ($env:GLAUCOPLASTIC_MODEL_DIR) { $env:GLAUCOPLASTIC_MODEL_DIR }
    else { Join-Path $HOME "models\gemma-4" }
  )
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ModelDir = [System.IO.Path]::GetFullPath($ModelDir)
$ModelPath = if ($env:GLAUCOPLASTIC_MODEL_PATH) {
  [System.IO.Path]::GetFullPath($env:GLAUCOPLASTIC_MODEL_PATH)
}
else {
  Join-Path $ModelDir $File
}

if (-not (Get-Command hf -ErrorAction SilentlyContinue)) {
  Write-Host "==> Instalando a CLI oficial do Hugging Face"
  Invoke-Expression (Invoke-RestMethod https://hf.co/cli/install.ps1)
  $env:Path = "$HOME\.local\bin;$env:Path"
}

if (-not (Get-Command hf -ErrorAction SilentlyContinue)) {
  throw "CLI hf não encontrada após instalação. Abra um novo PowerShell e execute novamente."
}

New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $ModelPath) -Force | Out-Null
$argsList = @("download", $Repo, $File, "--local-dir", $ModelDir)
if ($env:HF_TOKEN) { $argsList += @("--token", $env:HF_TOKEN) }

Write-Host "==> Baixando $Repo / $File"
& hf @argsList
if ($LASTEXITCODE -ne 0) { throw "Falha no download do modelo." }

if (-not (Test-Path $ModelPath) -and (Test-Path (Join-Path $ModelDir $File))) {
  Copy-Item -Force (Join-Path $ModelDir $File) $ModelPath
}

if (-not (Test-Path $ModelPath)) { throw "Modelo não encontrado após download: $ModelPath" }
$hash = (Get-FileHash -Algorithm SHA256 -Path $ModelPath).Hash.ToLowerInvariant()
@{
  repo = $Repo
  file = $File
  sha256 = $hash
  format = "GGUF"
  role = "Gemma 4 E4B Instruct"
} | ConvertTo-Json | Set-Content (Join-Path $ModelDir "model.json") -Encoding UTF8
Write-Host "Modelo instalado em: $ModelPath"
Write-Host "SHA-256: $hash"
