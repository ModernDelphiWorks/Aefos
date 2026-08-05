<#
.SYNOPSIS
    On-machine UNINSTALL engine for the Aefos AI Lazarus edition.

.DESCRIPTION
    Reverses aefos-laz-install.ps1. Because Aefos is STATICALLY LINKED into
    lazarus.exe (not a droppable BPL), "uninstalling" means getting a stock
    lazarus.exe back. Two methods:

      * Restore (default) - copy the timestamped stock backup that the install
        engine made over lazarus.exe. Instant, byte-exact, no rebuild. Falls
        back to Lazarus' own lazarus.old.exe if our backup is gone AND that copy
        is provably Aefos-free.
      * Rebuild - rebuild lazarus.exe from the IDE install list, minus Aefos.
        OPT-IN ONLY. It is NEVER selected automatically, because it rebuilds the
        user's IDE from THEIR package list and can hand back an IDE missing their
        components. When Restore finds nothing to restore, this engine stops and
        says so instead (see the "could not restore" section at the end).

    Either way it also:
      - removes the Aefos package link from the pcp (packagefiles.xml),
      - removes Aefos from the IDE install list (miscellaneousoptions.xml
        StaticAutoInstallPackages), so no later IDE rebuild of the user's fails
        on a package name that no longer resolves,
      - removes the shipped WebView2Loader.dll + sqlite3.dll + libvterm.dll beside
        lazarus.exe, but ONLY once a non-Aefos lazarus.exe is actually in place
        (see the DLL section for why removing them too early bricks the IDE), and
        RESTORES any same-named DLL of the user's that the install displaced,
      - puts back the three IDE preferences the install changed
        (ShowStopMessage, DebuggerShowExitCodeMessage, CheckDiskChangesWithLoading),
        unless the user has since changed them again,
      - removes the shipped source tree (when -RemoveSources points at it).

    What was there before us is read from aefos-laz-install-state.json, written by
    the install engine into the Lazarus directory. An install made by an older
    build has no such file; every step then falls back to its legacy behaviour.

    Both config edits go through Set-AefosIndexedList, which renumbers the list.
    Read its comment before touching either edit: Lazarus reads these lists BY
    INDEX, so a wrong Count or a numbering hole silently discards packages that
    are not ours.

    The rebuilt-IDE unit objects the install left under the Lazarus directory are
    inert once a stock lazarus.exe is in place; they are ignored here.

.PARAMETER Method
    Restore (default) or Rebuild. Rebuild must be asked for explicitly; a failed
    Restore never escalates to it on its own.

.PARAMETER LazarusDir
    Override the detected Lazarus directory.

.PARAMETER Pcp
    Override the detected primary config path.

.PARAMETER SourceRoot
    Root that holds packages\Lazarus\Aefos.Lazarus.IDE.lpk (needed for a Rebuild
    and to locate the link to remove). Defaults to two levels above this script.

.PARAMETER RemoveSources
    Also delete this folder (the shipped source tree) at the end.
#>

