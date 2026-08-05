param([switch]$Silent)
$ErrorActionPreference = "Stop"
$Url = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
$Target = Join-Path $env:TEMP "MicrosoftEdgeWebview2Setup.exe"
Invoke-WebRequest -Uri $Url -OutFile $Target
$argsList = @("/silent", "/install")
if (-not $Silent) { Write-Host "Instalando WebView2 Evergreen Runtime..." }
Start-Process -FilePath $Target -ArgumentList $argsList -Wait
Remove-Item $Target -Force -ErrorAction SilentlyContinue
