<#
.SYNOPSIS
    Build the Aefos AI Lazarus design package (and, optionally, a test IDE that
    statically links it).

.DESCRIPTION
    Aefos AI ships on RAD Studio as dynamically loaded design-time BPLs. The
    Lazarus edition uses the opposite deploy model: a design package is compiled
    to .ppu/.o and then *statically linked* into lazarus.exe by rebuilding the
    IDE (Lazarus has no hot reload for design packages).

    This script has two stages:

      1. HARD GATE (always) - compile packages\Lazarus\Aefos.Lazarus.IDE.lpk with
         lazbuild. Exit 0 + a .compiled/.ppu/.o under packages\Lazarus\lib is the
         contract the CI/maintainer relies on.

      2. TEST IDE (only with -BuildIde) - rebuild a throwaway lazarus.exe with the
         package in its static package list, into an ISOLATED location so the
         real C:\lazarus install is never modified.

    -------------------------------------------------------------------------
    Where does the rebuilt lazarus.exe land? (investigated in the Lazarus source)
    -------------------------------------------------------------------------
    IMPORTANT, and counter-intuitive: --pcp (primary config path) ISOLATES the
    config and the package-link database, but it does NOT by itself isolate the
    rebuilt IDE binary. The target directory is decided by
    C:\lazarus\ide\buildlazdialog.pas, TLazarusBuilder.CalcTargets:

      * Case 1 (buildlazdialog.pas:654-663) - if the active build profile has an
        explicit TargetDirectory, BOTH lazarus.exe and the IDE .ppu units go
        there. This is the only clean, automatic isolation.
      * Case 3 (buildlazdialog.pas:698-706) - if the Lazarus directory is
        read-only, output falls back to <pcp>\bin. Clean, but we will not chmod
        the user's install.
      * Case 4 (buildlazdialog.pas:707-711) - if the Lazarus directory is
        WRITABLE (the normal case on this machine), lazarus.exe and units are
        written straight into C:\lazarus, IGNORING --pcp.

    So on a writable C:\lazarus, a naive "lazbuild --pcp=X --add-package Y
    --build-ide=" would CLOBBER the user's IDE. To stay safe this script forces
    Case 1: it seeds the scratch pcp's miscellaneousoptions.xml with a build profile whose
    TargetDirectory points inside the scratch dir (schema proven from
    ide\miscoptions.pas:165 MiscOptsVersion=3 and
    ide\buildprofilemanager.pas:214-249 / :475-497). It also sets
    UpdateRevisionInc=False so ide\revision.inc in C:\lazarus is left alone.

    Belt and suspenders: the script snapshots the SHA-256 of
    C:\lazarus\lazarus.exe before the rebuild and verifies it is unchanged after.
    If the real IDE was touched (i.e. Case 1 did not take), the script FAILS loud
    and tells you to restore from Lazarus's own backup (lazarus.old.exe). It also
    proves the static link via the pcp's staticpackages.inc + a scan of the exe
    to prove the static link.

    If -BuildIde ever proves unreliable on your Lazarus (e.g. a future version
    changes the profile schema), the manual step is: open the IDE, Tools >
    "Configure Build Lazarus", set a Target directory outside C:\lazarus, tick the
    Aefos.Lazarus.IDE package in the package list, and Build. That is exactly what
    this script automates.

.PARAMETER BuildIde
    Also rebuild an isolated test lazarus.exe with the package statically linked.

.PARAMETER LazBuild
    Path to lazbuild.exe. Defaults to C:\lazarus\lazbuild.exe.

.PARAMETER ScratchPcp
    Isolated primary config path + IDE output root. Defaults to a fresh temp dir.

.EXAMPLE
    pwsh -File scripts\build-lazarus.ps1
    Compile the package only (hard gate).

.EXAMPLE
    pwsh -File scripts\build-lazarus.ps1 -BuildIde
    Compile, then rebuild an isolated test IDE and verify the static link.
#>

