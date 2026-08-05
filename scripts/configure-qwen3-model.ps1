param(
  [string]$ModelDirectory = $(
    if ($env:GLAUCOPLASTIC_MODEL_DIR) {
      $env:GLAUCOPLASTIC_MODEL_DIR
    }
    else {
      Join-Path $HOME "models\Qwen3-4B"
    }
  ),
  [string]$ModelFile = $(
    if ($env:GLAUCOPLASTIC_MODEL_FILE) {
      $env:GLAUCOPLASTIC_MODEL_FILE
    }
    else {
      "Qwen3-4B-Q4_K_M.gguf"
    }
  ),
  [string]$Repo = $(if ($env:HF_REPO) { $env:HF_REPO } else { "Qwen/Qwen3-4B-GGUF" })
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ModelDirectory = [System.IO.Path]::GetFullPath($ModelDirectory)
$ModelPath = if ($env:GLAUCOPLASTIC_MODEL_PATH) {
  [System.IO.Path]::GetFullPath($env:GLAUCOPLASTIC_MODEL_PATH)
}
else {
  Join-Path $ModelDirectory $ModelFile
}

New-Item -ItemType Directory -Path $ModelDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Root "models") -Force | Out-Null

if (-not (Test-Path $ModelPath)) {
  Write-Host "==> Modelo ausente; será baixado para: $ModelPath"

  if (-not (Get-Command hf -ErrorAction SilentlyContinue)) {
    Write-Host "==> Instalando a CLI oficial do Hugging Face"
    Invoke-Expression (Invoke-RestMethod https://hf.co/cli/install.ps1)
    $env:Path = "$HOME\.local\bin;$env:Path"
  }

  if (-not (Get-Command hf -ErrorAction SilentlyContinue)) {
    throw "CLI hf não encontrada após instalação."
  }

  $arguments = @("download", $Repo, $ModelFile, "--local-dir", $ModelDirectory)
  if ($env:HF_TOKEN) { $arguments += @("--token", $env:HF_TOKEN) }
  & hf @arguments
  if ($LASTEXITCODE -ne 0) { throw "Falha no download do modelo." }
}

if (-not (Test-Path $ModelPath)) {
  throw "Modelo não encontrado: $ModelPath"
}

$hash = (Get-FileHash -Algorithm SHA256 -Path $ModelPath).Hash.ToLowerInvariant()
@{
  repo = $Repo
  file = $ModelFile
  path = $ModelPath
  sha256 = $hash
  format = "GGUF"
  role = "Qwen3 4B Instruct"
} | ConvertTo-Json | Set-Content (Join-Path $Root "models\model.json") -Encoding UTF8

@"
GLAUCOPLASTIC_MODEL_PATH=$ModelPath
GLAUCOPLASTIC_MODEL_ALIAS=qwen3-4b
"@ | Set-Content (Join-Path $Root "models\model.env") -Encoding UTF8

Write-Host "Modelo configurado: $ModelPath"
Write-Host "SHA-256: $hash"
