<#
.SYNOPSIS
    MILESTONE 2 / SLICE F4 -- UNINSTALL the isolated Aefos Lazarus IDE.
    It removes ONE directory and OUR shortcuts (the Start-menu entry, and the
    desktop one when the user asked for it at install). That is the whole uninstall.

.DESCRIPTION
    WHY THIS FILE IS SHORT, AND WHY THAT IS THE POINT
    -------------------------------------------------
    installer\lazarus\aefos-laz-uninstall.ps1 is a thousand lines because the
    in-place install CHANGED the user's machine: it had to restore his lazarus.exe
    from a timestamped backup, take our entry out of two XML lists that Lazarus
    reads BY INDEX (renumbering Item1..ItemN and fixing Count, or the IDE silently
    loads NOTHING), put back three DLLs it had overwritten, and restore three
    preferences it had forced. Every one of those steps is a chance to give back
    something slightly different from what was taken, and two of them shipped
    broken.

    The isolated install changes nothing on his side, so there is nothing to give
    back. The proof stops being "I restored it correctly" and becomes "I never
    wrote there". This file exists to keep that true under pressure: it can ONLY
    delete a path that passes Test-AefosIsolatedRemovable, and that guard refuses a
    drive root, the profile roots, the shared brain (%APPDATA%\Aefos -- deleting it
    blinds a Delphi user, the bug PR #349 had to fix), the user's own Lazarus config,
    anything inside his Lazarus tree, and anything that is neither shaped like our
    install nor carries our stamp file.

    WHAT DELIBERATELY SURVIVES AN UNINSTALL
    ---------------------------------------
      * His Lazarus tree and his lazarus.exe        - never touched, so nothing to undo.
      * His config (%LOCALAPPDATA%\lazarus)         - only ever READ.
      * %APPDATA%\Aefos (the shared brain)          - memory.md, config.json, models.json,
        aefos.db, mcp-bridge.ps1, bin\aefos.exe. CO-OWNED with the RAD Studio
        edition: a Delphi user must not lose his memory because a Lazarus user
        uninstalled. The .iss already flags those files uninsneveruninstall; this
        engine simply never looks there.
      * ~\.aefos (addons)                            - shared the same way.
      * {app}                                        - Inno's own [Files] removal.
      * The Inno uninstall registry key              - Inno's own.

    IDEMPOTENT ON PURPOSE. Running it twice, or on a machine that never had the
    isolated IDE, exits 0 and says so. An uninstaller that fails when there is
    nothing to do turns a clean machine into a support ticket.

.PARAMETER TargetPcp
    The isolated install to remove. Default %LOCALAPPDATA%\Aefos\lazarus.

.PARAMETER LazarusDir
    The user's Lazarus tree. Optional, and used ONLY as an extra refusal: if the
    target somehow resolved inside his tree, this engine stops.

.PARAMETER ReportOnly
    Print exactly what would be removed and what would be kept, and change nothing.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\aefos-laz-uninstall-isolated.ps1
#>

[CmdletBinding()]
param(
    [string]$TargetPcp,
    [string]$LazarusDir,
    [string]$ShortcutDir,
    # Empty on purpose - resolved from the ONE declaration in
    # aefos-laz-isolated-layout.ps1 after the dot-source below, because a param()
    # default cannot read a variable that does not exist yet.
    [string]$ShortcutName,
    [string]$DesktopDir,
    [switch]$KeepShortcut,
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LayoutLib = Join-Path $ScriptDir 'aefos-laz-isolated-layout.ps1'
if (-not (Test-Path -LiteralPath $LayoutLib)) { throw "Layout library not found: '$LayoutLib'." }
# The layout library has no param() block, so dot-sourcing it cannot blank the
# parameters bound above. That is why the shared declarations live there and not in
# the seeder (whose param() block would).
. $LayoutLib

function Write-Head($m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host $m -ForegroundColor Green }
function Write-Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Write-Bad($m)  { Write-Host $m -ForegroundColor Red }

<#
.SYNOPSIS
    Is the isolated IDE running right now? Probe the FILE, not a window class.
.DESCRIPTION
    Windows locks a running image against writes, so failing to open it for write
    with a sharing violation is exact proof. A window-class probe is NOT usable
    here: 'TApplication' is the class of every LCL app -- including an Inno setup --
    which is how the old installer trapped a user in an unclosable Retry loop.
#>
function Test-AefosIsolatedIdeRunning {
    param([Parameter(Mandatory = $true)][string]$IdeExe)
    if (-not (Test-Path -LiteralPath $IdeExe)) { return $false }
    try {
        $stream = [System.IO.File]::Open($IdeExe, 'Open', 'Write', 'None')
        $stream.Dispose()
        return $false
    } catch [System.IO.IOException] {
        return $true
    } catch {
        # Any other failure (access denied, path oddity) is NOT proof it is running.
        # Fail open: a wrong "it is running" blocks the uninstall forever, while a
        # missed one only means Remove-Item reports the locked file below.
        return $false
    }
}

Write-Host '=================================================================='
Write-Host ' Aefos AI - Lazarus edition - ISOLATED uninstall'
Write-Host '=================================================================='

if ([string]::IsNullOrWhiteSpace($TargetPcp))   { $TargetPcp = Get-AefosIsolatedInstallPcp }
if ([string]::IsNullOrWhiteSpace($ShortcutDir)) { $ShortcutDir = Get-AefosIsolatedShortcutDir }
if ([string]::IsNullOrWhiteSpace($ShortcutName)) { $ShortcutName = $Script:AefosIsolatedShortcutName }
# UNCONDITIONAL, exactly like the Start-menu one: the desktop entry is optional at
# INSTALL time and never optional at removal time. Nothing records whether the box
# was ticked, and nothing needs to - Remove-Item on an absent path is a no-op, while
# an uninstall that had to remember a choice would leave an icon behind on every
# machine whose record was lost (a repair, a reinstall, an upgrade from a build that
# never wrote one).
if ([string]::IsNullOrWhiteSpace($DesktopDir)) { $DesktopDir = Get-AefosIsolatedDesktopDir }

$Pcp    = Get-AefosIsolatedFullPath $TargetPcp
$IdeExe = Join-Path (Join-Path $Pcp 'bin') 'lazarus.exe'
$Lnk    = Join-Path $ShortcutDir ($ShortcutName + '.lnk')
$DeskLnk = ''
if (-not [string]::IsNullOrWhiteSpace($DesktopDir)) { $DeskLnk = Join-Path $DesktopDir ($ShortcutName + '.lnk') }

Write-Host ("target   : {0}" -f $Pcp)
Write-Host ("shortcut : {0}" -f $Lnk)
if ($DeskLnk) { Write-Host ("desktop  : {0}" -f $DeskLnk) }
if ($ReportOnly) { Write-Warn 'REPORT ONLY - nothing will be removed.' }

# -- 1. the guard -----------------------------------------------------------
# Before asking whether the directory EXISTS, ask whether it would ever be
# allowed to go. A refusal on a path that happens to be absent today is still a
# refusal worth printing: it means the caller passed the wrong thing.
Write-Head '-- 1. Is this a path we are allowed to remove? --'
$Refusal = Test-AefosIsolatedRemovable -Path $Pcp -LazarusDir $LazarusDir
if ($Refusal) {
    Write-Bad ("REFUSING to remove: {0}" -f $Refusal)
    Write-Bad 'Nothing was changed.'
    exit 2
}
Write-Ok 'Yes: it is the isolated Aefos IDE directory, and nothing else.'

# -- 2. the directory -------------------------------------------------------
Write-Head '-- 2. Removing the isolated IDE --'
$RemovedPcp = $false
if (-not (Test-Path -LiteralPath $Pcp)) {
    Write-Ok 'Nothing to remove: the isolated Aefos IDE is not installed here.'
} elseif ($ReportOnly) {
    $files = @(Get-ChildItem -LiteralPath $Pcp -Recurse -File -Force -ErrorAction SilentlyContinue)
    $bytes = 0
    foreach ($f in $files) { $bytes += $f.Length }
    Write-Warn ("WOULD REMOVE: {0}  ({1:N0} file(s), {2:N0} MB)" -f $Pcp, $files.Count, ($bytes / 1MB))
} else {
    if (Test-AefosIsolatedIdeRunning -IdeExe $IdeExe) {
        Write-Bad 'The Aefos IDE is RUNNING. Close it and run the uninstall again.'
        Write-Bad ("  {0}" -f $IdeExe)
        exit 3
    }
    $files = @(Get-ChildItem -LiteralPath $Pcp -Recurse -File -Force -ErrorAction SilentlyContinue)
    $bytes = 0
    foreach ($f in $files) { $bytes += $f.Length }
    Remove-Item -LiteralPath $Pcp -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Pcp) {
        # Say WHICH files held on. "Uninstall failed" with no name is a support
        # ticket; a list of locked paths is an answer.
        $left = @(Get-ChildItem -LiteralPath $Pcp -Recurse -Force -ErrorAction SilentlyContinue)
        Write-Bad ("Could not remove '{0}' completely -- {1} item(s) remain:" -f $Pcp, $left.Count)
        foreach ($l in ($left | Select-Object -First 20)) { Write-Bad ("  {0}" -f $l.FullName) }
        Write-Bad 'Close anything using them (the IDE, a terminal, an editor) and run the uninstall again.'
        exit 3
    }
    $RemovedPcp = $true
    Write-Ok ("REMOVED: {0}  ({1:N0} file(s), {2:N0} MB)" -f $Pcp, $files.Count, ($bytes / 1MB))
}

# -- 3. the shortcut --------------------------------------------------------
# The CURRENT name plus every name this shortcut has carried before: a machine
# upgraded from an older build has an entry under the old name pointing at the
# very exe step 2 just deleted, and removing "the shortcut" while leaving that
# behind is the same defect as an uninstall that leaves a service running.
Write-Head '-- 3. Removing our shortcuts (Start menu, and the desktop one) --'
$LnkTargets = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $Lnk) { [void]$LnkTargets.Add($Lnk) }
foreach ($legacy in (Get-AefosIsolatedLegacyShortcutPaths -Directory $ShortcutDir)) { [void]$LnkTargets.Add($legacy) }
# The desktop, by EXACT name and never by pattern. His desktop is HIS: the
# lazarus.lnk that opens his own Lazarus lives there, and the only entries we may
# delete are the ones we wrote - the current name and the names we used before.
if ($DeskLnk) {
    if (Test-Path -LiteralPath $DeskLnk) { [void]$LnkTargets.Add($DeskLnk) }
    foreach ($legacy in (Get-AefosIsolatedLegacyShortcutPaths -Directory $DesktopDir)) { [void]$LnkTargets.Add($legacy) }
}

