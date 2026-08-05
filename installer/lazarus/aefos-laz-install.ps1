<#
.SYNOPSIS
    On-machine INSTALL engine for the Aefos AI Lazarus edition.

.DESCRIPTION
    Lazarus does NOT load design packages the way Delphi loads design-time BPLs.
    A Delphi design package is a .bpl dropped into a folder and registered in the
    registry; the IDE maps it at runtime. A Lazarus design package is instead
    STATICALLY LINKED into lazarus.exe: "installing" it means recompiling the
    user's IDE binary with the package in its static package list. There is no
    drop-and-register; there is a rebuild.

    So this engine, run ON THE USER'S MACHINE, does exactly that:

      1. DETECT the user's Lazarus install directory (hence its bundled FPC) and
         its primary config path (pcp, e.g. %LOCALAPPDATA%\lazarus).
      2. BACK UP the current lazarus.exe (timestamped) so the install is fully
         reversible (Lazarus keeps its own lazarus.old.exe too; we keep ours).
      3. REGISTER the shipped Aefos .lpk as a package link, ADD it to the IDE's
         static package list, and REBUILD lazarus.exe with it linked
         (lazbuild --add-package ... --build-ide=).
      4. COPY WebView2Loader.dll beside lazarus.exe (the chat renders through it).
      5. VERIFY the static link: the package name appears in staticpackages.inc
         AND the rebuilt lazarus.exe carries the "Aefos AI Chat" menu string.

    Everything it changes that is NOT ours -- a same-named DLL already beside
    lazarus.exe, the three IDE preferences it seeds -- is recorded, with what was
    there BEFORE, in aefos-laz-install-state.json in the Lazarus directory. That
    file is the uninstaller's only way to tell "we created this" (delete it) from
    "we overwrote theirs" (give it back). A displaced DLL is additionally kept as
    <name>.aefos-preexisting-<stamp>.bak beside it.

    On a writable Lazarus directory (the normal case) lazbuild's CalcTargets
    writes the rebuilt lazarus.exe straight into that directory
    (buildlazdialog.pas Case 4) -- which is EXACTLY what a real install wants,
    the opposite of scripts\build-lazarus.ps1, whose job was to AVOID touching
    the real IDE by redirecting into a scratch target. Here we DO target the real
    IDE, on purpose.

    Because the user's pcp is already configured (it has environmentoptions.xml,
    a compiler, FPC source, etc.), the first-run "Configure Lazarus IDE" wizard
    does NOT fire -- that whole seeding dance in build-lazarus.ps1 was only needed
    for a FRESH scratch pcp. A real install reuses the user's real, working pcp.

    The engine is IDEMPOTENT: re-running re-registers the link (harmless) and
    rebuilds; the stock backup is captured only once (the first run), so a second
    run never overwrites the precious stock backup with an Aefos-linked binary.

.PARAMETER SourceRoot
    Root that contains packages\Lazarus\Aefos.Lazarus.IDE.lpk and the source\
    tree it references (..\..\source\...). Defaults to the repo root two levels
    above this script; the installer passes the stable shipped location.

.PARAMETER LazarusDir
    Override the detected Lazarus directory (the folder holding lazbuild.exe and
    lazarus.exe). If omitted, the engine detects it (PATH, common paths, registry).

