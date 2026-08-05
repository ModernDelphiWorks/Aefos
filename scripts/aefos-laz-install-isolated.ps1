<#
.SYNOPSIS
    MILESTONE 2 / SLICE F3 -- INSTALL the ISOLATED Aefos Lazarus IDE.
    Builds our own lazarus.exe into %LOCALAPPDATA%\Aefos\lazarus\bin, puts the
    three runtime DLLs beside it, stamps what it was built against, and creates one
    Start-menu shortcut. It writes NOTHING on the user's side -- not his Lazarus
    tree, not his config, not even to ADD -- and it needs NO elevation.

.DESCRIPTION
    WHAT THIS REPLACES
    ------------------
    installer\lazarus\aefos-laz-install.ps1 rebuilds the USER'S lazarus.exe in
    place: it backs his binary up, edits his XML config, drops three DLLs into his
    folder and rewrites ~200 MB of his unit output. Every field incident of the
    Lazarus edition came out of that model. This engine does the same job by
    building a SECOND IDE in a directory of ours, using his tree only through
    --lazarusdir (so it is the same LCL, the same FPC, the same sources -- no
    version conflict, no duplicated tree).

    THE FOUR THINGS THIS FILE OWNS (everything else is delegated)
    ------------------------------------------------------------
      1. THE FINAL LOCATION. Where each produced artefact ends up and why -- the
         answer lives in scripts\aefos-laz-isolated-layout.ps1 as DATA, and the
         install prints it as a layout report. An entry that is not declared there
         fails the gate, so "justify every file" is executable, not prose.
      2. THE THREE DLLs, now beside OUR exe. They are checked against the
         <pcp>\bin sort-order rule BEFORE the copy, never after (see below).
      3. THE SHORTCUTS. One .lnk in the user's own Start menu, pointing straight at
         our exe with --pcp (ours) and --scp (his, read-only seed-once), plus the
         SAME entry on his desktop when he asked for one (-DesktopShortcut). They
         are created HERE and not by the Inno [Icons] section for a reason that is
         structural: the target, <pcp>\bin\lazarus.exe, does not exist until this
         engine has finished building it.
      4. NO ELEVATION. Every write root is asserted to be inside the current user's
         profile, and the engine says so out loud.

    THE SORT-ORDER RULE, RESTATED HERE BECAUSE IT DECIDES A COPY
    ------------------------------------------------------------
    Our exe lives in <pcp>\bin, and ide\main.pp runs DeleteDirectory(PCP+'bin')
    whenever the config's version stamp disagrees with the exe. DeleteDirectory is
    a single FindFirst pass that EXITS on the first failure, and the running
    lazarus.exe is locked -- so everything that sorts AFTER the exe survives and
    everything BEFORE it is already gone when the loop stops. The three DLLs are
    safe (libvterm/sqlite3/WebView2Loader all sort after lazarus.exe; libvterm by a
    single character, 'la' < 'li'), and Test-AefosIsolatedBinNameSafe proves it for
    each one before it is written. The landmine to remember: our own brand prefix
    'aefos-*' sorts BEFORE lazarus.exe.

    WHY THE SHORTCUT POINTS AT lazarus.exe AND NOT startlazarus.exe
    ---------------------------------------------------------------
    startlazarus with our --pcp compares <pcp>\bin\lazarus.exe (ours) with
    <lazdir>\lazarus.exe (his) and starts the NEWER one, asking "Which Lazarus
    should be started?" when it cannot decide (ide\lazarusmanager.pas:328-360). The
    day he rebuilds his own IDE, his becomes newer and the shortcut would open HIS
    IDE, or throw a modal at him. A direct shortcut never enters that comparison.
    startlazarus still matters -- TMainIDE.DoRestart launches the one from HIS tree
    after a package install, and it looks for the alternative IDE at <pcp>\bin --
    which is exactly why our exe has to live there.

    WHAT IT DOES NOT DO
    -------------------
      * It does not write the Inno {app} payload (that is the .iss) and it does not
        touch %APPDATA%\Aefos -- the brain is shared with the Delphi edition.
      * It is not wired into the .iss yet. That is the last slice, on purpose:
        wiring before the round-trip is proven is how a broken uninstall ships.

.PARAMETER LazarusDir
    The USER's Lazarus tree. READ ONLY. Auto-detected when omitted.

.PARAMETER UserPcp
    The USER's own config directory. READ ONLY. Default %LOCALAPPDATA%\lazarus.

.PARAMETER TargetPcp
    Where the isolated IDE goes. Default %LOCALAPPDATA%\Aefos\lazarus.

