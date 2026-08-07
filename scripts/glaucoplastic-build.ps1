param(
  [Parameter(Position=0, Mandatory=$true)]
  [ValidateSet("dev", "build", "package", "verify")]
  [string]$Command,

  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Remaining
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Tool = Join-Path $Root "tools\glaucoplastic_build.py"

$Python = Get-Command py -ErrorAction SilentlyContinue
if ($Python) {
  & $Python.Source -3 $Tool $Command @Remaining
} else {
  $Python = Get-Command python -ErrorAction Stop
  & $Python.Source $Tool $Command @Remaining
}

exit $LASTEXITCODE
