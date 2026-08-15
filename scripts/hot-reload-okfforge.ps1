param(
  [string]$Source = 'F:\OKF Forge\knowledge_studio_app.nim',
  [string]$Output = 'F:\OKF Forge\okfforge_bncc_nw.exe',
  [string]$WorkDir = 'F:\OKF Forge',
  [int]$Port = 7654
)

$ErrorActionPreference = 'Stop'
$nim = (Get-Command nim -ErrorAction Stop).Source
$buildDir = Join-Path $WorkDir 'build'
$nimCache = Join-Path $buildDir 'nimcache'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

function Stop-App {
  Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Output)) -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
}

function Build-App {
  Write-Host "[GlaucoPlastic hot reload] compilando $Source"
  $env:TEMP = $buildDir
  $env:TMP = $buildDir
  & $nim c -d:release -d:glaucoplasticHeadless "--nimcache:$nimCache" "--out:$Output" $Source
  if ($LASTEXITCODE -ne 0) { throw "Falha na compilação ($LASTEXITCODE)" }
}

function Start-App {
  Write-Host "[GlaucoPlastic hot reload] iniciando http://127.0.0.1:$Port"
  Start-Process -FilePath $Output -ArgumentList '--nw', "--nw-port=$Port", '--nw-host=0.0.0.0' -WorkingDirectory $WorkDir | Out-Null
}

Build-App
Stop-App
Start-App

$watchRoots = @(
  (Split-Path -Parent $Source),
  (Join-Path $PSScriptRoot '..\src')
)
$watchers = foreach ($watchRoot in $watchRoots) {
  $item = New-Object IO.FileSystemWatcher $watchRoot, '*.nim'
  $item.IncludeSubdirectories = $true
  $item.NotifyFilter = [IO.NotifyFilters]'LastWrite,FileName,Size'
  $item
}
$events = @('Changed', 'Created', 'Renamed')
$registrations = foreach ($watcher in $watchers) {
  foreach ($eventName in $events) {
    Register-ObjectEvent $watcher $eventName -Action { $global:glaucoReloadPending = [DateTime]::UtcNow }
  }
}

$global:glaucoReloadPending = $null
try {
  while ($true) {
    Start-Sleep -Milliseconds 250
    if ($null -eq $global:glaucoReloadPending) { continue }
    if (([DateTime]::UtcNow - $global:glaucoReloadPending).TotalMilliseconds -lt 700) { continue }
    $global:glaucoReloadPending = $null
    try {
      Stop-App
      Build-App
      Start-App
      Write-Host '[GlaucoPlastic hot reload] pronto; o WebView recarrega pelo reloadToken.'
    } catch {
      Write-Warning $_
      Start-App
    }
  }
} finally {
  $registrations | Unregister-Event -ErrorAction SilentlyContinue
  $watchers | ForEach-Object { $_.Dispose() }
  Stop-App
}
