<#
  Builds AND stages the Aefos package group for one or more RAD Studio versions.

  The same .dproj files target every supported Delphi: the version is chosen by
  which rsvars.bat (i.e. which $(BDS)) drives msbuild -- the projects use $(BDS)
  macros, so nothing in them is version-specific. We build Win32/Release only
  (the design-time BPLs load into the 32-bit IDE) and stage the built BPLs into
  installer\bpl\<ver>\ so installer\build-installer.ps1 can package them.

  Supported design-time versions (the only ones that ship a plugin) live in ONE
  place -- scripts\aefos-ide-versions.ps1 -- which this script dot-sources. Adding
  a Delphi is a row there, not an edit here. Today: 10 Seattle (17.0) through 13
  (37.0).

  Reaching back to Seattle is deliberate and cheap: nothing in the RTL Aefos uses
  is newer than 2015 (System.Net.HttpClient and System.Hash arrived in XE8, which
  Seattle ships), the WebView2 layer is our own COM import rather than Vcl.Edge
  (which only exists from 10.4), and the source is free of inline var by house
  rule. The one unit that is newer -- ToolsAPI.Editor, Delphi 12 -- is gated by
  {$IF CompilerVersion >= 36} around the WHOLE unit, because gating just the call
  is not enough when the .dpk still lists it in `contains`.

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
  # Keep in step with scripts\aefos-ide-versions.ps1 -- ValidateSet needs literals
  # (it is evaluated at parse time), so this is the one list that cannot be
  # computed. The check right after the dot-source fails loudly if the two drift.
  [ValidateSet('17.0', '18.0', '19.0', '20.0', '21.0', '22.0', '23.0', '37.0', 'all')]
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
# Lower-case 'packages': the tree was renamed and git tracks it that way. Windows
# would not care; a case-sensitive checkout would fail to find the group project.
$grp   = Join-Path $root 'packages\Delphi\AefosGroup.groupproj'
$stage = Join-Path $root 'installer\bpl'
if (-not (Test-Path $grp)) { throw "Group project not found: $grp" }

. (Join-Path $PSScriptRoot 'aefos-ide-versions.ps1')
$Supported = $script:AefosIdeSupported

