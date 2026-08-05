<#
  Builds AND stages the Aefos package group for one or more RAD Studio versions.

  The same .dproj files target every supported Delphi: the version is chosen by
  which rsvars.bat (i.e. which $(BDS)) drives msbuild -- the projects use $(BDS)
  macros, so nothing in them is version-specific. We build Win32/Release only
  (the design-time BPLs load into the 32-bit IDE) and stage the built BPLs into
  installer\bpl\<ver>\ so installer\build-installer.ps1 can package them.

  Supported design-time versions (the only ones that ship a plugin):
    22.0 = Delphi 11 Alexandria (compiler 35.0)
    23.0 = Delphi 12 Athens     (compiler 36.0)
    37.0 = Delphi 13            (compiler 37.0)

  Cross-machine note: a version builds only where its RAD Studio is installed AND
  registered (command-line dcc needs the per-user product registry). Build each
  version on the machine that has it -- e.g. Delphi 11 inside its VM -- then bring
  that machine's installer\bpl\<ver>\ folder over to whoever compiles the .iss.

  IMPORTANT -- DCC_ForceExecute=true: older command-line msbuild (seen on Delphi
  12) otherwise fails with "DCC command-line too long" (MSB6003). ForceExecute
  routes the long search paths through a compiler commands file. Harmless on
  newer versions, so we pass it for every version (one code path).

  Usage:
    pwsh -File scripts\build-packages.ps1                 # all installed versions
    pwsh -File scripts\build-packages.ps1 -Version 22.0   # just Delphi 11 (in its VM)
    pwsh -File scripts\build-packages.ps1 -Config Debug
#>
[CmdletBinding()]
param(
  [ValidateSet('22.0', '23.0', '37.0', 'all')]
  [string]$Version = 'all',
  [ValidateSet('Release', 'Debug')]
  [string]$Config = 'Release',
  # Win32 is the classic IDE. Win64 is Delphi 13's separate 64-bit IDE
  # (bin64\bds.exe) -- a design-time BPL must match the process bitness, so
  # the two are different builds, not one build installed twice.
  [ValidateSet('Win32', 'Win64', 'all')]
  [string]$Platform = 'Win32'
)

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
$grp   = Join-Path $root 'Packages\Delphi\AefosGroup.groupproj'
$stage = Join-Path $root 'installer\bpl'
if (-not (Test-Path $grp)) { throw "Group project not found: $grp" }

$Supported = @('22.0', '23.0', '37.0')   # 22.0 = D11, 23.0 = D12, 37.0 = D13
$Bpls = @(
  'Aefos.Harness.bpl', 'Aefos.Providers.bpl',
  'Aefos.WebView.bpl', 'Aefos.Tools.bpl', 'Aefos.MCP.Core.bpl',
  'Aefos.MCP.Tools.OTA.bpl', 'Aefos.Data.bpl', 'Aefos.OTA.Chat.bpl',
  'Aefos.OTA.Terminal.bpl', 'dclAefosWebView.bpl'
)

function Get-PublicBplDir([string]$Ver, [string]$Plat) {
  $base = Join-Path $env:PUBLIC "Documents\Embarcadero\Studio\$Ver\Bpl"
  if ($Plat -eq 'Win32') { $base } else { Join-Path $base $Plat }
}

# Resolve the version list. 'all' = every supported version installed on THIS
# machine (rsvars present); explicit version is taken as-is.
if ($Version -eq 'all') {
  $targets = $Supported | Where-Object {
    Test-Path "C:\Program Files (x86)\Embarcadero\Studio\$_\bin\rsvars.bat"
  }
  if (-not $targets) { throw "No supported RAD Studio version is installed on this machine." }
} else {
  $targets = @($Version)
}

# libvterm is vendored C, linked into the Terminal BPL via {$L}. Its objects are
# build output and therefore gitignored (source\terminal\ThirdParty\libvterm\
# .gitignore), so a FRESH checkout -- a clone, a CI runner, an agent's git
# worktree -- has the sources but no .obj/.lib and the Terminal BPL fails to link.
# Building them is not optional and needs nothing we don't already have (bcc32c
# ships with RAD Studio; rsvars puts it on PATH), so the build heals itself
# instead of demanding a manual step nobody remembers.
function Ensure-LibVTerm([string]$Rsvars, [string]$Plat) {
  $vtermDir = Join-Path $root 'source\terminal\ThirdParty\libvterm'
  # The one artefact that matters: Core.LibVTerm.pas links exactly this via {$L}
  # (a unity object -- the per-file .obj's alone don't satisfy the single-pass linker).
  # bcc32c emits 32-bit OMF into obj\; bcc64 emits ELF x64 into obj\Win64\.
  # Each linker rejects the other's output with E2045, which reads like a
  # corrupt file and is really the wrong architecture -- hence two folders.
  if ($Plat -eq 'Win32') {
    $unity = Join-Path $vtermDir 'obj\libvterm_unity.obj'
  } else {
    $unity = Join-Path $vtermDir 'obj\Win64\libvterm_unity.o'
  }
  if (Test-Path $unity) { return }
  Write-Host "  libvterm objects missing -- building them (fresh checkout)." -ForegroundColor Yellow
  $bat = Join-Path $vtermDir 'build-objs.bat'
  if (-not (Test-Path $bat)) { throw "libvterm build-objs.bat not found at $bat" }
  cmd /c "`"$Rsvars`" && pushd `"$vtermDir`" && call `"$bat`" $Plat && popd"
  if (-not (Test-Path $unity)) {
    throw "libvterm build produced no unity object for $Plat -- the Terminal BPL cannot link."
  }
}