.PARAMETER SourceRoot
    The payload root: packages\Lazarus\Aefos.Lazarus.IDE.lpk plus the three DLLs.
    Under Inno this is {app}; in a checkout it is the repo root (the default).

.PARAMETER ShortcutDir
    Where the .lnk goes. Default: the user's own Start menu, Programs\Aefos AI.

.PARAMETER DesktopShortcut
    Also put the SAME entry on the user's desktop. OFF by default here and passed
    in by the installer when he leaves the wizard's box ticked (it ships ticked -
    see the [Tasks] comment in installer\lazarus\Aefos-Lazarus.iss). It is a
    parameter and not a second engine because the target of the .lnk is
    <pcp>\bin\lazarus.exe, which does not exist until this engine has built it -
    which is also why the Inno [Icons] section cannot create it.

.PARAMETER DesktopDir
    Override the desktop folder. Only for tests; production resolves it through
    Get-AefosIsolatedDesktopDir, which is what the gate exercises.

.EXAMPLE
    pwsh -File scripts\aefos-laz-install-isolated.ps1 -LazarusDir C:\lazarus
#>

[CmdletBinding()]
param(
    [string]$LazarusDir,
    [string]$UserPcp,
    [string]$TargetPcp,
    [string]$SourceRoot,
    [string]$ShortcutDir,
    # Empty on purpose: the name lives in ONE place
    # (scripts\aefos-laz-isolated-layout.ps1 $Script:AefosIsolatedShortcutName)
    # and a param() default cannot read it, because param binding happens before
    # the dot-source. Resolved right after the libraries load, exactly like
    # $ShortcutDir already is.
    [string]$ShortcutName,
    [string]$DesktopDir,
    [string]$IdeOptions = '-g- -Xs',
    [switch]$NoImport,
    [switch]$NoShortcut,
    [switch]$DesktopShortcut,
    [switch]$NoRunnableGate,
    [switch]$NoPkgOutDirRedirect
)

$ErrorActionPreference = 'Stop'

# -- 0. arguments into locals, BEFORE any dot-source -------------------------
# scripts\aefos-laz-seed-pcp.ps1 and scripts\aefos-laz-import-components.ps1 each
# carry a param() block declaring $LazarusDir / $TargetPcp / $UserPcp / $NoImport /
# $NoPkgOutDirRedirect. Dot-sourcing runs that block IN THIS SCOPE, which would
# blank our own bound parameters. Copy first, then load. (The layout library has no
# param() block for exactly this reason and is safe to load anywhere.)
$RunLazarusDir   = $LazarusDir
$RunUserPcp      = $UserPcp
$RunTargetPcp    = $TargetPcp
$RunSourceRoot   = $SourceRoot
$RunShortcutDir  = $ShortcutDir
$RunShortcutName = $ShortcutName
$RunDesktopDir   = $DesktopDir
$RunIdeOptions   = $IdeOptions
$RunNoImport     = $NoImport.IsPresent
$RunNoShortcut   = $NoShortcut.IsPresent
$RunDesktopLnk   = $DesktopShortcut.IsPresent
$RunNoRunGate    = $NoRunnableGate.IsPresent
$RunNoPkgOutDir  = $NoPkgOutDirRedirect.IsPresent

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot  = Split-Path -Parent $ScriptDir

foreach ($lib in @('aefos-laz-isolated-layout.ps1', 'aefos-laz-seed-pcp.ps1', 'aefos-laz-import-components.ps1')) {
    $libPath = Join-Path $ScriptDir $lib
    if (-not (Test-Path -LiteralPath $libPath)) { throw "Required engine not found: '$libPath'." }
    . $libPath
}

function Write-Head($m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host $m -ForegroundColor Green }
function Write-Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Write-Bad($m)  { Write-Host $m -ForegroundColor Red }

# Every explicit write this engine makes is announced on stdout. Inno keeps the
# whole stream in aefos-laz-install.log, so support (and the gate) can answer
# "what did you put on my machine" from the log alone, without trusting a comment.
$Script:Wrote = New-Object System.Collections.Generic.List[string]
function Add-Wrote {
    param([string]$Path)
    [void]$Script:Wrote.Add($Path)
    Write-Host ("WROTE: {0}" -f $Path)
}

<#
.SYNOPSIS
    The user's Lazarus tree when the caller did not name one. Mirrors the .iss
    DetectLazarusDir plus one better source: the LazarusDirectory his own IDE
    recorded in his own config, which is the only candidate that is a FACT rather
    than a guess.