[CmdletBinding()]
param(
    [ValidateSet('Restore', 'Rebuild')]
    [string]$Method = 'Restore',
    [string]$LazarusDir,
    [string]$Pcp,
    [string]$SourceRoot,
    [string]$RemoveSources
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PkgName    = 'Aefos.Lazarus.IDE'
$LpkRelPath = 'packages\Lazarus\Aefos.Lazarus.IDE.lpk'

function Write-Step($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host $msg -ForegroundColor Green }
function Write-WarnMsg($m){ Write-Host $m  -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Drop nodes from a Lazarus <ItemN> list, then leave the list CONSISTENT:
# renumbered Item1..ItemN with no holes, and a Count attribute equal to the real
# number of items. Returns that number.
#
# WHY the renumbering is not cosmetic: Lazarus does not walk this XML, it reads
# it BY INDEX. ide\packages\idepackager\packagelinks.pas:614-619 does
#     LinkCount := XMLConfig.GetValue(Path+'Count', 0);
#     for i := 1 to LinkCount do ... ItemPath := Path+'Item'+IntToStr(i)+'/';
# so plain RemoveChild leaves Item1, Item3 and the read of "Item2" comes back
# empty -- one of the USER'S packages vanishes even though its XML is still on
# disk. A Count that is too low truncates the tail the same way.
#
# WHY $_.LocalName and never $_.Name: PowerShell's XML adapter SHADOWS the .NET
# XmlNode.Name property with the child element named <Name>. For
# <Item1><Name Value="rxtools"/></Item1> the expression $_.Name evaluates to an
# XmlElement, NOT the string 'Item1', so a filter like { $_.Name -like 'Item*' }
# matches NOTHING. That single expression wrote Count="0" into a real user's
# packagefiles.xml; Lazarus then loaded ZERO package links, could not resolve any
# third-party component package, and dropped them all from the install list. Do
# not reintroduce it. ($_.Name.Value IS correct where the <Name> child is what we
# actually want -- that is the same shadowing, used deliberately.)
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

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
}

# ---------------------------------------------------------------------------
# Detect lazbuild / Lazarus dir (same logic as the install engine).
# ---------------------------------------------------------------------------
function Find-LazBuild {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $c = Join-Path $Override 'lazbuild.exe'
        if (Test-Path -LiteralPath $c) { return $c }
        throw "No lazbuild.exe under '$Override'."
    }
    $cmd = Get-Command 'lazbuild.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        'C:\lazarus', 'C:\Lazarus',
        (Join-Path $env:SystemDrive 'lazarus'),
        (Join-Path ${env:ProgramFiles} 'Lazarus'),
        (Join-Path ${env:ProgramFiles(x86)} 'Lazarus')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($d in $candidates) {
        $c = Join-Path $d 'lazbuild.exe'
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $regKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\lazarus',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\lazarus',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\lazarus'
    )
    foreach ($k in $regKeys) {
        try {
            $loc = (Get-ItemProperty -Path $k -Name 'InstallLocation' -ErrorAction Stop).InstallLocation
            if ($loc) { $c = Join-Path $loc 'lazbuild.exe'; if (Test-Path -LiteralPath $c) { return $c } }
        } catch { }
    }
    throw "Could not find a Lazarus installation (lazbuild.exe). Pass -LazarusDir."
}

$LazBuild = Find-LazBuild -Override $LazarusDir
$LazDir   = Split-Path -Parent $LazBuild
$LazExe   = Join-Path $LazDir 'lazarus.exe'

if ([string]::IsNullOrWhiteSpace($Pcp)) {
    $defaultPcp = Join-Path $env:LOCALAPPDATA 'lazarus'
    if (Test-Path -LiteralPath $defaultPcp) { $Pcp = $defaultPcp }
}

# ---------------------------------------------------------------------------
# The install state: what the install engine found BEFORE it changed anything.
#
# Written by aefos-laz-install.ps1 into the Lazarus directory (see the long
# comment there for why it lives beside lazarus.exe and not under %APPDATA%).
# Without it this engine cannot tell a DLL it created from one it overwrote, nor
# an IDE preference it invented from one it changed - and the only behaviour left
# is the destructive one. Absent = an install made by an older build; every
# consumer below falls back to the legacy behaviour instead of guessing.
#
# Twin of the reader in the install engine (the two ship standalone, so it lives
# in both). Every record comes back as a hashtable so a missing key reads as $null
# instead of throwing under StrictMode.
function Read-AefosInstallState {
    param([string]$Path)
    $result = @{ schema = 1; dlls = @(); idePrefs = @() }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    try { $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $result }
    foreach ($listName in @('dlls', 'idePrefs')) {
        $items = @()
        if (@($raw.PSObject.Properties.Name) -contains $listName) {
            foreach ($entry in @($raw.$listName)) {
                $record = @{}
                foreach ($prop in $entry.PSObject.Properties) { $record[$prop.Name] = $prop.Value }
                $items += $record
            }
        }
        $result[$listName] = $items
    }
    if (@($raw.PSObject.Properties.Name) -contains 'pcp') { $result['pcp'] = $raw.pcp }
    return $result
}

$StatePath    = Join-Path $LazDir 'aefos-laz-install-state.json'
$HasState     = Test-Path -LiteralPath $StatePath
$InstallState = Read-AefosInstallState -Path $StatePath

Write-Step "== Aefos AI - Lazarus edition uninstall =="
Write-Host "lazarus dir : $LazDir"
Write-Host "pcp         : $Pcp"
Write-Host "method      : $Method"
if ($HasState) { Write-Host "state file  : $StatePath" }
else { Write-Host "state file  : none (installed by an older build)" }

