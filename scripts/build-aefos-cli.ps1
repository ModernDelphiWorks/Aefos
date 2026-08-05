<#
.SYNOPSIS
  Compiles the Aefos addon manager (cli\aefos.dpr) into cli\bin\aefos.exe.

.DESCRIPTION
  A plain Win32 console EXE (RTL + the Aefos.Compat.* shims in source\compat for
  HTTP/SHA-256/ZIP/JSON/IO - no ToolsAPI, no VCL). ONE binary serves every IDE
  version; compiled once with whichever RAD Studio command line is installed
  (D13/37.0 preferred, then D12/23.0). No IDE needs to be open. The same sources
  build under FPC 3.2.2 (see scripts\build-fpc.ps1 -Clis).

.EXAMPLE
  pwsh -NoProfile -File scripts/build-aefos-cli.ps1
#>
[CmdletBinding()]
param(
  [string] $Version  # optional: '37.0' or '23.0'; auto-detected when omitted
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$dpr  = Join-Path $repo 'cli\aefos.dpr'
$out  = Join-Path $repo 'cli\bin'
$dcu  = Join-Path $repo 'cli\.build-aefos'

if (-not (Test-Path $dpr)) { throw "CLI program not found: $dpr" }

$candidates = if ($Version) { @($Version) } else { @('37.0', '23.0') }
$rsvars = $null
foreach ($v in $candidates) {
  $p = "C:\Program Files (x86)\Embarcadero\Studio\$v\bin\rsvars.bat"
  if (Test-Path $p) { $rsvars = $p; break }
}
if (-not $rsvars) { throw "No installed RAD Studio (looked for: $($candidates -join ', '))." }

New-Item -ItemType Directory -Force -Path $out | Out-Null
New-Item -ItemType Directory -Force -Path $dcu | Out-Null

$u  = "$repo\cli;$repo\source\compat"
$ns = 'System;System.Win;Winapi'
$cmd = "call `"$rsvars`" && dcc32 -B -U`"$u`" -NS`"$ns`" -E`"$out`" -NU`"$dcu`" `"$dpr`""

Write-Host "== compiling Aefos addon manager (rsvars: $rsvars) ==" -ForegroundColor Cyan
$compile = cmd /c $cmd 2>&1
$compile | Select-Object -Last 8
if ($LASTEXITCODE -ne 0) { $compile; throw "Compilation FAILED (dcc32 exit $LASTEXITCODE)." }

$exe = Join-Path $out 'aefos.exe'
if (-not (Test-Path $exe)) { throw "EXE not produced: $exe" }
Write-Host "OK  $exe" -ForegroundColor Green