#>
function Find-AefosUserLazarusDir {
    param([string]$UserConfigDir)
    if (-not [string]::IsNullOrWhiteSpace($UserConfigDir)) {
        $envXml = Join-Path $UserConfigDir 'environmentoptions.xml'
        if (Test-Path -LiteralPath $envXml) {
            try {
                $envDoc = New-Object System.Xml.XmlDocument
                $envDoc.Load($envXml)
                $node = $envDoc.SelectSingleNode('//LazarusDirectory')
                if ($null -ne $node) {
                    $fromCfg = $node.GetAttribute('Value')
                    if ((-not [string]::IsNullOrWhiteSpace($fromCfg)) -and (Test-Path -LiteralPath (Join-Path $fromCfg 'lazbuild.exe'))) {
                        return $fromCfg
                    }
                }
            } catch { }
        }
    }
    foreach ($candidate in @('C:\lazarus',
                             (Join-Path $env:SystemDrive 'lazarus'),
                             (Join-Path ${env:ProgramFiles} 'Lazarus'),
                             (Join-Path ${env:ProgramFiles(x86)} 'Lazarus'),
                             (Join-Path $env:LOCALAPPDATA 'Programs\Lazarus'))) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate 'lazbuild.exe')) { return $candidate }
    }
    return ''
}

<#
.SYNOPSIS
    The Start-menu shortcut. One .lnk, in the user's own Start menu, created
    through WScript.Shell (present on every Windows, and the only COM this engine
    uses).
.DESCRIPTION
    Contents, and why each field is what it is:
      TargetPath : OUR exe, directly (see the header for why not startlazarus).
      Arguments  : --pcp=<ours> so it reads our config, and --scp=<his> so the IDE
                   seed-once copies HIS editor colours, key mappings, code
                   templates and codetools settings the first time it starts
                   (lazconf.pp CopySecondaryConfigFile; lazconf.pp:67 -- "the IDE
                   will never write to it"). That is how the isolated IDE opens
                   looking like his, without us ever writing in his config.
      Description: the tooltip is the honest one-liner about what this shortcut is.
      IconLocation: aefos-lazarus.ico from the payload. The exe's own icon comes
                   from the .res of HIS lazarus.lpr and we will NOT post-process
                   the produced PE to change it (a rejected PE cost a release
                   once), so the SHELL entry gets its identity from this field.
                   The RUNNING window and the taskbar button are handled by the
                   other half of the same slice: our package assigns
                   Application.Icon at IDE startup from the same .ico
                   (source\lazarus\ide\Aefos.Lazarus.AppIdentity.pas), which the
                   LCL turns into WM_SETICON on the application window and on
                   every IDE form. Both halves read one file, so the shell and
                   the running IDE can never show two different pictures.
#>
function New-AefosIsolatedShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$IdeExe,
        [Parameter(Mandatory = $true)][string]$Pcp,
        [string]$UserPcpPath,
        [string]$IconFile
    )
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Force -Path $Directory | Out-Null }
    $lnk = Join-Path $Directory ($Name + '.lnk')
    # NOT $args: that is an automatic variable in PowerShell and shadowing it inside
    # a function is a trap nobody needs to step in twice.
    $lnkArgs = ('--pcp="{0}"' -f $Pcp)
    if (-not [string]::IsNullOrWhiteSpace($UserPcpPath)) {
        $lnkArgs += (' --scp="{0}"' -f $UserPcpPath)
    }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($lnk)
        $link.TargetPath       = $IdeExe
        $link.Arguments        = $lnkArgs
        $link.WorkingDirectory = (Split-Path -Parent $IdeExe)
        # The tooltip answers the question this shortcut raises: "is this MY
        # Lazarus?". Same three facts the installer's closing screen gives.
        $link.Description      = 'A Lazarus IDE of its own, built by Aefos AI. Separate from your own Lazarus, which is not modified.'
        if ((-not [string]::IsNullOrWhiteSpace($IconFile)) -and (Test-Path -LiteralPath $IconFile)) {
            $link.IconLocation = ($IconFile + ',0')
        }
        $link.Save()
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    return $lnk
}

# ===========================================================================
# 1. PREFLIGHT
# ===========================================================================
Write-Host '=================================================================='
Write-Host ' Aefos AI - Lazarus edition - ISOLATED install'
Write-Host '=================================================================='

