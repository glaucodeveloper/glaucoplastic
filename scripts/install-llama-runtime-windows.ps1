param(
  [ValidateSet("cpu", "vulkan", "cuda12", "cuda13")]
  [string]$Backend = "cpu",
  [string]$RuntimeDirectory = $(
    if ($env:GLAUCOPLASTIC_WINDOWS_RUNTIME_DIR) {
      $env:GLAUCOPLASTIC_WINDOWS_RUNTIME_DIR
    }
    else {
      ""
    }
  )
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RuntimeRoot = if ($RuntimeDirectory) {
  [System.IO.Path]::GetFullPath($RuntimeDirectory)
}
else {
  Join-Path $Root "runtime\llama\windows-x64"
}
$BinDir = Join-Path $RuntimeRoot "bin"
$Api = "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
$Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("glaucoplastic-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Temp | Out-Null

try {
  Write-Host "==> Pasta dos binários Windows: $BinDir"
  $release = Invoke-RestMethod -Uri $Api -Headers @{ "Accept" = "application/vnd.github+json" }

  $pattern = switch ($Backend) {
    "cpu" { '^llama-b\d+-bin-win-cpu-x64\.zip$' }
    "vulkan" { '^llama-b\d+-bin-win-vulkan-x64\.zip$' }
    "cuda12" { '^llama-b\d+-bin-win-cuda-12\.\d+-x64\.zip$' }
    "cuda13" { '^llama-b\d+-bin-win-cuda-13\.\d+-x64\.zip$' }
  }

  $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
  if (-not $asset) { throw "Asset llama.cpp compatível não encontrado." }

  $archive = Join-Path $Temp $asset.name
  $extracted = Join-Path $Temp "extracted"
  Write-Host "==> Baixando $($asset.name)"
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive

  if ($asset.digest -and $asset.digest.StartsWith("sha256:")) {
    $expected = $asset.digest.Substring(7).ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "SHA-256 do runtime não confere." }
  }

  New-Item -ItemType Directory -Path $extracted -Force | Out-Null
  Expand-Archive -Path $archive -DestinationPath $extracted -Force

  $server = Get-ChildItem -Path $extracted -Recurse -Filter "llama-server.exe" | Select-Object -First 1
  if (-not $server) { throw "llama-server.exe não encontrado." }

  if (Test-Path $RuntimeRoot) { Remove-Item $RuntimeRoot -Recurse -Force }
  New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
  Copy-Item (Join-Path $server.DirectoryName "*") $BinDir -Recurse -Force

  if ($Backend -like "cuda*") {
    $cudaMajor = if ($Backend -eq "cuda12") { "12" } else { "13" }
    $cudartPattern = "^cudart-llama-bin-win-cuda-$cudaMajor\.\d+-x64\.zip$"
    $cudart = $release.assets | Where-Object { $_.name -match $cudartPattern } | Select-Object -First 1
    if (-not $cudart) { throw "Pacote CUDA runtime correspondente não encontrado." }

    $cudartArchive = Join-Path $Temp $cudart.name
    Write-Host "==> Baixando $($cudart.name)"
    Invoke-WebRequest -Uri $cudart.browser_download_url -OutFile $cudartArchive

    if ($cudart.digest -and $cudart.digest.StartsWith("sha256:")) {
      $expectedCuda = $cudart.digest.Substring(7).ToLowerInvariant()
      $actualCuda = (Get-FileHash -Algorithm SHA256 -Path $cudartArchive).Hash.ToLowerInvariant()
      if ($actualCuda -ne $expectedCuda) { throw "SHA-256 do runtime CUDA não confere." }
    }

    Expand-Archive -Path $cudartArchive -DestinationPath $BinDir -Force
  }

  @{
    tag = $release.tag_name
    asset = $asset.name
    backend = $Backend
    bin_directory = $BinDir
  } | ConvertTo-Json | Set-Content (Join-Path $RuntimeRoot "VERSION.json") -Encoding UTF8

  Write-Host "Runtime Windows instalado em: $RuntimeRoot"
  Write-Host "Binários disponíveis em: $BinDir"
  & (Join-Path $BinDir "llama-server.exe") --version
}
finally {
  if (Test-Path $Temp) { Remove-Item $Temp -Recurse -Force }
}