$plats = if ($Platform -eq 'all') { @('Win32', 'Win64') } else { @($Platform) }

$built = @()
foreach ($v in $targets) {
  $rsvars = "C:\Program Files (x86)\Embarcadero\Studio\$v\bin\rsvars.bat"
  if (-not (Test-Path $rsvars)) {
    Write-Warning "Delphi $v not installed (no rsvars at $rsvars) -- skipping."
    continue
  }
  foreach ($plat in $plats) {
    # Only Delphi 13 has a 64-bit IDE to load a Win64 package.
    if ($plat -eq 'Win64' -and $v -ne '37.0') {
      Write-Host "  --  Delphi $v has no 64-bit IDE -- skipping Win64." -ForegroundColor DarkGray
      continue
    }
    Ensure-LibVTerm $rsvars $plat
    Write-Host "=== Building Aefos group for Delphi $v ($Config/$plat) ===" -ForegroundColor Cyan
    $cmd = "`"$rsvars`" && msbuild `"$grp`" /t:Build /p:Config=$Config /p:Platform=$plat " +
           "/p:DCC_ForceExecute=true /v:minimal /nologo"
    cmd /c $cmd
    if ($LASTEXITCODE -ne 0) { throw "Build FAILED for Delphi $v/$plat (exit $LASTEXITCODE)." }

    # Stage into installer\bpl\<ver>\ for Win32, <ver>\Win64\ for the 64-bit
    # IDE -- the installer copies each set to the directory its IDE reads.
    $src = Get-PublicBplDir $v $plat
    $dst = Join-Path $stage $v
    if ($plat -ne 'Win32') { $dst = Join-Path $dst $plat }
    New-Item -ItemType Directory -Force $dst | Out-Null
    $missing = @()
    foreach ($b in $Bpls) {
      $f = Join-Path $src $b
      if (Test-Path $f) { Copy-Item $f $dst -Force } else { $missing += $b }
    }
    if ($missing.Count -gt 0) {
      throw "Delphi $v/${plat}: built but $($missing.Count) BPL(s) not found in $src : $($missing -join ', ')."
    }
    Write-Host "  OK  Delphi $v/$plat  ($($Bpls.Count) BPLs)" -ForegroundColor Green
    $built += "$v/$plat"
  }
}

if ($built.Count -eq 0) { throw "Nothing built (none of $($targets -join ', ') is installed)." }
Write-Host "Built + staged: $($built -join ', ')" -ForegroundColor Green

# Build + provision the Agent CLI that drives local models (Phase D). It is one
# console exe for every RAD Studio version, so build it once, stage it next to
# the BPLs (the installer ships it), and copy it to the per-user bin the plugin
# resolves first (%APPDATA%\Aefos\bin) so a dev-installed IDE finds it now.
& (Join-Path $PSScriptRoot 'build-agent-cli.ps1') | Out-Host
$agentExe = Join-Path $root 'cli\bin\AefosAgent.exe'
if (-not (Test-Path $agentExe)) { throw "Agent CLI not produced: $agentExe" }
foreach ($v in $built) { Copy-Item $agentExe (Join-Path $stage $v) -Force }
$binDir = Join-Path $env:APPDATA 'Aefos\bin'
New-Item -ItemType Directory -Force $binDir | Out-Null
Copy-Item $agentExe $binDir -Force
Write-Host "  OK  AefosAgent.exe -> installer\bpl\<ver>\ + $binDir" -ForegroundColor Green

# Build + provision the addon manager (aefos.exe) the same way: one console exe
# for every RAD Studio version, staged next to the BPLs and dropped into the
# per-user bin so `aefos install <slug>` works right after a dev install.
& (Join-Path $PSScriptRoot 'build-aefos-cli.ps1') | Out-Host
$aefosExe = Join-Path $root 'cli\bin\aefos.exe'
if (-not (Test-Path $aefosExe)) { throw "Addon manager not produced: $aefosExe" }
foreach ($v in $built) { Copy-Item $aefosExe (Join-Path $stage $v) -Force }
Copy-Item $aefosExe $binDir -Force
Write-Host "  OK  aefos.exe -> installer\bpl\<ver>\ + $binDir" -ForegroundColor Green

Write-Host "Next: installer\build-installer.ps1 (compiles the installer from installer\bpl\<ver>)." -ForegroundColor DarkGray
