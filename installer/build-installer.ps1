<#
  Compiles the multi-version Aefos installer from the per-version BPLs that
  scripts\build-packages.ps1 staged into installer\bpl\<ver>\.

  A version is shipped iff installer\bpl\<ver>\ holds the full set of BPLs, so:
    - On this machine:  pwsh -File scripts\build-packages.ps1   (builds+stages D12/D13)
    - In the Delphi 11 VM: pwsh -File scripts\build-packages.ps1 -Version 22.0,
      then copy that VM's installer\bpl\22.0\ folder into THIS repo's installer\bpl\.
  This script does NOT build or fetch BPLs -- it only validates what is staged,
  drops the WebView2 loader beside each version's BPLs, and runs ISCC.

  Supported design-time versions:
    22.0 = Delphi 11 Alexandria   23.0 = Delphi 12 Athens   37.0 = Delphi 13

  Usage:
    pwsh -File build-installer.ps1
    pwsh -File build-installer.ps1 -Iscc "C:\...\ISCC.exe"
#>
[CmdletBinding()]
param(
  [string]$Iscc = '',
  # Release flag: fetch the CURRENT upstream AI CLIs (codex today; gemini/copilot
  # phase 2) into redist\cli\ before compiling, so the shipped bundle is fresh.
  # Off by default so dev iteration builds don't hit the network.
  [switch]$FetchClis
)

$ErrorActionPreference = 'Stop'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$stage = Join-Path $here 'bpl'
$iss   = Join-Path $here 'Aefos.iss'

$Supported = @('22.0', '23.0', '37.0')
$Bpls = @(
  'Aefos.Harness.bpl', 'Aefos.Providers.bpl',
  'Aefos.WebView.bpl', 'Aefos.Tools.bpl', 'Aefos.MCP.Core.bpl',
  'Aefos.MCP.Tools.OTA.bpl', 'Aefos.Data.bpl', 'Aefos.OTA.Chat.bpl',
  'Aefos.OTA.Terminal.bpl', 'dclAefosWebView.bpl'
)

# WebView2Loader.dll is a Microsoft component (version-independent, x86). We ship
# it beside our BPLs and point the RTL at it by full path (SetWebView2Path). Source
# it from any installed RAD Studio bin (Delphi 12's bin lacks it; Delphi 13 has it).
function Get-WebView2Loader {
  foreach ($v in @('37.0', '23.0', '22.0')) {
    $p = "C:\Program Files (x86)\Embarcadero\Studio\$v\bin\WebView2Loader.dll"
    if (Test-Path $p) { return $p }
  }
  if ($env:BDS) {
    $p = Join-Path $env:BDS 'bin\WebView2Loader.dll'
    if (Test-Path $p) { return $p }
  }
  throw "WebView2Loader.dll not found in any RAD Studio bin. Needed for the loader fix."
}

if (-not (Test-Path $stage)) {
  throw "No staged BPLs at $stage. Run scripts\build-packages.ps1 first."
}

# Discover which versions are staged (folder holds the design package).
$staged = $Supported | Where-Object {
  Test-Path (Join-Path (Join-Path $stage $_) 'Aefos.OTA.Chat.bpl')
}
if (-not $staged) {
  throw "No version is staged under $stage. Run scripts\build-packages.ps1 (and, for " +
        "Delphi 11, copy the VM's installer\bpl\22.0 folder here)."
}

$wv2 = Get-WebView2Loader
Write-Host "WebView2Loader.dll: $wv2" -ForegroundColor DarkGray