if ($KeepShortcut) {
    Write-Warn 'Kept on request (-KeepShortcut).'
} elseif ($LnkTargets.Count -eq 0) {
    Write-Ok 'Nothing to remove: no shortcut of ours at that path.'
} elseif ($ReportOnly) {
    foreach ($target in $LnkTargets) { Write-Warn ("WOULD REMOVE: {0}" -f $target) }
} else {
    $LnkLeft = 0
    foreach ($target in $LnkTargets) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $target) {
            Write-Warn ("Could not remove the shortcut: {0}" -f $target)
            $LnkLeft++
        } else {
            Write-Ok ("REMOVED: {0}" -f $target)
        }
    }
    # The program group goes only when WE are the last thing in it: another
    # Aefos edition may own an entry there, and taking its folder away would be
    # the same category of mistake as deleting the shared brain. NOTE that this
    # is $ShortcutDir and only $ShortcutDir: the desktop is a folder of the user's
    # own and no branch here may ever consider removing it, empty or not.
    if (($LnkLeft -eq 0) -and (Test-Path -LiteralPath $ShortcutDir)) {
        $rest = @(Get-ChildItem -LiteralPath $ShortcutDir -Force -ErrorAction SilentlyContinue)
        if ($rest.Count -eq 0) {
            Remove-Item -LiteralPath $ShortcutDir -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $ShortcutDir)) { Write-Ok ("REMOVED: {0} (empty program group)" -f $ShortcutDir) }
        } else {
            Write-Host ("  kept {0}: it still holds {1} other entry(ies)" -f $ShortcutDir, $rest.Count)
        }
    }
}

