<#
.SYNOPSIS
  Compiles the Aefos Desktop MCP server (mcps\desktop\AefosDesktopMcp.dpr) into
  mcps\desktop\bin\.

.DESCRIPTION
  A plain Win32 console EXE speaking JSON-RPC over stdio. It reuses the same
  TMCPServer core as the in-IDE server, but runs OUT of process: driving UI
  Automation (a COM ABI) must never be able to crash or freeze the customer's
  RAD Studio.

  No ToolsAPI, no VCL, no designide - so ONE binary serves every IDE version.
  The window enumeration uses the hand-written COM import Aefos.Win.UIAutomation,
  which closes the D11/D12 gap (those IDEs do not ship Winapi.UIAutomation).

  Compiled with whichever RAD Studio command line is installed (D13/37.0
  preferred, down to 10 Seattle/17.0). No IDE needs to be open. Pass -Version
  to force one.

  -Test also stands the freshly built .exe up as a real MCP server and drives a
  minimal handshake over stdio: initialize -> tools/list -> tools/call
  desktop_ping -> tools/call desktop_list_windows. This proves the server
  responds. The list_windows call is READ-ONLY and safe to run.

.EXAMPLE
  pwsh -NoProfile -File scripts/build-desktop-mcp.ps1 -Test
#>
[CmdletBinding()]
param(
  [string] $Version,   # optional: any supported BDS, e.g. '37.0' or '17.0'; auto-detected when omitted
  [switch] $Test
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$dpr  = Join-Path $repo 'mcps\desktop\AefosDesktopMcp.dpr'
$out  = Join-Path $repo 'mcps\desktop\bin'
$dcu  = Join-Path $repo 'mcps\desktop\.build'

if (-not (Test-Path $dpr)) { throw "Desktop MCP program not found: $dpr" }

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

# Unit search path: the desktop units plus the reused MCP server core.
# source\compat is not optional: Aefos.MCP.Types uses Aefos.Compat.Json
# UNCONDITIONALLY (not under an FPC IFDEF), so leaving it off the path fails the
# build with F2613 in a unit this project does not even own.
$u  = "$repo\mcps\desktop;$repo\source\mcp\Core;$repo\source\compat"
$ns = 'System;System.Win;Winapi;Data;Xml;Web;Soap'

function Invoke-Dcc32([string] $target, [string] $label) {
  $cmd = "call `"$rsvars`" && dcc32 -B -U`"$u`" -NS`"$ns`" -E`"$out`" -NU`"$dcu`" `"$target`""
  Write-Host "== compiling $label (rsvars: $rsvars) ==" -ForegroundColor Cyan
  $compile = cmd /c $cmd 2>&1
  $compile | Select-Object -Last 6
  if ($LASTEXITCODE -ne 0) { $compile; throw "Compilation FAILED (dcc32 exit $LASTEXITCODE)." }
}

Invoke-Dcc32 $dpr 'Aefos Desktop MCP server'
$exe = Join-Path $out 'AefosDesktopMcp.exe'
if (-not (Test-Path $exe)) { throw "EXE not produced: $exe" }
Write-Host "OK  $exe" -ForegroundColor Green

if ($Test) {
  Write-Host "== stdio handshake smoke (initialize + tools/list + tools/call) ==" -ForegroundColor Cyan

  # Newline-delimited JSON-RPC, exactly as an MCP client frames it. stdout is the
  # protocol; the server logs to stderr. We feed four frames and read the replies.
  $frames = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"desktop_ping","arguments":{}}}'
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"desktop_list_windows","arguments":{}}}'
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

  $proc = [System.Diagnostics.Process]::Start($psi)
  foreach ($f in $frames) { $proc.StandardInput.WriteLine($f) }
  $proc.StandardInput.Flush()
  $proc.StandardInput.Close()   # EOF: tells the server's Run loop to exit

  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  if (-not $proc.WaitForExit(15000)) { $proc.Kill(); throw "server did not exit within 15s." }

  Write-Host "---- server stdout (protocol) ----" -ForegroundColor DarkGray
  Write-Host $stdout
  if ($stderr.Trim()) {
    Write-Host "---- server stderr (log) ----" -ForegroundColor DarkGray
    Write-Host $stderr
  }

  $lines = $stdout -split "`n" | Where-Object { $_.Trim() }
  $ok = $true
  $reasons = @()

  # tools/list must advertise both skeleton tools.
  if ($stdout -notmatch 'desktop_ping')         { $ok = $false; $reasons += 'tools/list missing desktop_ping' }
  if ($stdout -notmatch 'desktop_list_windows') { $ok = $false; $reasons += 'tools/list missing desktop_list_windows' }
  # desktop_ping must return ok:true. The content is JSON-encoded inside the MCP
  # text block, so the braces/quotes are escaped in the frame.
  if ($stdout -notmatch '\\"ok\\":true')        { $ok = $false; $reasons += 'desktop_ping did not return ok:true' }
  # desktop_list_windows must report at least one window (count >= 1).
  $m = [regex]::Match($stdout, '\\"count\\":(\d+)')
  if (-not $m.Success)      { $ok = $false; $reasons += 'desktop_list_windows returned no count' }
  elseif ([int]$m.Groups[1].Value -lt 1) { $ok = $false; $reasons += 'desktop_list_windows returned zero windows' }

  if (-not $ok) {
    throw "SMOKE FAILED: $($reasons -join '; ')"
  }
  Write-Host "OK  handshake passed: initialize + tools/list + desktop_ping(ok:true) + desktop_list_windows(count>=1)" -ForegroundColor Green
}