foreach ($v in $staged) {
  $dir = Join-Path $stage $v
  $missing = $Bpls | Where-Object { -not (Test-Path (Join-Path $dir $_)) }
  if ($missing) {
    throw "Delphi ${v}: staged folder is missing $($missing.Count) BPL(s): $($missing -join ', '). " +
          "Re-run scripts\build-packages.ps1 -Version $v on the machine that has it."
  }
  Copy-Item $wv2 $dir -Force   # ensure the loader is present (VM build may lack it)
  Write-Host "  ok  Delphi $v  ($($Bpls.Count) BPLs + WebView2Loader.dll)" -ForegroundColor Green

  # Delphi 13's 64-bit IDE, when its packages were built (-Platform Win64x). It is
  # a separate set: a design-time BPL loads into the IDE PROCESS, so the Win32 ones
  # above are invisible to bin64\bds.exe.
  $x64Dir = Join-Path $dir 'Win64x'
  if (Test-Path (Join-Path $x64Dir 'Aefos.OTA.Chat.bpl')) {
    $missing64 = $Bpls | Where-Object { -not (Test-Path (Join-Path $x64Dir $_)) }
    if ($missing64) {
      throw "Delphi $v/Win64x: staged folder is missing $($missing64.Count) BPL(s): " +
            "$($missing64 -join ', '). Re-run build-packages.ps1 -Version $v -Platform Win64x."
    }
    # A 64-bit IDE process cannot bind the 32-bit loader RAD Studio ships, and RAD
    # Studio has no x64 one (verified: nothing under any bin64). It comes from the
    # same place the Lazarus 64-bit payload gets it -- fetched from Microsoft's
    # NuGet package, machine word verified. Without it the chat would silently fall
    # back to plain text in the 64-bit IDE only.
    $loader64 = Join-Path (Split-Path -Parent $here) 'installer\lazarus\redist\x86_64\WebView2Loader.dll'
    if (-not (Test-Path $loader64)) {
      & (Join-Path (Split-Path -Parent $here) 'scripts\fetch-webview2-loader.ps1') -Arch x86_64 | Out-Host
    }
    if (Test-Path $loader64) {
      Copy-Item $loader64 $x64Dir -Force
      Write-Host "  ok  Delphi $v/Win64x  ($($Bpls.Count) BPLs + x64 WebView2Loader.dll)" -ForegroundColor Green
    } else {
      throw "Delphi $v/Win64x: no x64 WebView2Loader.dll. See " +
            "installer\lazarus\redist\x86_64\README.md."
    }
  }
}

# Bundled third-party AI CLIs. On release pass -FetchClis to stage the CURRENT
# upstream binaries; otherwise we just report whatever is already staged. The
# installer omits any CLI not present here (skipifsourcedoesntexist), so a build
# with none staged is valid -- it ships the plugin + AefosAgent.exe alone.
$cliDir = Join-Path $here 'redist\cli'
if ($FetchClis) {
  Write-Host "Fetching current AI CLIs into redist\cli ..." -ForegroundColor Cyan
  & (Join-Path $here 'fetch-clis.ps1')
}
$cliStaged = @()
if (Test-Path $cliDir) {
  $cliStaged = @(Get-ChildItem -Path $cliDir -Filter '*.exe' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name })
}
if ($cliStaged.Count -gt 0) {
  Write-Host "Bundled CLIs: $($cliStaged -join ', ')" -ForegroundColor Green
} else {
  Write-Host "Bundled CLIs: none staged (installer ships without them). Pass -FetchClis to bundle." -ForegroundColor DarkYellow
}

# The Desktop MCP is an ADDON: it is published in the addons repository and
# obtained with `aefos install desktop`, binary included. Only the source of its
# server executable lives here (mcps\desktop), so this installer does not bundle
# it offline. The .iss staging lines are skipifsourcedoesntexist, so a build
# without a packed dist simply ships online-only.

# Locate ISCC.
if (-not $Iscc) {
  foreach ($c in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'))) {
    if (Test-Path $c) { $Iscc = $c; break }
  }
}
if (-not (Test-Path $Iscc)) {
  throw "ISCC not found at '$Iscc'. Pass -Iscc with the Inno Setup path."
}

Write-Host "Compiling installer (versions: $($staged -join ', '))..." -ForegroundColor Cyan
& $Iscc $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed (exit $LASTEXITCODE)." }

Write-Host "Done -> $(Join-Path $here 'Output')" -ForegroundColor Green