# The ValidateSet above is literal by necessity. Prove it still matches the one
# list, so a version added there can never be silently rejected here.
$declared = @('17.0', '18.0', '19.0', '20.0', '21.0', '22.0', '23.0', '37.0')
$drift = @(Compare-Object -ReferenceObject $declared -DifferenceObject $Supported)
if ($drift.Count -gt 0) {
  throw ("-Version's ValidateSet and aefos-ide-versions.ps1 disagree: {0}. Update the ValidateSet literal." -f
         (($drift | ForEach-Object { "$($_.InputObject) ($($_.SideIndicator))" }) -join ', '))
}
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
  $targets = Get-AefosInstalledIdeVersions
  if (-not $targets) { throw "No supported RAD Studio version is installed on this machine." }
  Write-Host ("Installed: " + (($targets | ForEach-Object { "$_ ($(Get-AefosIdeProductName $_))" }) -join ', ')) -ForegroundColor DarkGray
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

  # libvterm is C, so this needs the C RUNTIME HEADERS, which arrive with the
  # C++ Builder personality - not with Delphi. An IDE installed Delphi-only has
  # bcc32c.exe on PATH (so nothing looks wrong up front) and no include\windows\
  # crtl, and the build then dies with a wall of "'stdint.h' file not found" that
  # says nothing about the actual cause. Measured on 10.2 Tokyo installed without
  # C++: include\ holds Box2D, osx and windows, but no crtl and no dinkumware,
  # while 10 Seattle and 10.1 Berlin have both.
  #
  # Checked here rather than left to the compiler because the fix is an IDE
  # install option, and nobody guesses that from a missing standard header.
  $bdsRoot = Split-Path -Parent (Split-Path -Parent $Rsvars)
  $crtl = Join-Path $bdsRoot 'include\windows\crtl\stdint.h'
  if (-not (Test-Path $crtl)) {
    throw @"
This RAD Studio has no C runtime headers, so the vendored libvterm (C) cannot be
compiled: $crtl is missing.

That means the C++ Builder personality was not installed for this version. Delphi
alone ships bcc32c.exe but not its headers.

Fix: re-run the RAD Studio installer for this version and add C++ Builder (the
Windows 32-bit C++ target is enough). Then run this script again.
"@
  }

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
  $rsvars = Get-AefosRsVarsPath $v
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
    # Prepend MSBuild 4.0 when rsvars picked an older one.
    #
    # Seattle's rsvars.bat sets FrameworkDir to .NET v3.5, i.e. MSBuild 3.5, which
    # is older than several things the toolchain now takes for granted.
    #
    # The first casualty was AfterTargets (MSBuild 4.0), which our staging target
    # used to carry: every package died with MSB4066 "the attribute AfterTargets is
    # unrecognized" before a line of Pascal was read. That one is now fixed at the
    # source - the .dproj files hook $(BuildDependsOn) instead, an idiom 3.5 and
    # every version since understand - because a build started from INSIDE the old
    # IDE hosts its own 3.5 engine and can never be handed a different msbuild.
    #
    # This override stays regardless: it is proven on Seattle (same projects, same
    # 30.0 compiler, MSBuild 4.0 - builds clean), and giving the command line the
    # modern engine costs nothing while removing a whole class of 3.5-era surprise.
    $msbuildPrefix = ''
    $msOverride = Get-AefosMSBuildOverrideDir $rsvars
    if ($msOverride -ne '') {
      if (-not (Test-Path (Join-Path $msOverride 'MSBuild.exe'))) {
        throw ("Delphi $v's rsvars does not provide a usable msbuild (declared " +
               "$(Get-AefosFrameworkVersion $rsvars)), and there is none at $msOverride either.")
      }
      Write-Host "  rsvars msbuild unusable -- using $msOverride." -ForegroundColor DarkGray
      $msbuildPrefix = "set PATH=$msOverride;%PATH% && "
    }
    # C++ header output directory.
    #
    # With the C++ Builder personality installed, the Delphi compiler also emits a
    # .hpp per unit so C++ code could consume it, and it will NOT create the
    # output folder itself: 10.3 Rio failed with
    #   F2039: Could not create output file '..\..\Bin\Win32\Release\<unit>.hpp'
    # which reads like a locked or missing BPL and is really a missing directory.
    #
    # Created rather than switched off on purpose: those headers are exactly what
    # a future C++Builder edition needs (issue #26), so suppressing them now would
    # be work to undo later. Empty directories cost nothing.
    $hppOut = Join-Path $root "Bin\$plat\$Config"
    New-Item -ItemType Directory -Force $hppOut | Out-Null

    # Static SQLite: LOOK, do not guess.
    #
    # FireDAC.Phys.SQLiteWrapper.Stat is what links the SQLite engine into
    # Aefos.Data instead of loading sqlite3.dll at run time, and it does not exist
    # in every FireDAC. Measured: absent in 10 Seattle AND in 10.1 Berlin, present
    # in Delphi 11. An earlier CompilerVersion guess put the boundary just above
    # Seattle and Berlin proved it wrong the day it was installed - hence this.
    #
    # The define is NEGATIVE on purpose. Building from the IDE passes no defines at
    # all, so the default (no symbol) has to be the CORRECT behaviour for every
    # modern Delphi - static linkage. Only a command-line build that has looked at
    # the lib folder and found nothing switches it off.
    $sqliteDefine = ''
    $needsSqliteDll = $false
    $statDcu = Join-Path (Split-Path -Parent (Split-Path -Parent $rsvars)) `
                         "lib\$($plat.ToLower())\release\FireDAC.Phys.SQLiteWrapper.Stat.dcu"
    if (-not (Test-Path $statDcu)) {
      Write-Host "  no static SQLite in this FireDAC -- Aefos.Data will load sqlite3.dll at run time." -ForegroundColor DarkYellow
      $sqliteDefine = '/p:DCC_Define=AEFOS_NO_STATIC_SQLITE '
      $needsSqliteDll = $true
    }
    # Say WHERE the BPLs go, rather than trusting the IDE's per-user state.
    #
    # A .dproj resolves its output folder through EnvOptions.proj, which the IDE
    # writes the first time it is RUN. On a machine where a version was installed
    # but never opened - exactly the case while walking old IDEs - msbuild warns
    # "Expected configuration file missing" and then quietly writes the BPLs next
    # to the .dproj instead. The build looks perfect: every unit compiles, no
    # error, and the staging step then reports ten missing BPLs.
    #
    # Passing DCC_BplOutput makes the destination a fact of the build instead of a
    # property of whoever's profile ran it.
    $bplOut = Get-PublicBplDir $v $plat
    New-Item -ItemType Directory -Force $bplOut | Out-Null

    $cmd = "`"$rsvars`" && $msbuildPrefix" +
           "msbuild `"$grp`" /t:Build /p:Config=$Config /p:Platform=$plat " +
           "/p:DCC_BplOutput=`"$bplOut`" " +
           "$sqliteDefine/p:DCC_ForceExecute=true /v:minimal /nologo"
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

    # Whoever measured also provisions. A build without static SQLite produces a
    # BPL that loads sqlite3.dll at RUN time, so shipping it without the DLL would
    # install cleanly and then fail the first time the chat opens its database -
    # the worst kind of failure, far from its cause. Staging it here means the
    # installer just copies whatever this folder holds.
    if ($needsSqliteDll) {
      $dllSrc = Join-Path $root 'source\data\ThirdParty\sqlite\bin\sqlite3.dll'
      if ($plat -ne 'Win32') {
        $dllSrc = Join-Path $root 'source\data\ThirdParty\sqlite\bin\x86_64\sqlite3.dll'
      }
      if (-not (Test-Path $dllSrc)) {
        throw ("Delphi $v/${plat} has no static SQLite, so it needs sqlite3.dll beside the BPLs, " +
               "and none was found at $dllSrc.")
      }
      Copy-Item $dllSrc $dst -Force
      Write-Host "  +   sqlite3.dll staged (this IDE has no static SQLite)" -ForegroundColor DarkYellow
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

# Build the out-of-process Desktop MCP server and pack it as the OFFLINE addon
# dist the installer seeds from. This belongs in the standard build: it was not
# here, and the consequence was silent - installer\Aefos.iss stages the dist with
# skipifsourcedoesntexist, so a tree that never produced one shipped online-only
# WITHOUT saying so, and the desktop tools were simply absent on a machine with
# no network.
#
# One binary serves every IDE version (no ToolsAPI, no VCL, no designide), so it
# is built once rather than per RAD Studio version like the BPLs.
& (Join-Path $PSScriptRoot 'build-desktop-mcp.ps1') | Out-Host
$desktopExe = Join-Path $root 'mcps\desktop\bin\AefosDesktopMcp.exe'
if (-not (Test-Path $desktopExe)) { throw "Desktop MCP not produced: $desktopExe" }
Write-Host "  OK  AefosDesktopMcp.exe" -ForegroundColor Green

& (Join-Path $PSScriptRoot 'pack-desktop-addon.ps1') -CheckGallery | Out-Host
$desktopRegistry = Join-Path $root 'mcps\desktop\dist\registry.json'
if (-not (Test-Path $desktopRegistry)) { throw "Desktop MCP offline dist not produced: $desktopRegistry" }
Write-Host "  OK  desktop addon offline dist -> mcps\desktop\dist" -ForegroundColor Green

Write-Host "Next: installer\build-installer.ps1 (compiles the installer from installer\bpl\<ver>)." -ForegroundColor DarkGray
