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
    17.0 = 10 Seattle  18.0 = 10.1 Berlin  19.0 = 10.2 Tokyo  20.0 = 10.3 Rio
    21.0 = 10.4 Sydney  22.0 = Delphi 11    23.0 = Delphi 12    37.0 = Delphi 13
    (the one list: scripts\aefos-ide-versions.ps1)

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

. (Join-Path (Split-Path -Parent $here) 'scripts\aefos-ide-versions.ps1')
$Supported = $script:AefosIdeSupported
# Base names. Each staged file carries the IDE's package suffix
# (Aefos.MCP.Core230.bpl for Seattle, ...290 for Athens) so that two RAD Studios
# on one machine can no longer answer for each other's packages.
$BplNames = @(
  'Aefos.Harness', 'Aefos.Providers',
  'Aefos.WebView', 'Aefos.Tools', 'Aefos.MCP.Core',
  'Aefos.MCP.Tools.OTA', 'Aefos.Data', 'Aefos.OTA.Chat',
  'Aefos.OTA.Terminal', 'dclAefosWebView'
)

function Get-StagedSuffix {
  <#
    .SYNOPSIS
      The package suffix of an already-staged payload folder, read from the files.

    .DESCRIPTION
      Deliberately NOT Get-AefosIdePackageSuffix: that one asks the IDE, and the
      IDE whose payload this is may not exist on this machine at all - old-version
      payloads are built in a VM and the folder copied over. What is on disk is
      the only thing true here.

      Returns an empty string for a payload built before the suffix existed, which
      the caller must refuse rather than ship.
  #>
  param([Parameter(Mandatory = $true)][string] $Dir)
  $f = Get-ChildItem $Dir -Filter 'Aefos.OTA.Chat*.bpl' -ErrorAction SilentlyContinue |
       Select-Object -First 1
  if (-not $f) { return $null }
  if ($f.Name -match '^Aefos\.OTA\.Chat(\d*)\.bpl$') { return $Matches[1] }
  return $null
}