# An unrecognizable pcp is not fatal here - nothing below writes into a config it
# cannot read - but it does mean the package link and the install-list entry are
# NOT being cleaned, and the user must know. The usual cause is the same
# elevated-profile mismatch the install engine now refuses outright: setup was
# elevated with another account, so {localappdata} is not the user's.
if (-not [string]::IsNullOrWhiteSpace($Pcp) -and
    -not (Test-Path -LiteralPath (Join-Path $Pcp 'packagefiles.xml')) -and
    -not (Test-Path -LiteralPath (Join-Path $Pcp 'environmentoptions.xml'))) {
    Write-WarnMsg @"
The Lazarus configuration folder '$Pcp' holds no Lazarus config files, so it is
probably not the one your IDE uses. The Aefos package link and install-list entry
cannot be cleaned from a config we cannot see. If the Aefos entry is still listed
in Package > Install/Uninstall Packages after this, remove it there.
"@
}

# ---------------------------------------------------------------------------
# Get a stock lazarus.exe back.
# ---------------------------------------------------------------------------
$restored = $false
if ($Method -eq 'Restore') {
    Write-Step "`n-- Restoring stock lazarus.exe --"
    $backup = Get-ChildItem -Path $LazDir -Filter 'lazarus-aefos-backup-*.exe' -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -First 1
    if (-not $backup) {
        # ! lazarus.old.exe is NOT a stock exe. It is lazbuild's own ROLLING
        # backup: make renames the previous lazarus.exe aside before linking, so
        # after any Aefos install it is itself an Aefos-linked build. Verified on
        # the maintainer's machine 2026-07-17 - after repeated installs both
        # lazarus.exe AND lazarus.old.exe hashed 530096CE, while the real stock
        # (91266E13) survived only in our timestamped backup. Copying it blindly
        # would leave Aefos linked in and still announce a stock restore.
        $old = Join-Path $LazDir 'lazarus.old.exe'
        $oldExists = Test-Path -LiteralPath $old
        $oldIsClean = $false
        if ($oldExists) {
            $oldIsClean = -not (Select-String -Path $old -Pattern $PkgName `
                -Encoding default -SimpleMatch -List -ErrorAction SilentlyContinue)
        }
        if ($oldExists -and $oldIsClean) {
            Write-WarnMsg "No Aefos backup found; falling back to Lazarus' own lazarus.old.exe (scanned: carries no $PkgName)."
            Copy-Item -LiteralPath $old -Destination $LazExe -Force
            $restored = $true
        } elseif ($oldExists) {
            Write-WarnMsg "No Aefos backup found, and lazarus.old.exe still carries $PkgName (it is lazbuild's rolling backup, not a stock exe)."
        } else {
            Write-WarnMsg "No backup of your stock lazarus.exe was found."
        }
        # NOTE: no automatic fall back to a rebuild here -- see the "could not
        # restore" section near the end for why an unattended rebuild is the more
        # destructive outcome, not the safer one.
    } else {
        Copy-Item -LiteralPath $backup.FullName -Destination $LazExe -Force
        Remove-Item -LiteralPath $backup.FullName -Force
        Write-Ok "Restored stock lazarus.exe from $($backup.Name)."
        $restored = $true
    }
}

# ---------------------------------------------------------------------------
# Remove the Aefos package link from the pcp (packagefiles.xml).
#
# This file is the USER'S, and every entry that is not ours belongs to a package
# WE never installed (rxtools, MetaDarkStyle, OPM downloads, ...). Touch only the
# entries whose <Name Value=...> is exactly ours, and hand the rest to
# Set-AefosIndexedList so the list stays index-readable.
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($Pcp)) {
    $pkgFiles = Join-Path $Pcp 'packagefiles.xml'
    if (Test-Path -LiteralPath $pkgFiles) {
        Write-Step "`n-- Removing the Aefos package link --"
        try {
            [xml]$doc = Get-Content -LiteralPath $pkgFiles -Raw
            $userPkgs = $doc.SelectSingleNode('//UserPkgLinks')
            $removed = 0
            if ($userPkgs) {
                $toRemove = @()
                foreach ($child in $userPkgs.ChildNodes) {
                    $nameNode = $child.SelectSingleNode('Name')
                    if ($nameNode -and ($nameNode.GetAttribute('Value') -eq $PkgName)) { $toRemove += $child }
                }
                $removed = @($toRemove).Count
                if ($removed -gt 0) {
                    $kept = Set-AefosIndexedList -ListNode $userPkgs -Remove $toRemove
                    $doc.Save($pkgFiles)
                    Write-Ok "Removed $removed Aefos link entry/entries from packagefiles.xml ($kept link(s) of yours kept)."
                } else {
                    Write-Ok "No Aefos link entry in packagefiles.xml; nothing to remove."
                }
            }
        } catch {
            Write-WarnMsg "Could not edit packagefiles.xml automatically: $($_.Exception.Message)"
        }
    }

    # -----------------------------------------------------------------------
    # Remove Aefos from the IDE install list (miscellaneousoptions.xml
    # <StaticAutoInstallPackages>).
    #
    # Leaving it behind is a TIME BOMB in the user's IDE, not a cosmetic leftover:
    # the list survives us, the .lpk it names does not (the installer deletes the
    # shipped source tree), and `lazbuild --build-ide` / Package > Install/Uninstall
    # Packages ABORT the whole rebuild on the first package they cannot open
    # ("Unable to open the package ..."). So every future IDE rebuild of theirs
    # would fail on OUR ghost -- the exact failure our own install pre-flight warns
    # about. Same index-read contract as the links above, hence the same helper.
    # -----------------------------------------------------------------------
    $miscFile = Join-Path $Pcp 'miscellaneousoptions.xml'
    if (Test-Path -LiteralPath $miscFile) {
        Write-Step "`n-- Removing Aefos from the IDE install list --"
        try {
            [xml]$miscDoc = Get-Content -LiteralPath $miscFile -Raw
            $autoInstall = $miscDoc.SelectSingleNode('//StaticAutoInstallPackages')
            if ($autoInstall) {
                $toRemove = @()
                foreach ($child in $autoInstall.ChildNodes) {
                    if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                    if ($child.GetAttribute('Value') -eq $PkgName) { $toRemove += $child }
                }
                if (@($toRemove).Count -gt 0) {
                    $kept = Set-AefosIndexedList -ListNode $autoInstall -Remove $toRemove
                    $miscDoc.Save($miscFile)
                    Write-Ok "Removed $PkgName from the IDE install list ($kept package(s) of yours kept)."
                } else {
                    Write-Ok "$PkgName is not in the IDE install list; nothing to remove."
                }
            }
        } catch {
            Write-WarnMsg "Could not edit miscellaneousoptions.xml automatically: $($_.Exception.Message)"
        }
    }

    # staticpackages.inc is DELIBERATELY left alone. It is GENERATED output, not
    # our state: lazbuild rewrites it from <StaticAutoInstallPackages> at the start
    # of every --build-ide, so the entry we just removed above disappears from it on
    # the user's next rebuild anyway. It also lists EVERYONE's statically linked
    # packages (anchordockpkg, allsyneditdsgn, dockedformeditor, ...), so the old
    # "delete the file in three locations" cleanup was deleting shared state -- in
    # the user's own pcp -- to remove one line we did not even need to remove.
}

# ---------------------------------------------------------------------------
# Give the three IDE preferences back.
#
# HISTORICAL PATH. Up to 0.24.7 the install engine wrote ShowStopMessage=False,
# DebuggerShowExitCodeMessage=False and CheckDiskChangesWithLoading=True into the
# USER'S environmentoptions.xml so IDE modals could not freeze the MCP pipe on the
# main thread. Nothing ever changed them back: an uninstalled Aefos left the user's
# debugger permanently not telling them that a program stopped, nor what exit code
# it returned - our convenience, billed to them forever.
#
# Since 2026-07-27 the installer writes NONE of them (owner's only-ADD rule; the
# modals are tamed at runtime instead, source\lazarus\ide\Aefos.Lazarus.IdeSilence.pas)
# and an upgrade hands them back on the spot. So idePrefs is empty for anything
# installed from that build on, and this block is dead weight for them. It stays
# for the users who are still on 0.24.7 or older and uninstall without upgrading:
# they must get their preferences back too.
#
# Two rules make this safe:
#   * "did not exist" is restored by REMOVING the node, never by writing a default
#     of our own invention (the IDE's own default may differ, and may change).
#   * a value that is no longer the one we wrote was changed by the USER after the
#     install. That is their decision; leave it alone.
function Restore-AefosIdePrefs {
    param([string]$ConfigDir, [object[]]$Prefs)
    if (@($Prefs).Count -eq 0) { return }
    if ([string]::IsNullOrWhiteSpace($ConfigDir)) { return }
    $envXml = Join-Path $ConfigDir 'environmentoptions.xml'
    if (-not (Test-Path -LiteralPath $envXml)) {
        Write-WarnMsg "No environmentoptions.xml in '$ConfigDir'; nothing to restore."
        return
    }
    try {
        [xml]$doc = Get-Content -LiteralPath $envXml -Raw
        $changed = 0
        foreach ($pref in @($Prefs)) {
            $path = [string]$pref['path']
            if (-not $path) { continue }
            $leaf = $doc.DocumentElement.SelectSingleNode($path)
            if (-not $leaf) { continue }          # already gone - nothing to undo
            $current = $leaf.GetAttribute('Value')
            if ($current -ne [string]$pref['applied']) {
                Write-WarnMsg "Keeping your own $path = $current (you changed it after the install)."
                continue
            }
            if ($pref['existed']) {
                $leaf.SetAttribute('Value', [string]$pref['original'])
                Write-Ok "Restored $path = $([string]$pref['original'])."
            } else {
                [void]$leaf.ParentNode.RemoveChild($leaf)
                Write-Ok "Removed $path (it did not exist before the install)."
            }
            $changed++
        }
        if ($changed -gt 0) {
            $doc.Save($envXml)
            Write-Ok "IDE preferences restored in $envXml."
        } else {
            Write-Ok "No IDE preference still held the value we set; yours were left as they are."
        }
    } catch {
        Write-WarnMsg "Could not restore the IDE preferences: $($_.Exception.Message)"
    }
}

# Restore into the pcp the INSTALL recorded, not the one this run guessed: an
# elevated uninstall can resolve {localappdata} into another profile, and writing
# into the wrong config would be a fresh injury rather than a repair.
$PrefsCfgDir = $Pcp
if ($InstallState['pcp'] -and (Test-Path -LiteralPath ([string]$InstallState['pcp']))) {
    $PrefsCfgDir = [string]$InstallState['pcp']
}
if (@($InstallState['idePrefs']).Count -gt 0) {
    Write-Step "`n-- Restoring the IDE preferences the install changed --"
    Restore-AefosIdePrefs -ConfigDir $PrefsCfgDir -Prefs $InstallState['idePrefs']
}

# ---------------------------------------------------------------------------
# Rebuild without Aefos -- ONLY when the operator explicitly asked for -Method
# Rebuild. It is never an automatic fallback any more.
#
# WHY (this is the rule this whole file exists to enforce): `lazbuild --build-ide=`
# does not rebuild "the IDE minus Aefos". It rebuilds the IDE from the USER'S
# <StaticAutoInstallPackages> list, and that list is theirs -- anchordockingdsgn,
# dockedformeditor, SynEditDsgn, whatever they installed over the years. If ONE of
# those no longer resolves to an .lpk on disk, or the link file is stale, the
# rebuild produces an IDE without them. Running that unattended, from an
# UNINSTALLER the user launched to remove OUR product, is how a stranger's working
# Lazarus came back stripped of every third-party component. The old code made it
# worse by only WARNING on a non-zero exit, so the damage was silent.
#
# An uninstaller's contract is "leave no trace", never "rebuild the user's tools".
# So when we cannot hand back a stock lazarus.exe we STOP, leave the working (still
# Aefos-linked) binary exactly as it is, and tell the user in plain words how to
# finish -- one menu action they can see, on their terms. A slightly stale IDE that
# still starts beats a rebuilt one that lost their packages.
# ---------------------------------------------------------------------------
$rebuilt = $false
if ($Method -eq 'Rebuild') {
    Write-Step "`n-- Rebuilding lazarus.exe without Aefos (explicitly requested) --"
    $pcpArg = @()
    if (-not [string]::IsNullOrWhiteSpace($Pcp)) { $pcpArg = @("--pcp=$Pcp") }
    $LogPath = Join-Path $LazDir 'aefos-laz-uninstall-buildide.log'
    & $LazBuild @pcpArg "--lazarusdir=$LazDir" "--build-ide=" *>&1 | Tee-Object -FilePath $LogPath
    if ($LASTEXITCODE -ne 0) {
        # Hard failure, not a warning: a failed --build-ide is exactly the case
        # where lazarus.exe may have been replaced by an incomplete build.
        throw @"
Rebuilding lazarus.exe without Aefos FAILED (lazbuild exit $LASTEXITCODE).

lazbuild rebuilds the IDE from YOUR install list (Package > Install/Uninstall
Packages), so this usually means one of the packages on that list can no longer be
opened - see '$LogPath' for the name.

Aefos has NOT been left half-removed: your package link and install-list entry are
already gone. Open Lazarus, remove the package the log names, and use "Save and
rebuild IDE" to get a clean IDE.
"@
    }
    Write-Ok "Rebuilt a stock lazarus.exe."
    $rebuilt = $true
}

# lazarus.exe is only OURS to strip once a non-Aefos binary is really in place.
$IdeIsClean = ($restored -or $rebuilt)

# ---------------------------------------------------------------------------
# Remove the shipped WebView2 loader + SQLite + libvterm DLLs (all dropped beside
# lazarus.exe by the install engine).
#
# GATED ON $IdeIsClean ON PURPOSE. libvterm.dll is a LOAD-TIME import of an
# Aefos-linked lazarus.exe (source\terminal\Core\Aefos.OTA.Terminal.Core.LibVTerm.pas:
# `external cLibVTerm name 'vterm_*'`), so it is in the exe's import table, not
# LoadLibrary'd on demand. Delete it while the still-Aefos-linked exe is in place
# and Windows refuses to start the process AT ALL - the user's IDE stops opening,
# with no error that points anywhere near us. Leftover DLLs are inert; a missing
# import is fatal. So they go only after a clean lazarus.exe is back, and the
# "could not restore" notice below tells the user they are still there.
# ---------------------------------------------------------------------------
#
# AND "remove" is not always deletion. sqlite3.dll beside lazarus.exe is a normal
# thing for an SQLdb user to keep there, possibly a different build than ours; the
# install engine used to overwrite it with no backup and this engine then DELETED
# it, so a user who handed us a working DLL got back an empty folder. The install
# state says, per DLL, whether we created it or displaced someone else's - and the
# displaced copy is restored instead of removed.
#
# Get-AefosFileHash and not Get-FileHash, for the reason spelled out in the
# install engine: a PSModulePath inherited from a PowerShell 7 parent makes
# Windows PowerShell load PS7's Utility module, which has no Get-FileHash. An
# uninstall must not fall over on a hash comparison.
function Get-AefosFileHash {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Remove-AefosRuntimeDlls {
    param([string]$LazDir, [bool]$HasState, [object[]]$Records)
    foreach ($name in @('WebView2Loader.dll', 'sqlite3.dll', 'libvterm.dll')) {
        $path = Join-Path $LazDir $name
        if (-not $HasState) {
            # Installs older than the state file recorded nothing. Their overwrite
            # already destroyed any foreign copy, so deleting is both the legacy
            # behaviour and the closest thing to "no trace" still available.
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                Write-Ok "Removed $name."
            }
            continue
        }
        $record = $null
        foreach ($entry in @($Records)) {
            if ($entry -and ($entry['name'] -eq $name)) { $record = $entry; break }
        }
        if (-not $record) {
            if (Test-Path -LiteralPath $path) {
                Write-WarnMsg "Leaving ${name}: this install never recorded copying it, so it is not ours to delete."
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        # Is it still the copy WE wrote? If the user swapped it afterwards, the file
        # is theirs now - the same rule the IDE preferences follow above.
        $current = ''
        try { $current = Get-AefosFileHash -Path $path } catch { }
        if ($record['ourSha256'] -and $current -and ($current -ne [string]$record['ourSha256'])) {
            Write-WarnMsg "Leaving ${name}: it is no longer the copy we installed."
            continue
        }
        $backupName = [string]$record['backup']
        if ($backupName) {
            $backupPath = Join-Path $LazDir $backupName
            if (Test-Path -LiteralPath $backupPath) {
                Copy-Item -LiteralPath $backupPath -Destination $path -Force
                Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                Write-Ok "Restored your original $name (the install had displaced it)."
            } else {
                Write-WarnMsg "Your original $name ($backupName) is no longer there; leaving our copy rather than deleting a DLL you may still need."
            }
            continue
        }
        if ($record['preexisting']) {
            Write-Ok "Leaving ${name}: it was already beside lazarus.exe before the install (byte-identical to ours)."
            continue
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Ok "Removed $name."
    }
}

if ($IdeIsClean) {
    Remove-AefosRuntimeDlls -LazDir $LazDir -HasState $HasState -Records $InstallState['dlls']
    # The state described artifacts that are now back the way the user had them;
    # keeping the file would be a leftover of ours in their Lazarus folder.
    if ($HasState) { Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue }
} else {
    Write-WarnMsg "Keeping sqlite3.dll / libvterm.dll / WebView2Loader.dll beside lazarus.exe: your lazarus.exe still has Aefos linked in and would not start without them."
}

# ---------------------------------------------------------------------------
# Remove the shipped source tree if asked.
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($RemoveSources) -and (Test-Path -LiteralPath $RemoveSources)) {
    Write-Step "`n-- Removing shipped sources --"
    try {
        Remove-Item -LiteralPath $RemoveSources -Recurse -Force
        Write-Ok "Removed $RemoveSources."
    } catch {
        Write-WarnMsg "Could not remove '$RemoveSources': $($_.Exception.Message)"
    }
}

if ($IdeIsClean) {
    Write-Ok "`nAefos AI removed. Restart Lazarus - the 'Aefos AI' menu is gone."
    exit 0
}

# ---------------------------------------------------------------------------
# COULD NOT RESTORE: fail LOUD, having changed nothing that can break the IDE.
#
# Everything reversible is already done (package link gone, install-list entry
# gone, DLLs deliberately left in place), so the user's Lazarus still starts and
# their own packages are untouched. What we cannot do without their say-so is
# rebuild their IDE. Say so, in their own words, and leave the same text on disk:
# this runs from Inno's [UninstallRun], whose console window closes the moment we
# exit, so a console-only message is a message nobody reads. Exit non-zero so any
# scripted caller sees a failure instead of a green "removed".
# ---------------------------------------------------------------------------
$Notice = @"
Aefos AI - uninstall could not finish automatically
===================================================

WHAT HAPPENED
Aefos AI is not a plug-in file that can be deleted: on Lazarus it is compiled
INTO lazarus.exe. Removing it means putting a lazarus.exe back that was built
without it. The backup we made of your original lazarus.exe (named
lazarus-aefos-backup-*.exe, in $LazDir) is no longer there, so we have nothing to
put back.

WHAT WE DID
  * Removed the Aefos package link and the Aefos entry from your IDE install
    list. Your other packages were not touched.
  * Left sqlite3.dll, libvterm.dll and WebView2Loader.dll in $LazDir ON PURPOSE:
    your current lazarus.exe still has Aefos compiled in and will NOT START
    without them.

WHAT WE DID NOT DO, AND WHY
We did not rebuild your IDE for you. Rebuilding uses YOUR list of installed
packages, and if any of them cannot be found right now, the rebuilt IDE comes
back missing them. We are not willing to risk your setup to finish removing our
own product. Your Lazarus keeps working exactly as it does today; the only
leftover is the Aefos menu.

HOW TO FINISH (about two minutes, at your convenience)
  1. Open Lazarus.
  2. Package > Install/Uninstall Packages.
  3. Aefos is already off the install list; just click "Save and rebuild IDE".
  4. When Lazarus restarts, the Aefos AI menu is gone. You may then delete
     sqlite3.dll, libvterm.dll and WebView2Loader.dll from $LazDir - EXCEPT that
     if you see a file named like sqlite3.dll.aefos-preexisting-<date>.bak there,
     that is YOUR OWN DLL, which this install had to move aside. Rename it back
     over ours instead of deleting it. aefos-laz-install-state.json in the same
     folder records which file came from where; delete it last.

If step 3 reports it cannot open some OTHER package, that package was already
broken in your IDE - remove it from the right-hand list and rebuild again.
"@
$NoticePath = Join-Path $LazDir 'AEFOS-UNINSTALL-README.txt'
try {
    Set-Content -LiteralPath $NoticePath -Value $Notice -Encoding UTF8
} catch {
    $NoticePath = $null
}

Write-Host ''
Write-WarnMsg '============================================================'
Write-WarnMsg $Notice
if ($NoticePath) { Write-WarnMsg "These instructions were also saved to: $NoticePath" }
Write-WarnMsg '============================================================'
exit 1