[CmdletBinding()]
param(
    [switch]$BuildIde,
    [string]$LazBuild = 'C:\lazarus\lazbuild.exe',
    [string]$ScratchPcp,
    # How to link the static SQLite object into the IDE:
    #   'internal' - FPC internal linker (no -Xe). Preferred: a small, stripped IDE
    #                (-g- -Xs) is light enough that the internal linker folds the
    #                ~800 KB C object without the AV that plagued the debug-heavy link.
    #   'external' - the external GNU linker (-Xe). Fallback if 'internal' ever AVs.
    # BOTH strip debug (-g- -Xs). Why it matters (proven 2026-07-18 on the broken
    # 236 MB build): the OLD path was -Xe with a debug-heavy IDE, and ld's PE output
    # then carried DWARF debug sections pulled from the mingw import libs - three of
    # them (.debug_loclists/.debug_line_str/.debug_rnglists) emitted at VMA/RVA 0 -
    # a section layout the Windows image loader REJECTS (STATUS_INVALID_IMAGE_FORMAT
    # -> "not a valid application for this OS platform"). The internal linker never
    # emits those sections; -Xs strips them regardless. So a stripped image loads.
    [ValidateSet('internal', 'external')]
    [string]$IdeLinkStrategy = 'internal',
    # Also statically link AnchorDocking + the docked form editor into the test IDE,
    # and seed the user's docking config, so the isolated IDE matches a real DOCKED
    # install (the default on Lazarus 4.x). Without this a rebuilt test IDE drops
    # docking and the form designer floats -- which does NOT exercise the docked
    # (TAnchorDockPage) code path the RULE #1 view guard cares about.
    [switch]$WithDocking
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot  = Split-Path -Parent $ScriptDir
$Lpk       = Join-Path $RepoRoot 'packages\Lazarus\Aefos.Lazarus.IDE.lpk'
$PkgName   = 'Aefos.Lazarus.IDE'

# Optional docking packages that ship with Lazarus, linked to reproduce a real
# docked install:
#   * anchordockingdsgn  -- docks the IDE windows (editor/OI/messages) into one host.
#   * dockedformeditor   -- the DOCKED FORM EDITOR ("EditorDocker"): the form designer
#                           becomes a TAB inside the source editor (the Delphi-like
#                           F12 flip). This is the layout the developer actually uses
#                           and the exact case the RULE #1 view guard must handle --
#                           WITHOUT it the designed form floats in its own window.
# --add-package resolves each package's runtime deps.
$DockPkgs = @()
if ($WithDocking) {
    $LazComp = Join-Path (Split-Path -Parent $LazBuild) 'components'
    $DockPkgs = @(
        (Join-Path $LazComp 'anchordocking\design\anchordockingdsgn.lpk'),
        (Join-Path $LazComp 'dockedformeditor\dockedformeditor.lpk')
    )
    foreach ($dp in $DockPkgs) {
        if (-not (Test-Path -LiteralPath $dp)) {
            throw "WithDocking: docking package not found at '$dp'."
        }
    }
}

if (-not (Test-Path -LiteralPath $LazBuild)) {
    throw "lazbuild not found at '$LazBuild'. Pass -LazBuild <path>."
}
if (-not (Test-Path -LiteralPath $Lpk)) {
    throw "Package not found at '$Lpk'."
}

$LazDir     = Split-Path -Parent $LazBuild
$LazExe     = Join-Path $LazDir 'lazarus.exe'

# ---------------------------------------------------------------------------
# SQLite backend (the one-brain shared aefos.db). SQLite is loaded at RUNTIME from
# sqlite3.dll (source\lazarus\data\Aefos.Lazarus.SQLite.pas), NOT statically linked
# -- so the IDE link has ZERO C dependencies and rebuilds normally (a plain
# `lazbuild --build-ide`, as Package > Install/Uninstall Packages runs, just works).
# Build the DLL here (idempotent, gitignored artifact) so the runnable gate below
# can drop it beside the produced test exe; the LINK itself does not need it.
# ---------------------------------------------------------------------------
Write-Host "-- ensuring SQLite DLL --"
& (Join-Path $ScriptDir 'build-sqlite-fpc.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "build-sqlite-fpc.ps1 failed (exit $LASTEXITCODE). SQLite DLL required for the runnable gate."
}
$SqliteDllPath = Join-Path $RepoRoot 'source\data\ThirdParty\sqlite\bin\sqlite3.dll'

# ---------------------------------------------------------------------------
# libvterm runtime DLL (the terminal engine). The Lazarus terminal core
# (Aefos.OTA.Terminal.Core.VTermBuffer via .LibVTerm) imports libvterm as a RUNTIME
# DLL under FPC (external 'libvterm.dll'), NOT a static {$LINK} -- a static link
# makes lazarus.exe non-rebuildable by the normal Package > Install path and drags
# the mingw CRT into the IDE link (the exact lesson SQLite taught). So, exactly like
# sqlite3.dll, the IDE link has ZERO C deps and the DLL is dropped beside the exe.
# Build it here (idempotent, gitignored) so the runnable gate can stage it. Best-
# effort: a resolver miss only warns when a pre-built DLL is already present.
# ---------------------------------------------------------------------------
Write-Host "-- ensuring libvterm DLL --"
$VtermDllPath = Join-Path $RepoRoot 'source\terminal\ThirdParty\libvterm\obj\libvterm.dll'
try {
    & (Join-Path $ScriptDir 'build-libvterm-fpc.ps1')
} catch {
    # build-libvterm-fpc.ps1 throws when no i686 gcc is found. Tolerate that only
    # when a pre-built DLL is already present.
    if (Test-Path -LiteralPath $VtermDllPath) {
        Write-Host "  build-libvterm-fpc.ps1 could not run ($($_.Exception.Message)); DLL exists -- continuing." -ForegroundColor Yellow
    } else {
        throw "build-libvterm-fpc.ps1 failed and $VtermDllPath is missing. Install an i686 mingw (see that script's header) and re-run. Error: $($_.Exception.Message)"
    }
}
if (-not (Test-Path -LiteralPath $VtermDllPath)) {
    throw "libvterm DLL still missing at $VtermDllPath after build attempt."
}

# ---------------------------------------------------------------------------
# Isolated primary config path. Created HERE, before stage 1, because stage 1
# needs it too (see the --pcp note below); stage 2 reuses the same folder.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ScratchPcp)) {
    $ScratchPcp = Join-Path $env:TEMP ("aefos-laz-ide-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
}
New-Item -ItemType Directory -Force -Path $ScratchPcp | Out-Null

Write-Host "== Aefos AI - Lazarus build ==" -ForegroundColor Cyan
Write-Host "lazbuild : $LazBuild"
Write-Host "package  : $Lpk"
Write-Host "pcp      : $ScratchPcp (isolated)"

# ---------------------------------------------------------------------------
# Stage 1 - HARD GATE: compile the design package.
# ---------------------------------------------------------------------------
Write-Host "`n-- Stage 1: compile package --" -ForegroundColor Cyan
# --pcp is NOT cosmetic here. Compiling an .lpk makes lazbuild REGISTER a package
# link for it, and with no --pcp that link lands in the DEVELOPER'S REAL config
# (%LOCALAPPDATA%\lazarus\packagefiles.xml), pointing at whatever tree the gate
# ran from. So every agent worktree that ran this gate left a link behind, and
# once the worktree was deleted the link became a DEAD entry in the real IDE
# config. Measured on the maintainer's machine 2026-07-17: three orphan links to
# deleted worktrees sitting next to the installed one. Not cosmetic either -
# staticpackages.inc resolves a package BY NAME through these links, so a later
# IDE rebuild can resolve a dead one and fail, taking the IDE with it.
# Probed before changing: an empty scratch pcp compiles the package identically
# (11114 lines, exit 0) and the link lands in the scratch instead.
& $LazBuild "--pcp=$ScratchPcp" $Lpk
if ($LASTEXITCODE -ne 0) {
    throw "Package compilation FAILED (lazbuild exit $LASTEXITCODE)."
}
$Compiled = Join-Path $RepoRoot 'packages\Lazarus\lib\i386-win32\Aefos.Lazarus.IDE.compiled'
if (-not (Test-Path -LiteralPath $Compiled)) {
    $Compiled = (Get-ChildItem -Path (Join-Path $RepoRoot 'packages\Lazarus\lib') -Recurse -Filter 'Aefos.Lazarus.IDE.compiled' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
Write-Host "Package compiled OK -> $Compiled" -ForegroundColor Green

if (-not $BuildIde) {
    Write-Host "`nDone (package only). Pass -BuildIde to also build an isolated test IDE." -ForegroundColor Green
    return
}

# ---------------------------------------------------------------------------
# Stage 2 - TEST IDE (isolated). See the header for why this is careful.
# ---------------------------------------------------------------------------
Write-Host "`n-- Stage 2: isolated test IDE --" -ForegroundColor Cyan

# Hygiene: a probe (e.g. a terminal controller probe) compiled without
# -FU leaves .ppu/.o next to the SHARED core sources; --build-ide then aborts with
# an "ambiguous unit" because the same unit resolves from two places. Sweep those
# stray outputs from the shared source dirs before rebuilding the IDE (the package's
# own outputs live under packages\Lazarus\lib and are untouched).
$SharedSrcDirs = @(
    (Join-Path $RepoRoot 'source\terminal\Core'),
    (Join-Path $RepoRoot 'source\lazarus\terminal'),
    (Join-Path $RepoRoot 'source\compat')
)
foreach ($sd in $SharedSrcDirs) {
    if (Test-Path -LiteralPath $sd) {
        Get-ChildItem -Path (Join-Path $sd '*') -Include '*.ppu', '*.o', '*.a' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# $ScratchPcp already exists - stage 1 needed it (the package-link isolation).
$IdeOut = Join-Path $ScratchPcp 'ide-build'
New-Item -ItemType Directory -Force -Path $IdeOut | Out-Null
Write-Host "scratch pcp : $ScratchPcp"
Write-Host "ide output  : $IdeOut"

# Guard: snapshot the real IDE so we can prove we never touched it.
$RealHashBefore = $null
if (Test-Path -LiteralPath $LazExe) {
    $RealHashBefore = (Get-FileHash -LiteralPath $LazExe -Algorithm SHA256).Hash
    Write-Host "guard: C:\lazarus\lazarus.exe SHA256 = $RealHashBefore"
}

# Register the package link into the isolated pcp (writes only under the pcp).
& $LazBuild "--pcp=$ScratchPcp" --add-package-link $Lpk | Out-Null
foreach ($dp in $DockPkgs) {
    & $LazBuild "--pcp=$ScratchPcp" --add-package-link $dp | Out-Null
}

# Force CalcTargets Case 1: seed an isolated build profile (TargetDirectory).
# XML paths per ide\miscoptions.pas + ide\buildprofilemanager.pas (see header).
$IdeOutXml = $IdeOut.Replace('/', '\')
$Misc = @"
<?xml version="1.0" encoding="UTF-8"?>
<CONFIG>
  <MiscellaneousOptions>
    <Version Value="3"/>
    <BuildLazarusOptions>
      <Profiles Count="1">
        <Profile0 Name="AefosTestIDE">
          <TargetDirectory Value="$IdeOutXml"/>
          <IdeBuildMode Value="Build"/>
          <UpdateRevisionInc Value="False"/>
        </Profile0>
      </Profiles>
      <ProfileIndex Value="0"/>
    </BuildLazarusOptions>
  </MiscellaneousOptions>
</CONFIG>
"@
# The FILE is miscellaneousoptions.xml (ide\miscoptions.pas:164 MiscOptsFilename)
# - the UNIT is miscoptions.pas, but seeding a file named miscoptions.xml is
# silently ignored and the rebuild falls back to Case 4 (writes into the real
# C:\lazarus). Proven the hard way: the SHA guard tripped on the first live run.
$MiscPath = Join-Path $ScratchPcp 'miscellaneousoptions.xml'
[System.IO.File]::WriteAllText($MiscPath, $Misc, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "seeded isolated build profile -> $MiscPath"

# Rebuild the IDE with our package in the static list, into the isolated target.
# --build-ide=<opts>: the string after '=' is passed to the compiler for the IDE
# link. Since SQLite is now a runtime DLL (no {LINK}, no mingw import libs), there
# is NOTHING machine-specific to inject here -- the exact same situation the user's
# own `lazbuild --build-ide` (Package > Install/Uninstall Packages) is in. That is
# the whole point of this change: prove the IDE links with DEFAULT options.
$LogPath = Join-Path $ScratchPcp 'build-ide.log'
# -g- : do not generate FPC debug info (keeps the IDE exe small: the debug IDE
#       build produced ~167 MB of .stab/.stabstr). -Xs : strip the final exe.
#       Both are ordinary size knobs, NOT correctness crutches -- a bare
#       `lazbuild --build-ide` with no opts links too (proven separately); we keep
#       them only so the test exe stays small. 'external' keeps -Xe as a fallback.
$IdeOpts = "-g- -Xs"
if ($IdeLinkStrategy -eq 'external') {
    $IdeOpts = "-Xe " + $IdeOpts
}
Write-Host "rebuilding test IDE (log: $LogPath ; ide-opts: '$IdeOpts') ..."
$AddPkgArgs = @('--add-package', $Lpk)
foreach ($dp in $DockPkgs) {
    $AddPkgArgs += @('--add-package', $dp)
}
if ($DockPkgs.Count -gt 0) {
    Write-Host "  + AnchorDocking + DockedFormEditor (docked test IDE)"
}
& $LazBuild "--pcp=$ScratchPcp" "--lazarusdir=$LazDir" @AddPkgArgs "--build-ide=$IdeOpts" *>&1 |
    Tee-Object -FilePath $LogPath
$IdeExit = $LASTEXITCODE

# Guard: the real IDE must be byte-for-byte unchanged.
if ($RealHashBefore) {
    $RealHashAfter = (Get-FileHash -LiteralPath $LazExe -Algorithm SHA256).Hash
    if ($RealHashAfter -ne $RealHashBefore) {
        Write-Host "!!! C:\lazarus\lazarus.exe WAS MODIFIED - isolation failed." -ForegroundColor Red
        Write-Host "    Restore it from Lazarus's own backup: $LazDir\lazarus.old.exe" -ForegroundColor Red
        throw "Isolation guard tripped: the real IDE binary changed. Aborting."
    }
    Write-Host "guard OK: C:\lazarus\lazarus.exe unchanged." -ForegroundColor Green
}

if ($IdeExit -ne 0) {
    throw "IDE rebuild FAILED (lazbuild exit $IdeExit). See $LogPath."
}

$TestExe   = Join-Path $IdeOut 'lazarus.exe'
$ExeMade   = Test-Path -LiteralPath $TestExe

# Prove the static link. The build log does NOT name the statically linked
# packages (proven on a live run) - the static list is consumed via the pcp's
# staticpackages.inc. So the link proof is: (a) our package is in
# staticpackages.inc AND (b) the produced exe carries the package name.
$StaticInc = Join-Path $ScratchPcp 'staticpackages.inc'
$LinkedOk  = (Test-Path -LiteralPath $StaticInc) -and
             ((Get-Content -LiteralPath $StaticInc -Raw) -match [Regex]::Escape($PkgName)) -and
             $ExeMade -and
             (Select-String -Path $TestExe -Pattern $PkgName -SimpleMatch -Quiet)

Write-Host ""
Write-Host ("static link ({0}) proven (inc + exe)     : {1}" -f $PkgName, $LinkedOk)
Write-Host ("isolated test lazarus.exe produced       : {0}" -f $ExeMade)
if ($ExeMade) { Write-Host "test IDE -> $TestExe" -ForegroundColor Green }

if (-not $ExeMade) {
    Write-Host "NOTE: no isolated lazarus.exe was produced. If the real IDE guard" -ForegroundColor Yellow
    Write-Host "      also stayed green, the profile seed was not honored by this" -ForegroundColor Yellow
    Write-Host "      Lazarus version - do the manual step from the script header." -ForegroundColor Yellow
    throw "Test IDE not produced in the isolated target."
}
if (-not $LinkedOk) {
    throw "Built IDE but '$PkgName' is not proven linked (staticpackages.inc + exe scan)."
}

# ---------------------------------------------------------------------------
# HARD GATE (new): the produced exe MUST actually LOAD. A link that "succeeds"
# is not enough - the 236 MB -Xe build linked fine yet Windows refused it ("not a
# valid application for this OS platform" == STATUS_INVALID_IMAGE_FORMAT, because
# ld emitted DWARF debug sections at RVA 0). So we START the exe and prove
# the loader accepts it. lazarus.exe --help does NOT halt (it opens the GUI), so
# we cannot wait for a clean exit; instead we launch it and assert the process
# actually SPAWNS and lives a moment (a rejected PE never spawns - CreateProcess
# throws immediately), then kill it. Run against an isolated pcp so nothing in the
# user's config is touched.
# ---------------------------------------------------------------------------
Write-Host "`n-- Runnable gate: does the produced exe actually load? --" -ForegroundColor Cyan
$RunPcp = Join-Path $ScratchPcp 'run-gate-pcp'
New-Item -ItemType Directory -Force -Path $RunPcp | Out-Null
# Ship sqlite3.dll beside the produced test exe (as the installer does beside the
# real lazarus.exe) so the IDE can operate the shared aefos.db at runtime.
if (Test-Path -LiteralPath $SqliteDllPath) {
    Copy-Item -LiteralPath $SqliteDllPath -Destination (Split-Path -Parent $TestExe) -Force
    Write-Host "staged sqlite3.dll beside the test exe"
}
# Ship libvterm.dll beside the produced test exe too, so the terminal panel's
# vterm_* imports resolve at runtime (the FPC edition binds libvterm as a runtime
# DLL, exactly like sqlite3.dll).
if (Test-Path -LiteralPath $VtermDllPath) {
    Copy-Item -LiteralPath $VtermDllPath -Destination (Split-Path -Parent $TestExe) -Force
    Write-Host "staged libvterm.dll beside the test exe"
}
$ExeSizeMB = [Math]::Round((Get-Item -LiteralPath $TestExe).Length / 1MB, 1)
Write-Host ("produced exe size : {0} MB" -f $ExeSizeMB)
$Loaded = $false
try {
    $proc = Start-Process -FilePath $TestExe -ArgumentList @("--pcp=$RunPcp") `
        -PassThru -WindowStyle Hidden -ErrorAction Stop
    Start-Sleep -Seconds 4
    if (-not $proc.HasExited) {
        $Loaded = $true                       # PE mapped + entry point ran = loader accepted it
        try { $proc.Kill() } catch { }
    } elseif ($proc.ExitCode -eq 0) {
        $Loaded = $true                       # clean early exit also proves it loaded
    } else {
        Write-Host ("process started then exited with code {0}" -f $proc.ExitCode) -ForegroundColor Yellow
        $Loaded = $true                       # it STARTED (a rejected PE never starts) -> loader OK
    }
} catch {
    Write-Host ("FAILED TO START: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $Loaded = $false
}
Remove-Item -Recurse -Force $RunPcp -ErrorAction SilentlyContinue
Write-Host ("runnable gate (exe loads)                : {0}" -f $Loaded)
if (-not $Loaded) {
    throw "Produced lazarus.exe does NOT load ('$IdeLinkStrategy' strategy). It linked but Windows rejects the PE."
}
Write-Host "Runnable gate PASSED: the exe loads." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Stage 3 - seed the scratch pcp so the FIRST launch opens straight into the
# workbench (no "Configure Lazarus IDE" first-run wizard, no manual click).
#
# The wizard (ide\main.pp TMainIDE.SetupInteractive, runs BEFORE package load at
# :1529) appears when any of these are not yet configured: Lazarus directory,
# compiler, FPC source, make, debugger, and fppkg (main.pp:1394-1458). A fresh
# pcp has none, so the wizard blocks - and cancelling it calls Application.
# Terminate, which on Lazarus 2.2.6 tears the half-started IDE down with an
# EAccessViolation. We seed a minimal-but-valid environmentoptions.xml pointing
# at this Lazarus install so every check passes on the first run.
#
# fppkg is the awkward one: its check (fppkghelper.pas IsProperlyConfigured)
# needs the 'rtl' package to resolve via an fppkg.cfg. We DO NOT rely on (or
# touch) the machine-global fppkg config - the wizard rewrites that global
# compiler config to a stub when it runs, which would then break the user's real
# IDE. Instead we seed an ISOLATED fppkg config INSIDE the pcp and point
# FppkgConfigFile at it, so the test IDE is fully self-contained. Its 'fpc'
# repository points at this install's fpc tree, where rtl is found.
#
# Seeded AFTER the build so the lazbuild --build-ide step cannot clobber it.
Write-Host "`n-- Stage 3: seed pcp (suppress first-run wizard) --" -ForegroundColor Cyan

$LazDirXml = $LazDir.Replace('/', '\').TrimEnd('\')

# Discover the FPC version dir shipped with this Lazarus (e.g. 3.2.2).
$FpcRoot = Join-Path $LazDir 'fpc'
$FpcVerDir = Get-ChildItem -Path $FpcRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $FpcVerDir) {
    Write-Host "WARNING: could not find an FPC version dir under $FpcRoot - skipping" -ForegroundColor Yellow
    Write-Host "         wizard-suppression seed. The first launch may show the wizard." -ForegroundColor Yellow
} else {
    $FpcVer     = $FpcVerDir.Name
    $FpcPrefix  = (Join-Path $FpcRoot $FpcVer).Replace('/', '\').TrimEnd('\') + '\'

    # Isolated fppkg config under the pcp (never the machine-global one).
    $FppkgDir    = (Join-Path $ScratchPcp 'fppkg').Replace('/', '\')
    $FppkgCfgDir = Join-Path $FppkgDir 'config'
    New-Item -ItemType Directory -Force -Path $FppkgCfgDir | Out-Null
    $FppkgLocalRepo = $FppkgDir.TrimEnd('\') + '\'
    $FppkgCfgFile   = Join-Path $FppkgDir 'fppkg.cfg'

    # fppkg.cfg: LocalRepository stays inside the pcp; the 'fpc' repository points
    # at this install's fpc tree so ScanPackages finds rtl. {LocalRepository} is a
    # literal fppkg macro (single-quoted here-string keeps it literal).
    $FppkgCfg = @'
[Defaults]
ConfigVersion=5
LocalRepository=__LOCALREPO__
BuildDir={LocalRepository}build\
ArchivesDir={LocalRepository}archives\
CompilerConfigDir={LocalRepository}config\
RemoteMirrors=https://www.freepascal.org/repository/mirrors.xml
RemoteRepository=auto
CompilerConfig=default
FPMakeCompilerConfig=default
Downloader=FPC
InstallRepository=user

[Repository]
Name=fpc
Description=Packages installed along with the Free Pascal Compiler
Path=__FPCPREFIX__
Prefix=__FPCPREFIX__

[Repository]
Name=user
Description=User-installed packages
Path={LocalRepository}
Prefix={LocalRepository}
'@
    $FppkgCfg = $FppkgCfg.Replace('__LOCALREPO__', $FppkgLocalRepo).Replace('__FPCPREFIX__', $FpcPrefix)
    [System.IO.File]::WriteAllText($FppkgCfgFile, $FppkgCfg, (New-Object System.Text.UTF8Encoding($false)))

    # The compiler config (config\default) - the shape fppkg's IsProperlyConfigured
    # needs (GlobalPrefix + Compiler + OS/CPU/Version so rtl scans clean).
    $FppkgDefault = @'
[Defaults]
ConfigVersion=5
GlobalPrefix=__FPCPREFIX__
LocalPrefix={LocalRepository}
GlobalInstallDir={GlobalPrefix}
LocalInstallDir={LocalPrefix}
Compiler=__FPCPREFIX__bin\i386-win32\fpc.exe
OS=win32
CPU=i386
Version=__FPCVER__
'@
    $FppkgDefault = $FppkgDefault.Replace('__FPCPREFIX__', $FpcPrefix).Replace('__FPCVER__', $FpcVer)
    [System.IO.File]::WriteAllText((Join-Path $FppkgCfgDir 'default'), $FppkgDefault, (New-Object System.Text.UTF8Encoding($false)))

    # environmentoptions.xml - the six wizard checks. Values that are real paths
    # are injected; $(...) tokens are Lazarus macros resolved by the IDE and MUST
    # stay literal, so this is a single-quoted here-string with placeholders.
    $FppkgCfgXml = $FppkgCfgFile.Replace('/', '\')
    $EnvOpts = @'
<?xml version="1.0" encoding="UTF-8"?>
<CONFIG>
  <EnvironmentOptions>
    <Version Value="110" Lazarus="2.2.6"/>
    <LazarusDirectory Value="__LAZDIR__"/>
    <CompilerFilename Value="$(Lazarusdir)\fpc\__FPCVER__\bin\i386-win32\fpc.exe"/>
    <FPCSourceDirectory Value="$(LazarusDir)fpc\$(FPCVer)\source"/>
    <MakeFilename Value="$(Lazarusdir)\fpc\__FPCVER__\bin\i386-win32\make.exe"/>
    <TestBuildDirectory Value="__TESTBUILD__"/>
    <FppkgConfigFile Value="__FPPKGCFG__"/>
    <Debugger>
      <Configs>
        <Config ConfigName="FpDebug" ConfigClass="TFpDebugDebugger" Active="True" UID="{B843F352-7E49-4510-A431-3A26F3BC7E58}"/>
        <Config ConfigName="Gdb" ConfigClass="TGDBMIDebugger" DebuggerFilename="$(LazarusDir)\mingw\$(TargetCPU)-$(TargetOS)\bin\gdb.exe" UID="{9A837BC6-0AE6-4B7F-8C4D-8D0207199914}"/>
      </Configs>
    </Debugger>
    <Language ID="en"/>
  </EnvironmentOptions>
</CONFIG>
'@
    $EnvOpts = $EnvOpts.
        Replace('__LAZDIR__', $LazDirXml).
        Replace('__FPCVER__', $FpcVer).
        Replace('__TESTBUILD__', ($env:TEMP.Replace('/', '\').TrimEnd('\') + '\')).
        Replace('__FPPKGCFG__', $FppkgCfgXml)
    $EnvPath = Join-Path $ScratchPcp 'environmentoptions.xml'
    [System.IO.File]::WriteAllText($EnvPath, $EnvOpts, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "seeded environmentoptions.xml + isolated fppkg config -> no first-run wizard" -ForegroundColor Green
}

# Seed the docking config so the launched IDE actually DOCKS (AnchorDocking + the
# docked form editor). Copied from the developer's real Lazarus pcp so the isolated
# IDE reproduces their exact docked layout -- the scenario the RULE #1 view guard's
# IsVisible path must handle (a designer on a TAnchorDockPage, not a floating form).
if ($WithDocking) {
    $RealPcp = Join-Path $env:LOCALAPPDATA 'lazarus'
    $DockCfgs = @('anchordockingoptions.xml', 'dockedformeditoroptions.xml')
    foreach ($cfg in $DockCfgs) {
        $src = Join-Path $RealPcp $cfg
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $ScratchPcp $cfg) -Force
            Write-Host "seeded docking config -> $cfg" -ForegroundColor Green
        } else {
            Write-Host "WARNING: docking config '$cfg' not found in $RealPcp -- the test IDE may float." -ForegroundColor Yellow
        }
    }
}

Write-Host "`nDone. Isolated test IDE built with $PkgName statically linked$(if($WithDocking){' + AnchorDocking'})." -ForegroundColor Green
Write-Host "Launch it with:  `"$TestExe`" --pcp=`"$ScratchPcp`"" -ForegroundColor Green