.PARAMETER Pcp
    Override the detected primary config path. If omitted, %LOCALAPPDATA%\lazarus
    is used when present (lazbuild's own default), else lazbuild's built-in default.

.PARAMETER WebView2Loader
    Path to the x86 WebView2Loader.dll to drop beside lazarus.exe. Defaults to the
    copy shipped beside this script.

.PARAMETER BackupStamp
    Timestamp used in the backup file name. Defaults to a Get-Date value; if
    Get-Date is unavailable the engine falls back to an incrementing suffix.

.EXAMPLE
    pwsh -File aefos-laz-install.ps1
    Detect everything and install into the user's real Lazarus.

.EXAMPLE
    pwsh -File aefos-laz-install.ps1 -LazarusDir "C:\lazarus" -Pcp "$env:LOCALAPPDATA\lazarus"
#>

[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$LazarusDir,
    [string]$Pcp,
    [string]$WebView2Loader,
    [string]$BackupStamp
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PkgName    = 'Aefos.Lazarus.IDE'
$LpkRelPath = 'packages\Lazarus\Aefos.Lazarus.IDE.lpk'
$MenuString = 'Aefos AI Chat'   # cChatCaption in Aefos.Lazarus.Register.pas

function Write-Step($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host $msg -ForegroundColor Green }
function Write-WarnMsg($m) { Write-Host $m  -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Drop nodes from a Lazarus <ItemN> list, then leave the list CONSISTENT:
# renumbered Item1..ItemN with no holes, and a Count attribute equal to the real
# number of items. Returns that number. (Twin of the helper in
# aefos-laz-uninstall.ps1 - the two engines ship standalone, so it lives in both.)
#
# WHY the renumbering is not cosmetic: Lazarus does not walk this XML, it reads it
# BY INDEX. ide\packages\idepackager\packagelinks.pas:614-619 does
#     LinkCount := XMLConfig.GetValue(Path+'Count', 0);
#     for i := 1 to LinkCount do ... ItemPath := Path+'Item'+IntToStr(i)+'/';
# so a plain RemoveChild leaves Item1, Item3 and the read of "Item2" comes back
# empty -- one of the USER'S package links vanishes even though its XML is still on
# disk, and every third-party component package it resolved goes with it.
#
# WHY $_.LocalName and never $_.Name when testing a TAG name: PowerShell's XML
# adapter SHADOWS the .NET XmlNode.Name property with the child element named
# <Name>, so for <Item1><Name Value="rxtools"/></Item1> the expression $_.Name is an
# XmlElement, never the string 'Item1'. ($_.Name.Value elsewhere in this file IS
# correct - there the <Name> child is exactly what we want.)
function Set-AefosIndexedList {
    param(
        [System.Xml.XmlElement]$ListNode,
        [object[]]$Remove
    )
    foreach ($node in @($Remove)) { [void]$ListNode.RemoveChild($node) }

    $items = @($ListNode.ChildNodes |
        Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
    $index = 0
    foreach ($item in $items) {
        $index++
        $wanted = 'Item' + $index
        if ($item.LocalName -ne $wanted) {
            # XmlElement cannot be renamed in place, so rebuild it under the right
            # tag (attributes + subtree preserved verbatim) and swap it in.
            $renamed = $ListNode.OwnerDocument.CreateElement($wanted)
            foreach ($attr in @($item.Attributes)) {
                $renamed.SetAttribute($attr.LocalName, $attr.Value)
            }
            foreach ($sub in @($item.ChildNodes)) {
                [void]$renamed.AppendChild($sub.CloneNode($true))
            }
            [void]$ListNode.ReplaceChild($renamed, $item)
        }
    }
    # Always write Count: a missing one reads back as 0, which is the same wipe.
    $ListNode.SetAttribute('Count', [string]$index)
    return $index
}

# ---------------------------------------------------------------------------
# Resolve the shipped sources.
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    # installer\lazarus\ -> repo root is two levels up.
    $SourceRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
}
$Lpk = Join-Path $SourceRoot $LpkRelPath
if (-not (Test-Path -LiteralPath $Lpk)) {
    throw "Aefos package not found at '$Lpk'. Pass -SourceRoot <folder that holds $LpkRelPath>."
}
# Spot-check the source tree the .lpk references really shipped.
$SpotCheck = Join-Path $SourceRoot 'source\lazarus\ide\Aefos.Lazarus.Register.pas'
if (-not (Test-Path -LiteralPath $SpotCheck)) {
    throw "The Aefos source tree is incomplete under '$SourceRoot' (missing $SpotCheck). Re-run the installer."
}

Write-Step "== Aefos AI - Lazarus edition install =="
Write-Host "source root : $SourceRoot"
Write-Host "package     : $Lpk"

# ---------------------------------------------------------------------------
# Detect lazbuild / Lazarus directory.
# ---------------------------------------------------------------------------
function Find-LazBuild {
    param([string]$Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $c = Join-Path $Override 'lazbuild.exe'
        if (Test-Path -LiteralPath $c) { return $c }
        throw "No lazbuild.exe under the specified Lazarus directory '$Override'."
    }

    # 1) lazbuild on PATH.
    $cmd = Get-Command 'lazbuild.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 2) Common install locations.
    $candidates = @(
        'C:\lazarus',
        'C:\Lazarus',
        (Join-Path $env:SystemDrive 'lazarus'),
        (Join-Path ${env:ProgramFiles} 'Lazarus'),
        (Join-Path ${env:ProgramFiles(x86)} 'Lazarus')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($d in $candidates) {
        $c = Join-Path $d 'lazbuild.exe'
        if (Test-Path -LiteralPath $c) { return $c }
    }

    # 3) Registry (Lazarus' own uninstall key stores InstallLocation).
    $regKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\lazarus',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\lazarus',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\lazarus'
    )
    foreach ($k in $regKeys) {
        try {
            $loc = (Get-ItemProperty -Path $k -Name 'InstallLocation' -ErrorAction Stop).InstallLocation
            if ($loc) {
                $c = Join-Path $loc 'lazbuild.exe'
                if (Test-Path -LiteralPath $c) { return $c }
            }
        } catch { }
    }

    throw @"
Could not find a Lazarus installation (lazbuild.exe).
Looked on PATH, in common install folders (C:\lazarus, Program Files\Lazarus, ...)
and in the registry. Pass -LazarusDir "<path to your Lazarus folder>" to point at it.
"@
}

$LazBuild = Find-LazBuild -Override $LazarusDir
$LazDir   = Split-Path -Parent $LazBuild
$LazExe   = Join-Path $LazDir 'lazarus.exe'
Write-Host "lazbuild    : $LazBuild"
Write-Host "lazarus dir : $LazDir"

if (-not (Test-Path -LiteralPath $LazExe)) {
    throw "lazarus.exe not found in '$LazDir'. The Lazarus install looks incomplete."
}

# ---------------------------------------------------------------------------
# Resolve the primary config path (pcp).
#   Running elevated, the process' %LOCALAPPDATA% may be the ADMIN's profile,
#   not the logged-in user's. The installer passes -Pcp with the real user path;
#   detection here is the interactive/dev fallback.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Pcp)) {
    $defaultPcp = Join-Path $env:LOCALAPPDATA 'lazarus'
    if (Test-Path -LiteralPath $defaultPcp) {
        $Pcp = $defaultPcp
    }
}

# Does this folder look like a configuration Lazarus has actually written? Both
# markers are created on the IDE's first run; a pcp that has neither has never
# been used.
function Test-AefosPcpPlausible {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    foreach ($marker in @('environmentoptions.xml', 'packagefiles.xml')) {
        if (Test-Path -LiteralPath (Join-Path $Path $marker)) { return $true }
    }
    return $false
}

# GATE: the pcp we are about to operate MUST plausibly be the user's.
#
# Setup runs elevated (PrivilegesRequired=admin) and hands us
# "{localappdata}\lazarus". If that elevation prompt was answered with a DIFFERENT
# admin account, {localappdata} resolves inside THAT account's profile and we end
# up reading a config the user has never touched. Nothing errors along the way:
# the IDE install list read further down comes back EMPTY, and
# `lazbuild --build-ide` then cheerfully links an IDE with NONE of the user's
# packages in it. That is a second, independent road to the stripped IDE the P0
# Count=0 bug produced - and it had no guard at all. An empty install list is
# never evidence that the user has no packages; it is evidence that we are looking
# at the wrong folder. So refuse to guess: stop before touching anything.
$PcpProbe = $Pcp
if ([string]::IsNullOrWhiteSpace($PcpProbe)) { $PcpProbe = Join-Path $env:LOCALAPPDATA 'lazarus' }
if (-not (Test-AefosPcpPlausible -Path $PcpProbe)) {
    throw @"
The Lazarus configuration folder does not look like yours:

    $PcpProbe

It holds neither environmentoptions.xml nor packagefiles.xml, so Lazarus has never
written a configuration there. Installing against it would be WORSE than failing:
rebuilding lazarus.exe uses YOUR list of installed packages from that folder, an
empty list reads as "no packages at all", and your IDE would come back linked
without a single one of them.

Two causes, both easy to fix:
  * Lazarus has never been started on this account. Open Lazarus once so it
    creates its configuration, close it, and run this setup again.
  * Setup was elevated with a DIFFERENT Windows account, so the path above points
    into that account's profile. Run the setup from your own account, or pass
    -Pcp "<your local AppData>\lazarus" to this engine.

Nothing has been changed.
"@
}
$Pcp = $PcpProbe
Write-Host "pcp         : $Pcp"

# ---------------------------------------------------------------------------
# Resolve the WebView2 loader.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($WebView2Loader)) {
    $WebView2Loader = Join-Path $ScriptDir 'WebView2Loader.dll'
}

# ---------------------------------------------------------------------------
# INSTALL STATE - the record the uninstaller needs to put things BACK.
#
# Everything this engine changes outside its own files (the DLLs it drops beside
# lazarus.exe, the three IDE preferences it seeds) belongs to the USER. Without a
# written record the uninstaller cannot tell "we created this" from "we overwrote
# theirs", and its only option is the destructive one: delete. So we write down,
# per artifact, what was there BEFORE us.
#
# WHY it lives in the Lazarus directory and not under %APPDATA%\Aefos: it
# describes THIS Lazarus directory, both engines already resolve that directory
# the same way, and it is immune to the elevated-profile mismatch that the pcp
# gate above exists for (%APPDATA% would resolve to the elevating account).
#
# It is a plain-JSON, additive record. Absent = an install made by an older build:
# the uninstaller falls back to its legacy behaviour instead of guessing.
$StatePath = Join-Path $LazDir 'aefos-laz-install-state.json'

function Read-AefosInstallState {
    param([string]$Path)
    $state = @{ schema = 1; dlls = @(); idePrefs = @() }
    if (-not (Test-Path -LiteralPath $Path)) { return $state }
    try { $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $state }
    foreach ($listName in @('dlls', 'idePrefs')) {
        $items = @()
        if (@($raw.PSObject.Properties.Name) -contains $listName) {
            foreach ($entry in @($raw.$listName)) {
                $record = @{}
                foreach ($prop in $entry.PSObject.Properties) { $record[$prop.Name] = $prop.Value }
                $items += $record
            }
        }
        $state[$listName] = $items
    }
    return $state
}

# Written after EVERY capture, not once at the end: a rebuild that fails midway
# must still leave the uninstaller able to give back what we already displaced.
function Write-AefosInstallState {
    param([string]$Path, [hashtable]$State)
    try {
        ($State | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        Write-WarnMsg "Could not write the install state to '$Path': $($_.Exception.Message)"
    }
}

# Re-running the installer must NEVER re-capture: the file on disk is our own copy
# from the previous run, so a second capture would record US as the user's
# original. Same rule as the stock lazarus.exe backup above.
function Get-AefosStateRecord {
    param([object[]]$Records, [string]$Name)
    foreach ($record in @($Records)) {
        if ($record -and $record['name'] -eq $Name) { return $record }
    }
    return $null
}

# NOT named $State: PowerShell variables are case-insensitive and the package-link
# dedup below already uses a local $state ('live'/'dead'), which would silently
# overwrite this hashtable with a string.
$InstallState = Read-AefosInstallState -Path $StatePath
$InstallState['schema']     = 1
$InstallState['lazarusDir'] = $LazDir
$InstallState['pcp']        = $Pcp
try { $InstallState['installedUtc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { }

# SHA-256 of a file, through .NET rather than Get-FileHash.
#
# This engine runs under whatever process the installer starts, and a
# PSModulePath inherited from a PowerShell 7 parent makes Windows PowerShell load
# PS7's Microsoft.PowerShell.Utility - where Get-FileHash does not exist ("The
# term 'Get-FileHash' is not recognized"). Reproduced on the dev machine while
# proving this very change. Comparing two files is not worth that failure mode.
# Format matches Get-FileHash: uppercase hex, no separators.
function Get-AefosFileHash {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

# ---------------------------------------------------------------------------
# Drop ONE of our runtime DLLs beside lazarus.exe WITHOUT eating whatever was
# already there, and return the record that lets the uninstaller undo it.
#
# sqlite3.dll next to lazarus.exe is not exotic - anyone using SQLdb keeps one
# there, quite possibly a different build than ours. The old code did a bare
# Copy-Item -Force over it and the uninstaller then DELETED it: the user handed us
# a working DLL and got back an empty folder. Whatever we displace is preserved
# under a traceable name in the same directory and named in the state file.
#
# Three outcomes, and the uninstaller treats each differently:
#   preexisting=$false            -> the file is ours; uninstall deletes it.
#   preexisting=$true, backup=$null -> theirs, byte-identical to ours; uninstall
#                                    LEAVES it (that already IS the original).
#   preexisting=$true, backup=<f> -> theirs and different; uninstall copies <f>
#                                    back over ours.
# ourSha256 is the "is it still ours?" proof: if the user swaps the DLL after the
# install, the uninstaller must not touch their newer file.
function Copy-AefosRuntimeDll {
    param(
        [string]$Source,
        [string]$LazDir,
        [string]$Name,
        [string]$Stamp,
        [hashtable]$Existing
    )
    $dest = Join-Path $LazDir $Name
    if ($Existing) {
        # Re-run: the ORIGINAL was captured by the first install; only refresh the
        # hash of the copy we are laying down now.
        Copy-Item -LiteralPath $Source -Destination $dest -Force
        $Existing['ourSha256'] = Get-AefosFileHash -Path $dest
        return $Existing
    }
    $record = @{ name = $Name; preexisting = $false; backup = $null; ourSha256 = $null }
    if (Test-Path -LiteralPath $dest) {
        $record['preexisting'] = $true
        $sameBytes = (Get-AefosFileHash -Path $dest) -eq (Get-AefosFileHash -Path $Source)
        if (-not $sameBytes) {
            $backupName = "{0}.aefos-preexisting-{1}.bak" -f $Name, $Stamp
            Copy-Item -LiteralPath $dest -Destination (Join-Path $LazDir $backupName) -Force
            $record['backup'] = $backupName
            Write-WarnMsg "A different $Name was already beside lazarus.exe; preserved as $backupName and restored on uninstall."
        }
    }
    Copy-Item -LiteralPath $Source -Destination $dest -Force
    $record['ourSha256'] = Get-AefosFileHash -Path $dest
    return $record
}

# One stamp for every file this run preserves. It mirrors -BackupStamp when the
# caller passed one (so a scripted install can pin every artifact name), and is
# minted here otherwise - the exe backup below mints its own when it needs one.
$DllStamp = $BackupStamp
if ([string]::IsNullOrWhiteSpace($DllStamp)) {
    try { $DllStamp = (Get-Date).ToString('yyyyMMdd-HHmmss') } catch { $DllStamp = 'stamp' }
}

# Copy a shipped DLL through Copy-AefosRuntimeDll and fold the record into $State.
function Register-AefosRuntimeDll {
    param(
        [hashtable]$State,
        [string]$Source,
        [string]$LazDir,
        [string]$Name,
        [string]$Stamp,
        [string]$StatePath
    )
    $existing = Get-AefosStateRecord -Records $State['dlls'] -Name $Name
    $record = Copy-AefosRuntimeDll -Source $Source -LazDir $LazDir -Name $Name -Stamp $Stamp -Existing $existing
    if (-not $existing) { $State['dlls'] = @($State['dlls']) + @($record) }
    Write-AefosInstallState -Path $StatePath -State $State
}

# ---------------------------------------------------------------------------
# Idempotent, timestamped backup of the stock lazarus.exe.
#   The FIRST backup is the precious one (stock IDE). Never overwrite it on a
#   re-run, and never back up an already-Aefos-linked exe as if it were stock.
# ---------------------------------------------------------------------------
Write-Step "`n-- Backing up lazarus.exe --"
$existingBackups = @(Get-ChildItem -Path $LazDir -Filter 'lazarus-aefos-backup-*.exe' -ErrorAction SilentlyContinue)
$StockBackup = $null   # the exe to restore if the rebuilt IDE fails the runnable gate
if ($existingBackups.Count -gt 0) {
    $StockBackup = $existingBackups[0].FullName
    Write-Ok "Stock backup already present ($($existingBackups[0].Name)); keeping it (idempotent re-run)."
} else {
    if ([string]::IsNullOrWhiteSpace($BackupStamp)) {
        try { $BackupStamp = (Get-Date).ToString('yyyyMMdd-HHmmss') }
        catch {
            $n = 1
            while (Test-Path -LiteralPath (Join-Path $LazDir ("lazarus-aefos-backup-{0:D3}.exe" -f $n))) { $n++ }
            $BackupStamp = ('{0:D3}' -f $n)
        }
    }
    $BackupPath = Join-Path $LazDir ("lazarus-aefos-backup-{0}.exe" -f $BackupStamp)
    Copy-Item -LiteralPath $LazExe -Destination $BackupPath -Force
    $StockBackup = $BackupPath
    Write-Ok "Backed up stock lazarus.exe -> $BackupPath"
}

# ---------------------------------------------------------------------------
# Register the package link, then rebuild the IDE with it statically linked.
# ---------------------------------------------------------------------------
$pcpArg = @()
if (-not [string]::IsNullOrWhiteSpace($Pcp)) { $pcpArg = @("--pcp=$Pcp") }

Write-Step "`n-- Registering package link --"

# The package link is what lets Lazarus resolve THIS package BY NAME the next
# time the IDE is rebuilt (e.g. the user installs something via Online Package
# Manager). staticpackages.inc only carries the name; without a link that points
# at a real .lpk, such a rebuild fails and takes the user's IDE with it.
#
# ⚠️ Two lazbuild traps, both paid for on 2026-07-17:
#   1. lazbuild's own --help documents "--add-package-link=<.lpk file>", but its
#      option parser REJECTS that form ("Option at position N does not allow an
#      argument: add-package-link"). The file must be POSITIONAL.
#   2. lazbuild exits 0 ANYWAY after rejecting it. So the exit code proves
#      nothing and the old `if ($LASTEXITCODE -ne 0) { throw }` could never fire:
#      the step was a silent no-op that always announced success.
# Therefore: use the positional form AND verify the link actually landed.
$LinksFile = if ($Pcp) { Join-Path $Pcp 'packagefiles.xml' } else { $null }

function Get-AefosLinks {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    try { $xml = [xml](Get-Content -LiteralPath $Path -Raw) } catch { return @() }
    $links = $xml.CONFIG.UserPkgLinks
    if (-not $links) { return @() }
    return @($links.ChildNodes | Where-Object { $_.Name.Value -eq $PkgName })
}

# Make the INSTALLED copy authoritative: drop every other link that carries our
# package name, whether its .lpk still exists or not. Two links with the same
# name is precisely the ambiguity that makes a later IDE rebuild resolve the
# wrong (or a dead) one. Observed on the maintainer's machine: three entries left
# by deleted dev worktrees plus a live one from a build tree. Only entries for
# OUR package are touched - nobody else's links are read or written.
if ($LinksFile -and (Test-Path -LiteralPath $LinksFile)) {
    $xml = [xml](Get-Content -LiteralPath $LinksFile -Raw)
    $links = $xml.CONFIG.UserPkgLinks
    if ($links) {
        # Match on package name AND foreign path, so only OUR duplicates go.
        $conflicts = @($links.ChildNodes | Where-Object {
            $_.Name.Value -eq $PkgName -and $_.Filename.Value -ne $Lpk
        })
        foreach ($node in $conflicts) {
            $state = if (Test-Path -LiteralPath $node.Filename.Value) { 'live' } else { 'dead' }
            Write-WarnMsg "Removing conflicting $PkgName link ($state) -> $($node.Filename.Value)"
        }
        if ($conflicts.Count -gt 0) {
            # Removing WITHOUT renumbering used to leave Item1, Item3, ... and the
            # index read above then dropped whichever of the USER'S links landed in
            # the hole. Set-AefosIndexedList removes and closes the gaps in one go.
            $kept = Set-AefosIndexedList -ListNode $links -Remove $conflicts
            $xml.Save($LinksFile)
            Write-Ok "Package links renumbered; $kept link(s) kept."
        }
    }
}

& $LazBuild @pcpArg --add-package-link "$Lpk"
# Exit code is not evidence here (trap 2) - verify the link is really on file.
$registered = @(Get-AefosLinks -Path $LinksFile |
    Where-Object { $_.Filename.Value -eq $Lpk })
if ($LinksFile -and $registered.Count -eq 0) {
    throw "lazbuild did not register the package link for '$Lpk' in '$LinksFile'. A later IDE rebuild would not find the package."
}
Write-Ok "Package link registered."

# ---------------------------------------------------------------------------
# environmentoptions.xml: WE DO NOT WRITE IT. Not one leaf, not even a new one.
#
# THE RULE (owner, 2026-07-27, after an install wrecked a real user's IDE): an
# install may only ADD to the XML files Lazarus maintains, never ALTER a value
# that is already the user's; an uninstall removes only what is ours. Up to
# 0.24.7 this file's Set-AefosIdeSilence broke that rule three times over -- it
# forced DebuggerOptions/ShowStopMessage=False, DebuggerOptions/
# DebuggerShowExitCodeMessage=False and EnvironmentOptions/
# CheckDiskChangesWithLoading=True into the USER'S config, silencing IDE dialogs
# he never asked us to silence.
#
# The protection those three keys bought was real and is NOT abandoned: modal
# boxes are pumped by the IDE MAIN THREAD, the same thread the in-process MCP host
# answers tool calls on, so one open modal freezes the pipe and an agent with no
# human in front of the IDE deadlocks. It simply moved to where it belongs -- OUR
# code, INSIDE the IDE, scoped to the moment the pipe is at risk:
#
#   source\lazarus\ide\Aefos.Lazarus.IdeSilence.pas
#     * debugger "Execution stopped" + exit-code boxes: the IDE's OWN one-shot
#       TDebuggerIntf.SetSkipStopMessage (dbgintfdebuggerbase.pp:1763), armed from
#       a debugger state-change handler ONLY for a run Aefos itself dispatched
#       (RunProject / StopProject / DebugContinue). The developer's own F9 run
#       still shows him exactly the dialogs he configured.
#     * "Some files have changed on disk" (DiskDiffsDialog): LazarusIDE
#       .CheckFilesOnDiskEnabled -- a PUBLIC property of TLazIDEInterface
#       (ideintf\lazideintf.pas:589), read at the top of DoCheckFilesOnDisk
#       (ide\main.pp:8856) -- turned off for the duration of ONE marshalled MCP
#       tool call and put straight back. (The 2026-07-19 commit that introduced
#       the config seed recorded that flag as "a private TMainIDE field"; it never
#       was, and that single wrong reading is what sent the fix into the user's XML.)
#
# So the ONLY thing this step does now is HEAL: if a previous Aefos install wrote
# those three keys, give them back. Same two safety rules the uninstaller uses --
# "did not exist" is undone by REMOVING the node (never by inventing a default),
# and a value that is no longer the one we wrote was changed by the USER since,
# so it is left alone.
function Repair-AefosIdePrefs {
    param([string]$ConfigDir, [object[]]$Prefs)
    if (@($Prefs).Count -eq 0) { return $false }
    if ([string]::IsNullOrWhiteSpace($ConfigDir)) { return $false }
    $envXml = Join-Path $ConfigDir 'environmentoptions.xml'
    if (-not (Test-Path -LiteralPath $envXml)) { return $false }
    try {
        [xml]$doc = Get-Content -LiteralPath $envXml -Raw
        $changed = 0
        foreach ($pref in @($Prefs)) {
            $path = [string]$pref['path']
            if (-not $path) { continue }
            $leaf = $doc.DocumentElement.SelectSingleNode($path)
            if (-not $leaf) { continue }          # already gone - nothing to undo
            if ($leaf.GetAttribute('Value') -ne [string]$pref['applied']) {
                Write-WarnMsg "Keeping your own $path = $($leaf.GetAttribute('Value')) (you changed it after the install)."
                continue
            }
            if ($pref['existed']) {
                $leaf.SetAttribute('Value', [string]$pref['original'])
                Write-Ok "Gave back $path = $([string]$pref['original'])."
            } else {
                [void]$leaf.ParentNode.RemoveChild($leaf)
                Write-Ok "Removed $path (it did not exist before Aefos)."
            }
            $changed++
        }
        if ($changed -gt 0) { $doc.Save($envXml) }
        return $true
    } catch {
        Write-WarnMsg "Could not give the IDE preferences back: $($_.Exception.Message)"
        return $false
    }
}
$AefosCfgDir = if ($Pcp) { $Pcp } else { Join-Path $env:LOCALAPPDATA 'lazarus' }
if (@($InstallState['idePrefs']).Count -gt 0) {
    Write-Step "`n-- Giving back the IDE preferences an older Aefos install changed --"
    # Repair into the pcp the INSTALL recorded, not the one this run guessed (an
    # elevated run can resolve {localappdata} into another profile).
    $RepairCfgDir = $AefosCfgDir
    if ($InstallState['pcp'] -and (Test-Path -LiteralPath ([string]$InstallState['pcp']))) {
        $RepairCfgDir = [string]$InstallState['pcp']
    }
    if (Repair-AefosIdePrefs -ConfigDir $RepairCfgDir -Prefs $InstallState['idePrefs']) {
        # Healed (or nothing left to heal): drop the record so no later uninstall
        # tries to "restore" preferences that are already the user's again.
        $InstallState['idePrefs'] = @()
        Write-AefosInstallState -Path $StatePath -State $InstallState
    }
}

# ---------------------------------------------------------------------------
# PRE-FLIGHT: the IDE install list belongs to the USER, not to us.
#
# `lazbuild --build-ide` rebuilds the IDE with EVERY package in the install list
# (<pcp>\miscellaneousoptions.xml <StaticAutoInstallPackages>) -- ours PLUS
# whatever the user already had installed. If any one of those cannot be resolved
# to a real .lpk, lazbuild aborts the ENTIRE rebuild ("Unable to open the package
# ... This package was marked for installation") before compiling a single Aefos
# unit.
#
# Field report (partner, 2026-07-25): a stale third-party package
# (ConnectComponents) with no surviving package link killed the install on Lazarus
# 4.8 + FPC 3.2.2 -- an environment identical to the one we build on. The user
# reads "Aefos failed to install" and blames us for their own broken IDE.
#
# So NAME THE CULPRIT UP FRONT. This only WARNS: the resolution below mirrors
# lazbuild's but is not lazbuild, and the rebuild is non-destructive (it fails
# before lazarus.exe is replaced, and the backup stays put), so a false positive
# must never block an install that would otherwise work.
function Get-AefosIdeInstallList {
    param([string]$ConfigDir)
    $misc = Join-Path $ConfigDir 'miscellaneousoptions.xml'
    if (-not (Test-Path -LiteralPath $misc)) { return @() }
    try { $xml = [xml](Get-Content -LiteralPath $misc -Raw) } catch { return @() }
    $node = $xml.SelectSingleNode('//StaticAutoInstallPackages')
    if (-not $node) { return @() }
    return @($node.ChildNodes |
        ForEach-Object { $_.GetAttribute('Value') } |
        Where-Object { $_ })
}

# Can this package name still be resolved to a .lpk that exists on disk?
# Two ways, the same two lazbuild uses: a user package link, or a package shipped
# inside the Lazarus tree.
function Test-AefosPackageResolvable {
    param([string]$Name, [string]$LinksPath, [hashtable]$LpkMap)
    if (Test-Path -LiteralPath $LinksPath) {
        try {
            $xml = [xml](Get-Content -LiteralPath $LinksPath -Raw)
            $links = $xml.CONFIG.UserPkgLinks
            if ($links) {
                foreach ($node in @($links.ChildNodes)) {
                    if ($node.Name.Value -eq $Name) {
                        $target = $node.Filename.Value
                        if ($target -and (Test-Path -LiteralPath $target)) { return $true }
                    }
                }
            }
        } catch { }
    }
    return $LpkMap.ContainsKey($Name)
}

$InstallList = @(Get-AefosIdeInstallList -ConfigDir $AefosCfgDir)
if ($InstallList.Count -gt 0) {
    # One pass over the Lazarus tree; a per-package recursive scan would be N times
    # the cost for the same answer.
    $LpkMap = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $LazDir -Recurse -Filter '*.lpk' -ErrorAction SilentlyContinue)) {
        if (-not $LpkMap.ContainsKey($file.BaseName)) { $LpkMap[$file.BaseName] = $file.FullName }
    }
    $Unresolved = @()
    foreach ($name in $InstallList) {
        # Ours is registered and verified above - do not re-judge it here.
        if ($name -eq $PkgName) { continue }
        if (-not (Test-AefosPackageResolvable -Name $name -LinksPath $LinksFile -LpkMap $LpkMap)) {
            $Unresolved += $name
        }
    }
    if ($Unresolved.Count -gt 0) {
        Write-WarnMsg @"
Your Lazarus IDE install list contains $($Unresolved.Count) package(s) that cannot be
resolved to an .lpk file on this machine:
    $($Unresolved -join "`n    ")
These are NOT Aefos packages - they were already marked for installation in your
IDE. Rebuilding the IDE (which this installer does, and which Package >
Install/Uninstall Packages does too) fails on them before Aefos is even compiled.
If the rebuild below aborts, remove them in Package > Install/Uninstall Packages
and run this setup again. Nothing is damaged either way: the rebuild fails before
lazarus.exe is replaced, and your backup stays in the Lazarus folder.
"@
    }
}

Write-Step "`n-- Rebuilding lazarus.exe with Aefos linked (this takes a couple of minutes) --"
$LogPath = Join-Path $LazDir 'aefos-laz-buildide.log'

# The chat session store operates the shared %APPDATA%\Aefos\aefos.db (one-brain
# backend) through a standard i386 sqlite3.dll loaded at RUNTIME -- NOT a static
# link. This is what keeps the IDE NORMALLY REBUILDABLE: the IDE link has ZERO C
# dependencies, so this rebuild -- and, crucially, any LATER `lazbuild --build-ide`
# the user runs from Package > Install/Uninstall Packages (to add AnchorDocking or
# any package) -- links with default options, no -Fo/-Fl/-Xe. History (paid for
# 2026-07-18): the previous static-object approach {LINK}ed sqlite3_fpc.o + the
# mingw import libs; it worked ONLY when the installer injected -Fo/-Fl, so the
# user's own normal IDE rebuild failed ("Object sqlite3_fpc.o not found"). The DLL
# removes that trap entirely.
#
# Ship sqlite3.dll beside lazarus.exe (as we do WebView2Loader.dll) so the IDE can
# open aefos.db at runtime. The .iss staged it to {app} (== $ScriptDir).
$SqliteDllSrc = Join-Path $ScriptDir 'sqlite3.dll'
if (-not (Test-Path -LiteralPath $SqliteDllSrc)) {
    throw @"
sqlite3.dll is missing from the installer payload - the chat session store cannot
open aefos.db without it. Rebuild the installer with
installer\lazarus\build-lazarus-installer.ps1 (which stages it) and reinstall.
"@
}
Register-AefosRuntimeDll -State $InstallState -Source $SqliteDllSrc -LazDir $LazDir `
    -Name 'sqlite3.dll' -Stamp $DllStamp -StatePath $StatePath
Write-Ok "Copied sqlite3.dll beside lazarus.exe."

# Ship libvterm.dll beside lazarus.exe too: the terminal panel binds libvterm as a
# RUNTIME DLL (external 'libvterm.dll'), exactly like sqlite3.dll and for the same
# reason -- a static {$LINK} would make the IDE non-rebuildable and drag the mingw
# CRT into the link. The .iss staged it to {app} (== $ScriptDir).
$VtermDllSrc = Join-Path $ScriptDir 'libvterm.dll'
if (-not (Test-Path -LiteralPath $VtermDllSrc)) {
    throw @"
libvterm.dll is missing from the installer payload - the terminal panel cannot
resolve its vterm_* imports without it. Rebuild the installer with
installer\lazarus\build-lazarus-installer.ps1 (which stages it) and reinstall.
"@
}
Register-AefosRuntimeDll -State $InstallState -Source $VtermDllSrc -LazDir $LazDir `
    -Name 'libvterm.dll' -Stamp $DllStamp -StatePath $StatePath
Write-Ok "Copied libvterm.dll beside lazarus.exe."

# -g- -Xs keeps the produced IDE small (no debug info + stripped); they are size
# knobs only, not correctness crutches -- the link has no C object to fold.
$IdeOpts = "-g- -Xs"
Write-Host "IDE build opts: $IdeOpts"
& $LazBuild @pcpArg "--lazarusdir=$LazDir" --add-package $Lpk "--build-ide=$IdeOpts" *>&1 |
    Tee-Object -FilePath $LogPath
$IdeExit = $LASTEXITCODE
if ($IdeExit -ne 0) {
    # Say WHOSE fault it is. A bare "lazbuild exit 2" makes every failure look like
    # an Aefos bug, and the single most common cause is a package the user already
    # had in the IDE install list that no longer resolves (see the pre-flight
    # above). lazbuild names it in the log; surface that name in the error itself.
    #
    # Matched in both languages this installer ships. The pre-flight already covers
    # any other locale, and the generic tail below still points at the real cause.
    $Culprit = $null
    foreach ($line in @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)) {
        if ($line -match 'Unable to open the package "([^"]+)"' -or
            $line -match 'Incapaz de abrir o pacote "([^"]+)"') {
            $Culprit = $Matches[1]
            break
        }
    }
    if ($Culprit) {
        throw @"
IDE rebuild FAILED (lazbuild exit $IdeExit) - and NOT because of Aefos.

Your Lazarus could not open the package "$Culprit", which is marked for
installation in YOUR IDE install list. Rebuilding the IDE requires every package
on that list, so lazbuild aborted before a single Aefos unit was compiled. The
same failure happens on any Package > Install/Uninstall Packages rebuild, with or
without Aefos.

To fix it: open Lazarus, go to Package > Install/Uninstall Packages, remove
"$Culprit" (and any other package the IDE reports as missing on startup) from the
right-hand list, click "Save and rebuild IDE", then run this setup again.

Nothing was damaged. The rebuild fails before lazarus.exe is replaced, and your
backup is in '$LazDir'. Full log: '$LogPath'.
"@
    }
    throw "IDE rebuild FAILED (lazbuild exit $IdeExit). See '$LogPath'. Your previous lazarus.exe backup is in '$LazDir'."
}
Write-Ok "lazarus.exe rebuilt."

# ---------------------------------------------------------------------------
# RUNNABLE GATE (paid for 2026-07-18): a link that "succeeds" is NOT proof the
# exe runs. The first SQLite cut linked a 236 MB exe that lazbuild reported OK,
# yet Windows refused to start it ("not a valid application for this OS
# platform"). Never hand the user an IDE we did not watch start. So: START the
# rebuilt exe against a throwaway pcp and assert the loader accepts it (the
# process spawns; a rejected PE never spawns - CreateProcess throws at once).
# lazarus.exe --help does not halt (it opens the GUI), so we launch, confirm the
# process is alive a moment, then kill it. If it will not start, RESTORE the stock
# backup so the user is left with a working IDE, and fail loud.
# ---------------------------------------------------------------------------
Write-Step "`n-- Verifying the rebuilt lazarus.exe actually starts --"
$RunPcp = Join-Path $env:TEMP ("aefos-laz-rungate-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $RunPcp | Out-Null
$Started = $false
try {
    $proc = Start-Process -FilePath $LazExe -ArgumentList @("--pcp=$RunPcp") `
        -PassThru -WindowStyle Hidden -ErrorAction Stop
    Start-Sleep -Seconds 4
    if (-not $proc.HasExited) {
        $Started = $true
        try { $proc.Kill() } catch { }
    } else {
        # Any spawn-then-exit still proves the loader accepted the image.
        $Started = $true
        Write-Host "  (process started then exited with code $($proc.ExitCode))"
    }
} catch {
    Write-WarnMsg "  Rebuilt lazarus.exe FAILED TO START: $($_.Exception.Message)"
    $Started = $false
}
Remove-Item -Recurse -Force $RunPcp -ErrorAction SilentlyContinue

# Put a working lazarus.exe back after a failed runnable gate. Returns the line to
# show the user, or '' when there was nothing to put back.
#
# WHY lazarus.old.exe is only ever READ here, never written or deleted: it is
# LAZARUS' OWN rollback slot, not ours. `make` renames the current lazarus.exe to
# lazarus.old.exe before every link, so it is the file the USER falls back on
# through their own Tools > Build Lazarus. Our timestamped backup is OUR net;
# consuming theirs to compensate for our failure takes away a recovery path that
# has nothing to do with us.
#
# And it is NOT a stock exe: after any earlier Aefos install it is itself
# Aefos-linked (proven on the maintainer's machine 2026-07-17, hashes in the
# uninstall engine's comment). It is still the user's last WORKING binary, so we
# do restore it - but we say what it actually is instead of announcing a stock
# restore that did not happen.
function Restore-AefosWorkingIde {
    param([string]$LazDir, [string]$LazExe, [string]$StockBackup, [string]$PkgName)
    if ($StockBackup -and (Test-Path -LiteralPath $StockBackup)) {
        Copy-Item -LiteralPath $StockBackup -Destination $LazExe -Force
        return "Restored your stock lazarus.exe from our backup ($StockBackup)."
    }
    $old = Join-Path $LazDir 'lazarus.old.exe'
    if (-not (Test-Path -LiteralPath $old)) { return '' }
    $carriesAefos = [bool](Select-String -Path $old -Pattern $PkgName `
        -Encoding default -SimpleMatch -List -ErrorAction SilentlyContinue)
    Copy-Item -LiteralPath $old -Destination $LazExe -Force
    if ($carriesAefos) {
        return "Our backup was gone, so your lazarus.exe was rebuilt from Lazarus' own lazarus.old.exe - which is a PREVIOUS AEFOS BUILD, not a stock IDE. It starts and works; lazarus.old.exe itself was left untouched."
    }
    return "Our backup was gone, so your lazarus.exe was restored from Lazarus' own lazarus.old.exe (scanned: carries no $PkgName). lazarus.old.exe itself was left untouched."
}

if (-not $Started) {
    $RestoreNote = Restore-AefosWorkingIde -LazDir $LazDir -LazExe $LazExe `
        -StockBackup $StockBackup -PkgName $PkgName
    if ($RestoreNote) { Write-WarnMsg $RestoreNote }
    throw "The rebuilt lazarus.exe does not start on this machine (see '$LogPath'). Your previous working IDE has been restored; Aefos was NOT installed."
}
Write-Ok "Runnable gate passed: lazarus.exe starts."

# ---------------------------------------------------------------------------
# Drop WebView2Loader.dll beside lazarus.exe (chat rendering).
# ---------------------------------------------------------------------------
Write-Step "`n-- WebView2 loader --"
if (Test-Path -LiteralPath $WebView2Loader) {
    Register-AefosRuntimeDll -State $InstallState -Source $WebView2Loader -LazDir $LazDir `
        -Name 'WebView2Loader.dll' -Stamp $DllStamp -StatePath $StatePath
    Write-Ok "Copied WebView2Loader.dll beside lazarus.exe."
} else {
    Write-WarnMsg "WebView2Loader.dll not found at '$WebView2Loader' - the chat needs it. Copy the x86 WebView2Loader.dll next to lazarus.exe manually."
}

# ---------------------------------------------------------------------------
# Prove the static link (mirrors scripts\build-lazarus.ps1's proof):
#   (a) staticpackages.inc lists the package, AND
#   (b) the rebuilt exe carries the package name + the "Aefos AI Chat" menu.
# ---------------------------------------------------------------------------
Write-Step "`n-- Verifying the static link --"
$incCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($Pcp)) { $incCandidates += (Join-Path $Pcp 'staticpackages.inc') }
$incCandidates += (Join-Path $LazDir 'staticpackages.inc')
$incCandidates += (Join-Path $LazDir 'ide\staticpackages.inc')
$StaticInc = $incCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$incOk = $false
if ($StaticInc) {
    $incOk = ((Get-Content -LiteralPath $StaticInc -Raw) -match [Regex]::Escape($PkgName))
}
$exeHasPkg  = Select-String -Path $LazExe -Pattern $PkgName    -SimpleMatch -Quiet
$exeHasMenu = Select-String -Path $LazExe -Pattern $MenuString -SimpleMatch -Quiet

if ($StaticInc) { $incWhere = $StaticInc } else { $incWhere = 'not found' }
Write-Host ("staticpackages.inc lists {0} : {1}  ({2})" -f $PkgName, $incOk, $incWhere)
Write-Host ("lazarus.exe carries '{0}'      : {1}" -f $PkgName, [bool]$exeHasPkg)
Write-Host ("lazarus.exe carries '{0}'      : {1}" -f $MenuString, [bool]$exeHasMenu)

if (-not ($exeHasPkg -and $exeHasMenu)) {
    throw "Rebuilt lazarus.exe does NOT prove the Aefos link (package/menu string missing). See '$LogPath'."
}

Write-Ok "`nAefos AI is now statically linked into lazarus.exe."
Write-Host "Restart Lazarus. You'll see the 'Aefos AI' menu on the menu bar." -ForegroundColor Green