# WebView2Loader.dll is a Microsoft component (version-independent, x86). We ship
# it beside our BPLs and point the RTL at it by full path (SetWebView2Path). Source
# it from any installed RAD Studio bin (Delphi 12's bin lacks it; Delphi 13 has it).
function Get-WebView2Loader {
  foreach ($v in $script:AefosIdeVersionsNewestFirst) {
    $p = Join-Path ${env:ProgramFiles(x86)} "Embarcadero\Studio\$v\bin\WebView2Loader.dll"
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

# Discover which versions are staged (folder holds the design package, under
# whatever suffix that IDE gives it).
$staged = $Supported | Where-Object {
  $d = Join-Path $stage $_
  (Test-Path $d) -and (Get-ChildItem $d -Filter 'Aefos.OTA.Chat*.bpl' -ErrorAction SilentlyContinue)
}
if (-not $staged) {
  throw "No version is staged under $stage. Run scripts\build-packages.ps1 (and, for " +
        "an IDE that lives in a VM, copy that machine's installer\bpl\<ver> folder here)."
}

# The build scripts accept every version in aefos-ide-versions.ps1, but Aefos.iss
# carries a hand-written payload block per version (#define Ver...). So a version
# can be built and staged while the .iss knows nothing about it - and the
# installer would compile happily, just without those BPLs. Refuse to be quiet
# about it: that is the same shape of silence that lost the Desktop MCP.
$issText  = Get-Content -LiteralPath $iss -Raw
$issKnows = @([regex]::Matches($issText, '(?m)^#define\s+Ver\w+\s+"([\d.]+)"') |
              ForEach-Object { $_.Groups[1].Value })
$orphans  = @($staged | Where-Object { $issKnows -notcontains $_ })
if ($orphans.Count -gt 0) {
  Write-Host ""
  Write-Host "STAGED BUT NOT PACKAGED: $($orphans -join ', ')" -ForegroundColor Yellow
  foreach ($o in $orphans) {
    Write-Host "  $o ($(Get-AefosIdeProductName $o)) has BPLs in installer\bpl\$o, but Aefos.iss" -ForegroundColor Yellow
    Write-Host "  has no payload block for it - those BPLs will NOT ship." -ForegroundColor Yellow
  }
  Write-Host "  Add a #define Ver.. plus its [Files]/[Components] block to Aefos.iss." -ForegroundColor Yellow
  Write-Host ""
  $staged = @($staged | Where-Object { $issKnows -contains $_ })
  if (-not $staged) { throw "Nothing left to package: every staged version is unknown to Aefos.iss." }
}

# Aefos.iss names every payload file literally, suffix included, through a
# per-version #define. That is a second copy of a number the compiler already
# decided - so rather than trust the two to stay in step, read both and refuse to
# build when they disagree. A wrong suffix here does not fail loudly on its own:
# the [Files] entry would simply point at a name nothing produced.
$issSuffixes = @{}
foreach ($m in [regex]::Matches($issText, '(?m)^#define\s+Ver(\w+)\s+"([\d.]+)"')) {
  $key = $m.Groups[1].Value
  $s = [regex]::Match($issText, "(?m)^#define\s+Suf$key\s+`"(\d+)`"")
  if ($s.Success) { $issSuffixes[$m.Groups[2].Value] = $s.Groups[1].Value }
}

$wv2 = Get-WebView2Loader
Write-Host "WebView2Loader.dll: $wv2" -ForegroundColor DarkGray

foreach ($v in $staged) {
  $dir = Join-Path $stage $v
  $suffix = Get-StagedSuffix $dir
  if ([string]::IsNullOrEmpty($suffix)) {
    throw ("Delphi ${v}: the staged BPLs have no version suffix, so this payload predates " +
           "Aefos.LibSuffix.inc. Re-run scripts\build-packages.ps1 -Version $v on the machine " +
           "that has that IDE; shipping unsuffixed BPLs puts the cross-version collision back.")
  }
  if ($issSuffixes.ContainsKey($v) -and $issSuffixes[$v] -ne $suffix) {
    throw ("Delphi ${v}: staged BPLs carry suffix $suffix but Aefos.iss declares " +
           "$($issSuffixes[$v]). One of the two is wrong - the installer would package file " +
           "names that do not exist.")
  }
  $missing = $BplNames | Where-Object { -not (Test-Path (Join-Path $dir "$_$suffix.bpl")) }
  if ($missing) {
    throw "Delphi ${v}: staged folder is missing $($missing.Count) BPL(s): $(($missing | ForEach-Object { "$_$suffix.bpl" }) -join ', '). " +
          "Re-run scripts\build-packages.ps1 -Version $v on the machine that has it."
  }
  Copy-Item $wv2 $dir -Force   # ensure the loader is present (VM build may lack it)
  Write-Host "  ok  Delphi $v  ($($BplNames.Count) BPLs, suffix $suffix + WebView2Loader.dll)" -ForegroundColor Green

  # Delphi 13's 64-bit IDE, when its packages were built (-Platform Win64). It is
  # a separate set: a design-time BPL loads into the IDE PROCESS, so the Win32 ones
  # above are invisible to bin64\bds.exe.
  $x64Dir = Join-Path $dir 'Win64'
  if ((Test-Path $x64Dir) -and (Get-ChildItem $x64Dir -Filter 'Aefos.OTA.Chat*.bpl' -ErrorAction SilentlyContinue)) {
    # Same suffix as Win32 on purpose: Embarcadero ships rtl290.bpl in both bin and
    # bin64, telling the two bitnesses apart by FOLDER rather than by name.
    $missing64 = $BplNames | Where-Object { -not (Test-Path (Join-Path $x64Dir "$_$suffix.bpl")) }
    if ($missing64) {
      throw "Delphi $v/Win64: staged folder is missing $($missing64.Count) BPL(s): " +
            "$(($missing64 | ForEach-Object { "$_$suffix.bpl" }) -join ', '). Re-run build-packages.ps1 -Version $v -Platform Win64."
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
      Write-Host "  ok  Delphi $v/Win64  ($($BplNames.Count) BPLs, suffix $suffix + x64 WebView2Loader.dll)" -ForegroundColor Green
    } else {
      throw "Delphi $v/Win64: no x64 WebView2Loader.dll. See " +
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

# The Desktop MCP is an ADDON: its binary travels INSIDE the addon zip, never as
# a loose file of this installer, so it arrives only when the addon is installed.
# scripts\pack-desktop-addon.ps1 packs the offline copy and build-packages.ps1
# runs it, so a normal build has one staged and the installer seeds it with no
# download.
#
# Report what is actually staged. The .iss lines are skipifsourcedoesntexist, so
# a missing dist still builds - it just silently ships online-only, and "silently"
# is exactly how this went unnoticed once. Say it out loud instead.
$desktopDist = Join-Path (Split-Path -Parent $here) 'mcps\desktop\dist\registry.json'
if (Test-Path $desktopDist) {
  $desktopEntry = (Get-Content -LiteralPath $desktopDist -Raw | ConvertFrom-Json).addons |
                  Where-Object { $_.slug -eq 'desktop' } | Select-Object -First 1
  Write-Host "Bundled Desktop MCP addon: v$($desktopEntry.version) (installs offline)" -ForegroundColor Green
} else {
  Write-Host "Bundled Desktop MCP addon: NONE staged - the installer will ship ONLINE-ONLY," -ForegroundColor Yellow
  Write-Host "  so a machine with no network gets no desktop tools. Run scripts\build-desktop-mcp.ps1" -ForegroundColor Yellow
  Write-Host "  then scripts\pack-desktop-addon.ps1 (build-packages.ps1 does both)." -ForegroundColor Yellow
}

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
