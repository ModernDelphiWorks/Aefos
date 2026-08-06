<#
.SYNOPSIS
  Compiles the Aefos Agent CLI (cli\AefosAgent.dpr) into cli\bin\AefosAgent.exe.

.DESCRIPTION
  The CLI is a plain Win32 console EXE (RTL-only: System.Net + threading, no
  ToolsAPI, no VCL) - ONE binary serves every supported IDE version, so it is
  compiled once with whichever RAD Studio command line is installed (D13/37.0
  preferred, down to 10 Seattle/17.0). No IDE needs to be open.

.EXAMPLE
  pwsh -NoProfile -File scripts/build-agent-cli.ps1
#>
[CmdletBinding()]
param(
  [string] $Version  # optional: any supported BDS, e.g. '37.0' or '17.0'; auto-detected when omitted
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$dpr  = Join-Path $repo 'cli\AefosAgent.dpr'
$out  = Join-Path $repo 'cli\bin'
$dcu  = Join-Path $repo 'cli\.build'

if (-not (Test-Path $dpr)) { throw "CLI program not found: $dpr" }

# Resolve a RAD Studio rsvars.bat.
# One binary serves every IDE version, so ANY installed RAD Studio can build it -
# newest first. The list is scripts\aefos-ide-versions.ps1; never a copy.
. (Join-Path $PSScriptRoot 'aefos-ide-versions.ps1')
$candidates = if ($Version) { @($Version) } else { $script:AefosIdeVersionsNewestFirst }
$rsvars = $null
foreach ($v in $candidates) {
  $p = Get-AefosRsVarsPath $v
  if (Test-Path $p) { $rsvars = $p; break }
}
if (-not $rsvars) { throw "No installed RAD Studio (looked for: $($candidates -join ', '))." }

New-Item -ItemType Directory -Force -Path $out | Out-Null
New-Item -ItemType Directory -Force -Path $dcu | Out-Null

$u  = "$repo\cli;$repo\source\providers;$repo\source\compat"
$ns = 'System;System.Win;Winapi'
$cmd = "call `"$rsvars`" && dcc32 -B -U`"$u`" -NS`"$ns`" -E`"$out`" -NU`"$dcu`" `"$dpr`""

Write-Host "== compiling Aefos Agent CLI (rsvars: $rsvars) ==" -ForegroundColor Cyan
$compile = cmd /c $cmd 2>&1
$compile | Select-Object -Last 6
if ($LASTEXITCODE -ne 0) { $compile; throw "Compilation FAILED (dcc32 exit $LASTEXITCODE)." }

$exe = Join-Path $out 'AefosAgent.exe'
if (-not (Test-Path $exe)) { throw "EXE not produced: $exe" }
Write-Host "OK  $exe" -ForegroundColor Green