# -- 4. what stays, and why -------------------------------------------------
# Printed on EVERY run, including the "nothing to do" one. The user is entitled to
# know what an uninstall did not take, and the list is the honest answer to "did
# you clean up after yourself".
Write-Head '-- 4. What is deliberately KEPT --'
$Kept = @(
    [pscustomobject]@{ Path = $LazarusDir; What = 'your Lazarus installation'
        Why = 'it was never modified, so there is nothing to restore. Your lazarus.exe is the one you installed.' }
    [pscustomobject]@{ Path = (Join-Path $env:LOCALAPPDATA 'lazarus'); What = 'your Lazarus configuration'
        Why = 'only ever read. Your package links, your install list and your preferences are exactly as you left them.' }
    [pscustomobject]@{ Path = (Join-Path $env:APPDATA 'Aefos'); What = 'the shared Aefos data'
        Why = 'memory, settings, models, sessions and the addon manager. SHARED with the Aefos edition for RAD Studio: removing it here would break a Delphi user on the same machine.' }
    [pscustomobject]@{ Path = (Join-Path $env:USERPROFILE '.aefos'); What = 'installed Aefos addons'
        Why = 'shared with the RAD Studio edition the same way.' }
    [pscustomobject]@{ Path = $DesktopDir; What = 'your desktop, and everything on it that is not ours'
        Why = 'only the entry WE created was removed, matched by its exact name. Your own shortcuts - the lazarus.lnk that opens your Lazarus among them - are never matched by a pattern and were not touched.' }
)
foreach ($k in $Kept) {
    if ([string]::IsNullOrWhiteSpace($k.Path)) { continue }
    $mark = if (Test-Path -LiteralPath $k.Path) { 'kept' } else { 'n/a ' }
    Write-Host ("  [{0}] {1}" -f $mark, $k.Path)
    Write-Host ("         {0} -- {1}" -f $k.What, $k.Why) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '=================================================================='
if ($ReportOnly) {
    Write-Warn 'REPORT ONLY - nothing was changed.'
} elseif ($RemovedPcp) {
    Write-Ok 'AEFOS AI (LAZARUS) REMOVED. Your own Lazarus is exactly as it was.'
} else {
    Write-Ok 'Nothing of the isolated Aefos IDE was on this machine. Your Lazarus is untouched.'
}
Write-Host '=================================================================='
exit 0