if ([string]::IsNullOrWhiteSpace($RunSourceRoot)) { $RunSourceRoot = $RepoRoot }
if ([string]::IsNullOrWhiteSpace($RunUserPcp))    { $RunUserPcp = Join-Path $env:LOCALAPPDATA 'lazarus' }
if ([string]::IsNullOrWhiteSpace($RunTargetPcp))  { $RunTargetPcp = Get-AefosIsolatedInstallPcp }
if ([string]::IsNullOrWhiteSpace($RunShortcutDir)) { $RunShortcutDir = Get-AefosIsolatedShortcutDir }
if ([string]::IsNullOrWhiteSpace($RunShortcutName)) { $RunShortcutName = $Script:AefosIsolatedShortcutName }
if ([string]::IsNullOrWhiteSpace($RunDesktopDir)) { $RunDesktopDir = Get-AefosIsolatedDesktopDir }
# -NoShortcut means NO shortcuts at all: it is the "install it, leave my shell
# alone" switch, and honouring it for the Start menu while still dropping one on
# the desktop would be the exact opposite of what it says.
if ($RunNoShortcut) { $RunDesktopLnk = $false }
if ([string]::IsNullOrWhiteSpace($RunLazarusDir)) { $RunLazarusDir = Find-AefosUserLazarusDir -UserConfigDir $RunUserPcp }

if ([string]::IsNullOrWhiteSpace($RunLazarusDir)) {
    Write-Bad 'No Lazarus installation was found (no lazbuild.exe on the usual paths).'
    Write-Bad 'Install Lazarus first, or pass -LazarusDir <folder that holds lazbuild.exe>.'
    exit 2
}

$Lpk = Join-Path $RunSourceRoot 'packages\Lazarus\Aefos.Lazarus.IDE.lpk'
if (-not (Test-Path -LiteralPath $Lpk)) {
    Write-Bad "Aefos package not found at '$Lpk'. Pass -SourceRoot <folder that holds packages\Lazarus\Aefos.Lazarus.IDE.lpk>."
    exit 2
}
# Same spot check the shipped engine does: a payload missing a source directory
# compiles fine on a dev machine and dies minutes into the on-machine build.
$SpotCheck = Join-Path $RunSourceRoot 'source\lazarus\ide\Aefos.Lazarus.Register.pas'
if (-not (Test-Path -LiteralPath $SpotCheck)) {
    Write-Bad "The Aefos source tree is incomplete under '$RunSourceRoot' (missing $SpotCheck)."
    exit 2
}

$TreeInfo = Get-AefosLazarusTreeInfo -LazarusDir $RunLazarusDir
$RunLazarusDir = $TreeInfo.LazarusDir
$Pcp    = Get-AefosIsolatedFullPath $RunTargetPcp
$BinDir = Join-Path $Pcp 'bin'
$IdeExe = Join-Path $BinDir 'lazarus.exe'

Write-Host ("your Lazarus  : {0}  (version {1}{2})" -f $RunLazarusDir, $TreeInfo.Version,
    $(if ($TreeInfo.Revision) { ', ' + $TreeInfo.Revision } else { '' }))
Write-Host ("your config   : {0}" -f $RunUserPcp)
Write-Host ("Aefos IDE     : {0}" -f $IdeExe)
Write-Host ("payload       : {0}" -f $RunSourceRoot)

# -- refuse anything that would make US the vandal --------------------------
if (Test-AefosIsolatedSamePath $Pcp $RunLazarusDir) {
    Write-Bad "Refusing: the install target IS your Lazarus tree."
    exit 2
}
if (Test-AefosIsolatedPathUnder -Child $Pcp -Parent $RunLazarusDir) {
    Write-Bad "Refusing: the install target is INSIDE your Lazarus tree ('$RunLazarusDir')."
    exit 2
}
if (Test-AefosIsolatedSamePath $Pcp $RunUserPcp) {
    Write-Bad "Refusing: the install target is your own Lazarus config directory."
    exit 2
}
if (Test-AefosIsolatedPathUnder -Child $Pcp -Parent (Join-Path $env:APPDATA 'Aefos')) {
    Write-Bad "Refusing: the install target is inside the shared brain (%APPDATA%\Aefos), which the Delphi edition co-owns."
    exit 2
}

# -- refuse an architecture we cannot actually deliver -----------------------
#
# BEFORE the build, not after, and that placement is the whole point. This
# installer does not ship an IDE, it BUILDS one with the user's FPC, so the
# architecture of the product is his. The three runtime DLLs, by contrast, are
# fixed binaries we ship. When those disagree, the build still succeeds -- FPC
# compiles every Aefos unit for x86_64 without a word -- and the finished,
# "installed" IDE dies at 0xc000007b on the loader, because libvterm.dll is a
# LOAD-TIME import. That is exactly what a partner testing 0.24.7-beta got: a
# green install and a dead IDE. Spending two minutes rebuilding an IDE we already
# know will not start would only move the same failure later.
#
# Unknown CPU FAILS OPEN, deliberately and for the same reason the version gate
# does: a wrong refusal leaves a user with no way to install at all, while a
# missed one costs him the build he would have run anyway.
$TargetCpu = Get-AefosLazarusTargetCpu -LazarusDir $RunLazarusDir
if ([string]::IsNullOrWhiteSpace($TargetCpu)) {
    Write-Warn 'Could not read the architecture of your lazbuild.exe; continuing without the architecture check.'
} else {
    Write-Host ("target CPU    : {0}  (read from your lazbuild.exe)" -f $TargetCpu)
    $ArchCheck = @(Test-AefosPayloadDllArchitecture -SourceRoot $RunSourceRoot -TargetCpu $TargetCpu)
    $ArchBad   = @($ArchCheck | Where-Object { -not $_.Ok })
    if ($ArchBad.Count -gt 0) {
        Write-Bad ("Refusing: this installer has no {0} build of the runtime libraries the Aefos IDE needs." -f $TargetCpu)
        Write-Bad ("Your Lazarus is {0}, so the IDE built from it would be {0} too, and these are not:" -f $TargetCpu)
        foreach ($b in $ArchBad) {
            Write-Bad ("  {0,-20} {1,-8} {2}" -f $b.Name, $(if ($b.Machine) { $b.Machine } else { 'unreadable' }), $b.Detail)
            Write-Bad ("  {0,-20} {1}" -f '', $b.Path)
        }
        Write-Bad 'NOTHING was built and NOTHING was installed; your own Lazarus was not touched.'
        Write-Bad ("To install Aefos today, point it at an i386 (32-bit) Lazarus - it can sit beside your {0} one, which this installer never modifies." -f $TargetCpu)
        exit 2
    }
    Write-Ok ("All {0} runtime libraries match your {1} Lazarus." -f $ArchCheck.Count, $TargetCpu)
}

# -- elevation: prove we do not need it -------------------------------------
Write-Head '-- 1. Privileges: this install writes only inside your own profile --'
$WriteRoots = Get-AefosIsolatedWriteRoots -Pcp $Pcp `
    -ShortcutDir $(if ($RunNoShortcut) { '' } else { $RunShortcutDir }) `
    -DesktopDir  $(if ($RunDesktopLnk) { $RunDesktopDir } else { '' })
$OutsideProfile = @($WriteRoots | Where-Object { -not $_.PerUser })
foreach ($r in $WriteRoots) {
    Write-Host ("  {0,-5} {1}" -f $(if ($r.PerUser) { 'user' } else { 'OTHER' }), $r.Path)
    Write-Host ("        {0}" -f $r.What)
}
if ($OutsideProfile.Count -gt 0) {
    # Not a warning. The whole point of the model is that nothing lands outside the
    # profile; a target that does would silently re-introduce the elevation
    # requirement -- and with it the "elevated as another account, so %LOCALAPPDATA%
    # was the admin's" class of failure.
    Write-Bad 'Refusing: an install target is outside your user profile, which would require elevation:'
    foreach ($r in $OutsideProfile) { Write-Bad ("  {0}" -f $r.Path) }
    exit 2
}
Write-Ok ("No elevation required (running elevated right now: {0})." -f (Test-AefosIsolatedElevated))

# ===========================================================================
# 2. BUILD (the F1 seeder + the F2 import engine do the work)
# ===========================================================================
Write-Head '-- 2. Building the isolated IDE (this takes a couple of minutes) --'
$DockPkgs = @()
foreach ($rel in @('components\anchordocking\design\anchordockingdsgn.lpk',
                   'components\dockedformeditor\dockedformeditor.lpk')) {
    $dockLpk = Join-Path $RunLazarusDir $rel
    if (Test-Path -LiteralPath $dockLpk) { $DockPkgs += $dockLpk }
    else { Write-Warn "  docking package not found in your Lazarus tree: $dockLpk" }
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Build = Invoke-AefosIsolatedIdeBuild -LazarusDir $RunLazarusDir -TargetPcp $Pcp -UserPcp $RunUserPcp `
    -AefosLpk $Lpk -ExtraPackageLpk $DockPkgs -IdeOpts $RunIdeOptions `
    -NoImport:$RunNoImport -NoPkgOutDirRedirect:$RunNoPkgOutDir
$sw.Stop()

Write-Host ("  outcome  : {0}" -f $Build.Outcome)
Write-Host ("  imported : {0} of your component package(s)" -f @($Build.Plan.Imported).Count)
Write-Host ("  left out : {0}" -f @($Build.Plan.Skipped).Count)
Write-Host ("  report   : {0}" -f $Build.ReportPath)
foreach ($a in $Build.Attempts) { Write-Host ("  attempt  : {0}" -f $a) }
# A package link that did not land means a component of his that CANNOT be imported,
# whatever the build then does. Never silent: the fallback would otherwise look like
# success while he quietly lost every component he has.
foreach ($f in @($Build.LinkFailures)) { Write-Warn ("  link FAIL: {0}" -f $f) }
Write-Host ("  elapsed  : {0:N0}s" -f $sw.Elapsed.TotalSeconds)
if ($Build.ReportPath) { Add-Wrote $Build.ReportPath }

if (($Build.Outcome -eq 'Failed') -or (-not $Build.IdeProduced)) {
    Write-Bad 'The isolated IDE could not be built. Your own Lazarus was NOT modified by this attempt.'
    Write-Bad ("Build logs: {0}" -f $Build.LogDir)
    if ($Build.Culprit) { Write-Bad ("The build stopped on: {0}" -f $Build.Culprit) }
    exit 1
}
Write-Ok ("Built {0} ({1:N1} MB)." -f $IdeExe, ((Get-Item -LiteralPath $IdeExe).Length / 1MB))

# ===========================================================================
# 3. THE THREE RUNTIME DLLs -- beside OUR exe, never beside his
# ===========================================================================
Write-Head '-- 3. Runtime DLLs beside the Aefos IDE --'
foreach ($dll in (Get-AefosIsolatedPayloadDlls -SourceRoot $RunSourceRoot -TargetCpu $TargetCpu)) {
    $src = ''
    foreach ($candidate in $dll.Candidates) {
        if (Test-Path -LiteralPath $candidate) { $src = $candidate; break }
    }
    if ([string]::IsNullOrWhiteSpace($src)) {
        Write-Bad ("{0} is missing from the payload -- {1}." -f $dll.Name, $dll.Why)
        Write-Bad ("Looked in: {0}" -f ($dll.Candidates -join '; '))
        exit 1
    }
    # The sort-order verdict is printed per DLL, not assumed: this is the check that
    # keeps the IDE from deleting its own dependencies on a version mismatch.
    $safe = Test-AefosIsolatedBinNameSafe -Name $dll.Name
    Write-Host ("  {0,-20} sorts after lazarus.exe: {1}" -f $dll.Name, $safe)
    $dest = Join-Path $BinDir $dll.Name
    Copy-AefosIsolatedPayload -Root $Pcp -Source $src -Destination $dest
    Add-Wrote $dest
}

# Hygiene + the invariant, AFTER the DLLs are in place: lazbuild rolls the previous
# exe aside on every --build-ide, and a 20.9 MB lazarus.old.exe per rebuild is pure
# waste (it sorts after lazarus.exe, so it is waste and not danger).
$Cleared = Clear-AefosIsolatedBin -BinDir $BinDir
if (@($Cleared).Count -gt 0) { Write-Host ("  swept from <pcp>\bin: {0}" -f (@($Cleared) -join ', ')) }

$BinRisk = Get-AefosIsolatedBinRisk -BinDir $BinDir
if ($BinRisk.Count -gt 0) {
    Write-Bad ("{0} entry(ies) in <pcp>\bin sort BEFORE lazarus.exe. The IDE would destroy them on the first version mismatch:" -f $BinRisk.Count)
    foreach ($r in $BinRisk) { Write-Bad ("  {0} ({1}) -- {2}" -f $r.Name, $r.Kind, $r.Reason) }
    exit 3
}
Write-Ok 'All three DLLs are beside our exe and every entry in <pcp>\bin sorts after it.'

# ===========================================================================
# 4. RUNNABLE CHECK -- a link that succeeds is not proof the exe starts
# ===========================================================================
if (-not $RunNoRunGate) {
    Write-Head '-- 4. Does the IDE we just built actually start? --'
    # The throwaway pcp lives INSIDE our own directory, so even this check writes
    # nothing outside the install, and it is removed when it passes.
    $RunCheckPcp = Join-Path $Pcp 'runcheck'
    if (Test-Path -LiteralPath $RunCheckPcp) { Remove-Item -LiteralPath $RunCheckPcp -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $RunCheckPcp | Out-Null
    $Alive = $false
    try {
        $proc = Start-Process -FilePath $IdeExe -ArgumentList @("--pcp=$RunCheckPcp", '--no-splash-screen') `
            -PassThru -WindowStyle Hidden -ErrorAction Stop
        Start-Sleep -Seconds 5
        $Alive = -not $proc.HasExited
        if ($Alive) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    } catch {
        $Alive = $false
    }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $RunCheckPcp -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $Alive) {
        Write-Bad 'The IDE was produced but does not start. Refusing to call this installed.'
        Write-Bad ("Build logs: {0}" -f $Build.LogDir)
        exit 4
    }
    Write-Ok 'The isolated IDE starts.'
}

# ===========================================================================
# 5. THE STAMP -- what this binary was built against
# ===========================================================================
Write-Head '-- 5. Stamping what this IDE was built against --'
# Read later (slice F6, scripts\aefos-laz-ide-drift.ps1) to notice that he upgraded
# his Lazarus while our binary stayed linked against the old .ppu set: same tree,
# different sources, and the honest answer is a non-modal offer to rebuild -- never a
# modal, which would freeze the IDE main thread and with it the MCP pipe.
#
# SCHEMA 2 adds lazarusExeSize / lazarusExeMtimeUtc: the cheap way to notice that HE
# rebuilt his own IDE. Size + mtime and never a hash -- the detector runs at every
# start of the Aefos IDE, and hashing a 21 MB binary there is how a startup check
# earns itself a deletion. The detector tolerates a schema-1 stamp and says that
# particular question is unanswerable rather than reporting a clean bill of health.
$HisExeInfo = Get-Item -LiteralPath $TreeInfo.LazarusExe -ErrorAction SilentlyContinue
$Stamp = [pscustomobject]@{
    schema        = 2
    builtUtc      = ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
    lazarusDir    = $RunLazarusDir
    lazarusVersion= $TreeInfo.Version
    lazarusRevision = $TreeInfo.Revision
    fpcVersion    = $TreeInfo.FpcVersion
    lazarusExeSize = $(if ($null -ne $HisExeInfo) { $HisExeInfo.Length } else { 0 })
    lazarusExeMtimeUtc = $(if ($null -ne $HisExeInfo) { $HisExeInfo.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' })
    builtAgainst  = ("{0}/{1}" -f $TreeInfo.Version, $TreeInfo.Revision)
    userPcp       = $RunUserPcp
    sourceRoot    = $RunSourceRoot
    ideExe        = $IdeExe
    importOutcome = $Build.Outcome
    imported      = @($Build.Plan.Imported | ForEach-Object { $_.Name })
    leftOut       = @($Build.Plan.Skipped | ForEach-Object { $_.Name })
}
$StampPath = Join-Path $Pcp 'aefos-ide.json'
$StampWritten = New-Object System.Collections.Generic.List[string]
Write-AefosSeedFile -Root $Pcp -Path $StampPath -Content (($Stamp | ConvertTo-Json -Depth 4) + "`r`n") -Written $StampWritten
Add-Wrote $StampPath

# ===========================================================================
# 6. THE SHORTCUT
# ===========================================================================
$LnkPath = ''
$DesktopLnkPath = ''
if (-not $RunNoShortcut) {
    Write-Head '-- 6. Shortcuts --'
    # Under Inno the payload root IS {app}, where the .iss drops the .ico; the
    # second candidate is the repo layout, so a run straight from a checkout gets
    # the same shortcut a real install does.
    $IconFile = ''
    foreach ($candidate in @((Join-Path $RunSourceRoot $Script:AefosIsolatedIconFileName),
                             (Join-Path $RunSourceRoot ('installer\lazarus\' + $Script:AefosIsolatedIconFileName)))) {
        if (Test-Path -LiteralPath $candidate) { $IconFile = $candidate; break }
    }
    $LnkPath = New-AefosIsolatedShortcut -Directory $RunShortcutDir -Name $RunShortcutName `
        -IdeExe $IdeExe -Pcp $Pcp -UserPcpPath $RunUserPcp -IconFile $IconFile
    Add-Wrote $LnkPath
    Write-Ok ("Start menu > {0} > {1}" -f $Script:AefosIsolatedGroupName, $RunShortcutName)
    if ([string]::IsNullOrWhiteSpace($IconFile)) {
        # Said out loud rather than left for the user to discover: without the .ico
        # the entry falls back to the Lazarus exe icon, and the two IDEs are then
        # told apart by NAME alone.
        Write-Warn ("No {0} in the payload: the entry uses the Lazarus exe icon, so the two IDEs are told apart by NAME." -f $Script:AefosIsolatedIconFileName)
    }
    # A shortcut we used to write under a DIFFERENT name is still on this machine
    # and still points at our exe. Leaving it would show the user two entries for
    # one IDE, and the uninstall - which deletes the CURRENT name - would leave the
    # old one dangling.
    foreach ($stale in (Get-AefosIsolatedLegacyShortcutPaths -Directory $RunShortcutDir)) {
        Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $stale)) {
            Write-Ok ("REMOVED: {0} (shortcut under our previous name)" -f $stale)
        }
    }

    # -- the DESKTOP entry, only when he asked for it -----------------------
    # Same name, same icon, same tooltip, same arguments: the entry on the desktop
    # and the entry in the Start menu are ONE thing shown in two places, produced by
    # one function. Two spellings of the same shortcut is how a user ends up with a
    # desktop icon that opens the IDE with a different config than the menu one.
    if ($RunDesktopLnk) {
        if ([string]::IsNullOrWhiteSpace($RunDesktopDir)) {
            Write-Warn 'No desktop folder could be resolved for this profile: the desktop shortcut was skipped (the Start-menu entry is there).'
        } else {
            $DesktopLnkPath = New-AefosIsolatedShortcut -Directory $RunDesktopDir -Name $RunShortcutName `
                -IdeExe $IdeExe -Pcp $Pcp -UserPcpPath $RunUserPcp -IconFile $IconFile
            Add-Wrote $DesktopLnkPath
            Write-Ok ("Desktop > {0}" -f $RunShortcutName)
            # Our OWN previous names, on the desktop too. Without this a machine
            # upgraded from a build that used the old name would show two icons for
            # one IDE. Exact names only - a desktop is full of shortcuts the user
            # owns, his lazarus.lnk among them, and none of them is ours to touch.
            foreach ($stale in (Get-AefosIsolatedLegacyShortcutPaths -Directory $RunDesktopDir)) {
                Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $stale)) {
                    Write-Ok ("REMOVED: {0} (desktop shortcut under our previous name)" -f $stale)
                }
            }
        }
    }
}

# ===========================================================================
# 7. LAYOUT REPORT + the verdict
# ===========================================================================
Write-Head '-- 7. What is installed, and why each part is there --'
$Manifest = Get-AefosIsolatedLayoutManifest
foreach ($scope in @('Pcp', 'Bin')) {
    $dir = if ($scope -eq 'Bin') { $BinDir } else { $Pcp }
    Write-Host ''
    Write-Host ("  {0}" -f $dir) -ForegroundColor DarkCyan
    foreach ($m in ($Manifest | Where-Object { $_.Scope -eq $scope })) {
        $path = Join-Path $dir $m.Name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        Write-Host ("    {0,-24} [{1}]" -f $m.Name, $m.Kind)
        Write-Host ("        {0}" -f $m.Why) -ForegroundColor DarkGray
    }
}

$Undeclared = Get-AefosIsolatedUndeclared -Pcp $Pcp
if ($Undeclared.Count -gt 0) {
    # An entry nobody declared is an entry nobody can justify to the user, and the
    # uninstaller has no idea it exists. Fail rather than ship an unexplained file.
    Write-Bad ''
    Write-Bad ("{0} entry(ies) in the install are NOT declared in the layout manifest:" -f $Undeclared.Count)
    foreach ($u in $Undeclared) { Write-Bad ("  {0}:{1}   {2}" -f $u.Scope, $u.Name, $u.Path) }
    Write-Bad 'Declare them in scripts\aefos-laz-isolated-layout.ps1 (with the reason) or stop producing them.'
    exit 3
}
$MissingReq = Get-AefosIsolatedMissingRequired -Pcp $Pcp
if ($MissingReq.Count -gt 0) {
    Write-Bad ("The install is missing required part(s): {0}" -f ($MissingReq -join ', '))
    exit 3
}

$PcpFiles = @(Get-ChildItem -LiteralPath $Pcp -Recurse -File -Force -ErrorAction SilentlyContinue)
$PcpBytes = 0
foreach ($f in $PcpFiles) { $PcpBytes += $f.Length }

Write-Host ''
Write-Host '=================================================================='
Write-Ok 'AEFOS AI (LAZARUS) INSTALLED - and your own Lazarus was not modified.'
Write-Host ("  IDE          : {0}" -f $IdeExe)
Write-Host ("  size on disk : {0:N0} file(s), {1:N0} MB" -f $PcpFiles.Count, ($PcpBytes / 1MB))
Write-Host ("  built against: Lazarus {0} at {1}" -f $TreeInfo.Version, $RunLazarusDir)
if ($LnkPath) { Write-Host ("  shortcut     : {0}" -f $LnkPath) }
if ($DesktopLnkPath) { Write-Host ("  desktop      : {0}" -f $DesktopLnkPath) }
Write-Host ("  components   : {0} imported, {1} left out (see {2})" -f `
    @($Build.Plan.Imported).Count, @($Build.Plan.Skipped).Count, $Build.ReportPath)
Write-Host ''
Write-Host '  To remove it later, everything above is inside ONE directory:'
Write-Host ("    {0}" -f $Pcp)
Write-Host '=================================================================='
exit 0
