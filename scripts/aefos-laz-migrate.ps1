<#
.SYNOPSIS
    MIGRATION engine: take a machine that already has the IN-PLACE Aefos AI
    Lazarus edition and hand the user's IDE back, stock, before the isolated
    (milestone 2) edition is installed over it.

.DESCRIPTION
    WHY THIS FILE EXISTS
    --------------------
    Up to 0.24.7 the Lazarus edition installed IN PLACE: it relinked the user's
    lazarus.exe with our package compiled in, registered a package link in HIS
    pcp, added our name to HIS IDE install list, dropped three DLLs beside HIS
    lazarus.exe, and left aefos-laz-install-state.json in HIS Lazarus folder.
    Milestone 2 stops doing all of that (the IDE is built into
    %LOCALAPPDATA%\Aefos\lazarus and his tree is never written). That change is
    worthless to the people who ALREADY have the old model on disk: the new
    installer must first give them their IDE back. This engine is that step.

    THE FOUR RULES IT OBEYS (each one paid for on a real machine)
    ------------------------------------------------------------
    1. ONLY-ADD / ONLY-REMOVE-OURS. In the config files Lazarus maintains, an
       install may only ADD, and an uninstall may remove only what is ours. This
       engine reverts what an Aefos install created and nothing else. Every
       entry in packagefiles.xml / StaticAutoInstallPackages that is not named
       Aefos.Lazarus.IDE is read, never written.
    2. NEVER `lazbuild --build-ide` BLIND. Rebuilding the IDE consumes the
       USER'S package list; if one package on it no longer resolves, the rebuilt
       IDE comes back without ANY of his components. That is exactly how a
       partner's working Lazarus came back stripped. This engine never invokes
       lazbuild at all, and it calls the shipped uninstall engine only with
       -Method Restore. There is no code path, flag or fallback that reaches
       Rebuild - the harness asserts this statically.
    3. SAME AppId. Not this file's job, but the reason it can exist: the new
       setup keeps AppId {2B9E7C41-5A3D-4E88-BF12-7C6E9A0D4F55}, so it REPLACES
       the old {app} - including the old, broken uninstaller - instead of
       leaving it alive beside the new one.
    4. WHEN THE MACHINE DOES NOT MATCH WHAT WE EXPECT, STOP AND SAY SO. No
       guessing, no "probably fine". Exit 4 and a report the user can act on.

    IT REUSES THE SHIPPED UNINSTALL ENGINE; IT DOES NOT REIMPLEMENT IT
    -----------------------------------------------------------------
    installer\lazarus\aefos-laz-uninstall.ps1 already knows how to undo an
    in-place install correctly, and every rule in it was bought with damage:
    the index-safe list edit (Set-AefosIndexedList), the DLL provenance rules,
    the "a value you changed after the install is yours" rule, the refusal to
    rebuild, the refusal to trust lazarus.old.exe. Duplicating any of that here
    would give us two copies to keep in step - the exact failure mode the
    round-trip gate's SRC-TWIN-HELPER check exists to catch. So this engine is a
    DETECTOR, a CRASH JOURNAL and a REPORTER wrapped around that engine:

        detect -> safeguard -> invoke the shipped engine -> verify by evidence
               -> report -> clean up the safeguard

    The one thing it adds to the undo itself is resumability (below); the undo
    steps themselves are never re-implemented.

    RESUMABILITY (the power-cut requirement)
    ----------------------------------------
    The dangerous window in the shipped engine is between
    "copy the stock backup over lazarus.exe" and "delete the backup"
    (aefos-laz-uninstall.ps1:283-284): after the delete, a re-run finds no
    backup, decides it restored nothing ($restored stays $false, :250/:495),
    skips the DLL step and exits 1 with a "could not restore" notice - even
    though the exe on disk is already stock. A half-migrated machine would then
    look unrecoverable to its own recovery path.

    So before anything is undone this engine copies the stock backup into its
    OWN folder and writes a journal. A resumed run reconciles by EVIDENCE
    (sha-256 of what is on disk), never by trusting the journal's phase, and
    when the shipped engine's happy path needs a backup file that a previous
    attempt already consumed, the safeguarded copy is put back so the engine
    runs its NORMAL path end to end. Nothing about the undo is re-implemented,
    and a machine is never left in a state where neither IDE works.

    WHAT IT WRITES, AND WHERE
    -------------------------
      %LOCALAPPDATA%\Aefos\lazarus\migration-state.json   the crash journal
      %LOCALAPPDATA%\Aefos\lazarus\migration-report.txt   the user-facing report
      %LOCALAPPDATA%\Aefos\lazarus\migration-engine.log   the shipped engine's transcript
      %LOCALAPPDATA%\Aefos\lazarus\migration\             the safeguarded stock exe
                                                          (deleted once verified)
    Inside the user's own Lazarus folder and pcp, this engine writes exactly
    three things itself - everything else goes through the shipped uninstall
    engine, and they are listed here rather than hidden behind a "we touch
    nothing" claim that would not be true:
      * a lazarus-aefos-backup-<stamp>.exe, TRANSIENTLY, when a previous attempt
        consumed the real one or when the binary is already Aefos-free (see the
        safeguard section). The shipped engine consumes and deletes it in the
        same run; the journal records it if a crash leaves it behind.
      * the deletion of aefos-laz-buildide.log and AEFOS-UNINSTALL-README.txt -
        files with our own names, created by the in-place install/uninstall -
        and only once the stock binary is verified back.
      * nothing else. Not one entry that is not named Aefos.Lazarus.IDE.
    %APPDATA%\Aefos (the brain shared with the RAD Studio edition) is never
    touched, read or written.

.PARAMETER LazarusDir
    The user's Lazarus installation. Detected like the shipped engines do when
    omitted.

.PARAMETER Pcp
    The user's Lazarus primary config path. Defaults to %LOCALAPPDATA%\lazarus.

.PARAMETER AefosHome
    OUR isolated root (milestone 2). Journal, report, log and safeguard live
    here. Default %LOCALAPPDATA%\Aefos\lazarus.

.PARAMETER UninstallEngine
    Path to the shipped aefos-laz-uninstall.ps1. Defaults to the copy beside
    this script ({app} layout) and then to the repo layout.

.PARAMETER DetectOnly
    Report what an in-place install left on this machine and exit. Writes
    NOTHING - not the journal, not the report. This is what a wizard page or a
    support session should call.

.OUTPUTS
    Exit codes, meant to be acted on by the installer:
      0 - nothing to migrate (clean machine), or migrated and verified.
      3 - THE USER MUST READ THE REPORT BEFORE HE OPENS LAZARUS. The IDE works
          and the installation may continue, but one thing is left that only he
          can decide or finish. Two situations reach it, and the report says
          which:
            * PARTIAL: something reversible could not be reverted (typically:
              the stock lazarus.exe backup is gone).
            * MIGRATED WITH A WARNING: the undo itself is complete and
              byte-exact, but the binary we handed back does not agree with his
              Lazarus tree or with his IDE configuration, so his next start of
              Lazarus will raise the Upgrade/Downgrade prompt that DELETES
              <pcp>\bin and <pcp>\units (ide\main.pp:1373-1378). Restoring
              "exactly what was there" can return a user to a state that was
              ALREADY broken before we arrived; when it does, we say so instead
              of letting him find out from a dialog nobody warned him about.
          Both share one exit code on purpose: it is the installer's existing
          "continue, but show him the report" channel (Aefos-Lazarus.iss:956).
      4 - REFUSED: the machine does not match what we can reason about. Nothing
          was changed. Do not continue unattended.
      1 - hard error.
#>

[CmdletBinding()]
param(
    [string]$LazarusDir,
    [string]$Pcp,
    [string]$AefosHome,
    [string]$UninstallEngine,
    [switch]$DetectOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PkgName = 'Aefos.Lazarus.IDE'

# Exit codes, named so the code below reads like the contract above.
$EXIT_OK       = 0
$EXIT_ERROR    = 1
$EXIT_PARTIAL  = 3
$EXIT_REFUSED  = 4
# The SAME code as PARTIAL, and deliberately so: 3 is the one channel the shipped
# installer already has for "the machine is usable, the install may continue, but
# put the report in front of him" (Aefos-Lazarus.iss:956-971). A migration that
# completes byte-exact and then leaves him to discover a Downgrade prompt on his
# own is the defect this name exists to close; inventing a fourth exit code would
# have needed an installer change that this slice must not make.
$EXIT_ATTENTION = $EXIT_PARTIAL

function Write-Step($m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host $m -ForegroundColor Green }
function Write-WarnMsg($m) { Write-Host $m -ForegroundColor Yellow }
function Write-BadMsg($m)  { Write-Host $m -ForegroundColor Red }

# ---------------------------------------------------------------------------
# SHA-256 through .NET and not Get-FileHash - the same reason spelled out in
# both shipped engines: a PSModulePath inherited from a PowerShell 7 parent
# makes Windows PowerShell load PS7's Utility module, which has no Get-FileHash,
# and a migration must not fall over on a hash comparison.
# ---------------------------------------------------------------------------
function Get-AefosFileHash {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

# Does this binary carry our package name? Same probe the install engine uses to
# PROVE the static link landed (aefos-laz-install.ps1:922) and the uninstall
# engine uses to judge lazarus.old.exe (:267). It is the single strongest piece
# of evidence there is: nothing but an Aefos IDE link puts that string in there.
function Test-ExeCarriesAefos {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern $PkgName -SimpleMatch -Quiet -ErrorAction SilentlyContinue)
}

# Can we replace this file? A RUNNING lazarus.exe is locked, and the shipped
# engine's Copy-Item over it would throw halfway through the undo. Neither
# engine guards this today; the migration does, BEFORE anything is changed.
function Test-FileReplaceable {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Write', 'None')
        $fs.Dispose()
        return $true
    } catch { return $false }
}

# ===========================================================================
# THE VERSION TRIANGLE: the restored binary, his tree, and his IDE config.
#
# WHY THIS EXISTS (a real machine, 2026-07-27)
# -------------------------------------------
# A migration ran, restored the stock lazarus.exe byte-exact and reported
# MIGRATED. The user opened Lazarus and got:
#
#     Downgrade configuration
#     Welcome to Lazarus 2.2.6. There is already a configuration from version
#     4.8 in C:\Users\...\AppData\Local\lazarus. The configuration will be
#     downgraded/converted.
#
# because the backup the in-place install took in 2026-07 captured a lazarus.exe
# from 2.2.6 dated 2023, while his TREE is 4.8. His machine was already
# inconsistent before Aefos ever touched it; the in-place install had
# accidentally papered over it by relinking the IDE from the 4.8 tree, and
# giving the binary back honestly brought the old mismatch back into view.
#
# Confirming that prompt runs DeleteDirectory on <pcp>\bin and <pcp>\units
# (ide\main.pp:1373-1378) - on HIS config, not ours. The migration held both
# numbers in its hands and said nothing. This is that gap closed: we do not
# "fix" an inherited mismatch (there is nothing here to fix - the backup is what
# it is), we DETECT it and we say it, loudly, before he opens the IDE.
#
# WHAT IS COMPARED, AND AGAINST WHAT ide\main.pp ACTUALLY DOES
# ------------------------------------------------------------
#   LoadGlobalOptions compares EnvironmentOptions/Version@Lazarus from HIS pcp
#   against LazarusVersionStr COMPILED INTO the running exe. So the prompt is
#   predicted by (config stamp) vs (version inside the binary) - the tree is not
#   part of the IDE's comparison at all, it is what EXPLAINS the mismatch and
#   what the repair rebuilds from.
#
# WHY THESE READERS ARE LOCAL AND NOT THE ONES IN THE ISOLATED ENGINES
# ---------------------------------------------------------------------
#   * Get-AefosLazarusTreeInfo (scripts\aefos-laz-seed-pcp.ps1:257-305) reads the
#     same ide\packages\ideconfig\version.inc and is the source of truth for the
#     rule "strip the quotes, never guess". It cannot be reused HERE: this engine
#     runs from {tmp} with only aefos-laz-uninstall.ps1 beside it
#     (Aefos-Lazarus.iss:167-168,895-896) - seed-pcp is installed to {app}, which
#     at migration time does not exist yet - and it carries a param() block, so
#     dot-sourcing it would blank THIS script's own -LazarusDir/-Pcp parameters
#     (the trap documented in aefos-laz-ide-drift.ps1:106-113). The gate closes
#     the duplication with a twin check: run-migration-gate.ps1 asserts the two
#     readers return the same version for the same tree.
#   * Get-AefosIdeConfigVersionStamp (scripts\aefos-laz-ide-drift.ps1:196-209) is
#     the same XPath read, on OUR isolated pcp; here the subject is HIS pcp.
#   * Get-AefosIdeExeVersion (aefos-laz-ide-drift.ps1:290-320) does NOT read a
#     version out of a binary: it INFERS ours from the install stamp's timestamp.
#     A machine being migrated FROM the in-place model has no such stamp, and the
#     binary in question is the user's own - so the version has to come from the
#     file itself, which is what Get-AefosExeVersionText does.
# ===========================================================================

# A version string reduced to comparable integer components, trailing zeros
# dropped: "'4.8'" -> 4,8   "4.8.0.0" -> 4,8   "2.2.6.0" -> 2,2,6.
# The quote stripping mirrors Get-AefosLazarusTreeInfo (seed-pcp:277), which
# reads the same version.inc.
function Get-AefosVersionParts {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $match = [Regex]::Match($Text.Trim().Trim("'").Trim(), '\d+(\.\d+)*')
    if (-not $match.Success) { return @() }
    $parts = @()
    foreach ($piece in $match.Value.Split('.')) { $parts += [int]$piece }
    while (($parts.Count -gt 1) -and ($parts[$parts.Count - 1] -eq 0)) {
        $parts = @($parts[0..($parts.Count - 2)])
    }
    return $parts
}

function Get-AefosVersionText {
    param([string]$Text)
    $parts = @(Get-AefosVersionParts -Text $Text)
    if ($parts.Count -eq 0) { return '' }
    return ($parts -join '.')
}

# Do two versions genuinely disagree? Compared over the components BOTH sides
# actually carry, never padded:
#   "2.2.6" vs "4.8" -> yes (2 <> 4).
#   "2.2"   vs "2.2.6" -> NO. A PE version resource whose Revision field upstream
#     left at 0 would otherwise be called a mismatch on a perfectly consistent
#     machine, and a warning that cries wolf is a warning the user learns to
#     click past. This engine would rather miss a patch-level difference than
#     invent one.
# An unknown side is never a disagreement: silence beats a guess.
function Test-AefosVersionsDiffer {
    param([string]$Left, [string]$Right)
    $leftParts  = @(Get-AefosVersionParts -Text $Left)
    $rightParts = @(Get-AefosVersionParts -Text $Right)
    if (($leftParts.Count -eq 0) -or ($rightParts.Count -eq 0)) { return $false }
    $common = [Math]::Min($leftParts.Count, $rightParts.Count)
    for ($i = 0; $i -lt $common; $i++) {
        if ($leftParts[$i] -ne $rightParts[$i]) { return $true }
    }
    return $false
}

# The version INSIDE a lazarus.exe, from its PE version resource. Lazarus builds
# it from ide\lazarus.lpi <VersionInfo> (UseVersionInfo=True), which upstream
# keeps in step with version.inc, so a 4.8 build stamps 4.8.0.0 and a 2.2.6 build
# stamps 2.2.6.0.
#
# The FIXED info (FileMajorPart..FilePrivatePart) is read first and the
# FileVersion STRING only as a fallback: the string comes from the resource's
# StringFileInfo block, which a build can omit entirely, while the fixed block is
# present whenever there is a version resource at all. A file with no version
# resource (a stub, a script renamed to .exe) answers '' - unknown, never a
# warning.
function Get-AefosExeVersionText {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $info = $null
    try { $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path) } catch { return '' }
    if ($null -eq $info) { return '' }
    $fixed = @($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
    if (@($fixed | Where-Object { $_ -ne 0 }).Count -gt 0) { return (Get-AefosVersionText -Text ($fixed -join '.')) }
    return (Get-AefosVersionText -Text ([string]$info.FileVersion))
}

# His tree's version today. Same file, same rule as Get-AefosLazarusTreeInfo
# (seed-pcp:270-280) - lazconf.pp:54 compiles this very include into the IDE, so
# a binary built from this tree carries this number. Absent = unknown, not a
# guess and not a warning.
function Get-AefosTreeVersionText {
    param([string]$LazDir)
    if ([string]::IsNullOrWhiteSpace($LazDir)) { return '' }
    $inc = Join-Path $LazDir 'ide\packages\ideconfig\version.inc'
    if (-not (Test-Path -LiteralPath $inc)) { return '' }
    try { return (Get-AefosVersionText -Text (Get-Content -LiteralPath $inc -Raw)) } catch { return '' }
}

# The stamp in HIS config - EnvironmentOptions/Version@Lazarus, written by
# environmentopts.pp:1211 on every save. This is the LEFT side of the comparison
# ide\main.pp makes at startup.
function Get-AefosConfigVersionText {
    param([string]$PcpDir)
    if ([string]::IsNullOrWhiteSpace($PcpDir)) { return '' }
    $path = Join-Path $PcpDir 'environmentoptions.xml'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($path)
        $node = $doc.SelectSingleNode('/CONFIG/EnvironmentOptions/Version')
        if ($null -eq $node) { return '' }
        return (Get-AefosVersionText -Text ($node.GetAttribute('Lazarus')))
    } catch { return '' }
}

# $null when there is nothing to warn about (the three agree, or the binary
# carries no version we can read). Otherwise the three numbers and which
# comparison failed.
function Get-AefosRestoredVersionMismatch {
    param([string]$LazDir, [string]$PcpDir, [string]$ExePath)
    $exeVersion = Get-AefosExeVersionText -Path $ExePath
    if ([string]::IsNullOrWhiteSpace($exeVersion)) { return $null }
    $treeVersion   = Get-AefosTreeVersionText -LazDir $LazDir
    $configVersion = Get-AefosConfigVersionText -PcpDir $PcpDir
    $vsTree   = Test-AefosVersionsDiffer -Left $exeVersion -Right $treeVersion
    $vsConfig = Test-AefosVersionsDiffer -Left $exeVersion -Right $configVersion
    if ((-not $vsTree) -and (-not $vsConfig)) { return $null }
    $exeDate = ''
    try { $exeDate = (Get-Item -LiteralPath $ExePath).LastWriteTime.ToString('yyyy-MM-dd') } catch { }
    return [pscustomobject]@{
        ExeVersion        = $exeVersion
        TreeVersion       = $treeVersion
        ConfigVersion     = $configVersion
        DiffersFromTree   = $vsTree
        DiffersFromConfig = $vsConfig
        ExeDate           = $exeDate
    }
}

# The warning itself, as lines. ENGLISH, like every other word Aefos says to a
# user (CLAUDE.md). It shipped bilingual - Portuguese first, English summary at the
# bottom - on the argument that the few people still on the in-place model are
# pt-BR; that argument does not survive the rule, and a product that speaks one
# language in its installer and another in its migration report is worse than one
# that simply speaks English everywhere. ASCII only, because this text is echoed to
# a console and into migration-setup.log.
#
# It does NOT offer to run the rebuild. Writing into the user's IDE is precisely
# what this version of Aefos stopped doing, and a rebuild consumes HIS package
# list - the operation that once handed a partner back an IDE without any of his
# components. We print the exact command instead, so the decision and the moment
# are his.
function Get-AefosVersionMismatchLines {
    param($Mismatch, [string]$LazDir, [string]$PcpDir, [string]$BackupName)
    # A machine whose pcp we could not read still gets the warning (the tree
    # comparison alone can raise it), so every path built from it is guarded:
    # Join-Path on an empty string throws, and a warning that dies while being
    # written is worse than no warning.
    $pcpText = '<your Lazarus configuration folder>'
    $configFileText = 'your Lazarus configuration was not found'
    if (-not [string]::IsNullOrWhiteSpace($PcpDir)) {
        $pcpText = $PcpDir
        $configFileText = Join-Path $PcpDir 'environmentoptions.xml'
    }
    $lines = @()
    $lines += 'WARNING - THE NEXT TIME YOU OPEN YOUR LAZARUS IT WILL ASK TO CONVERT THE CONFIGURATION'
    $lines += ''
    $lines += '  The migration finished: your lazarus.exe was handed back byte for byte, exactly'
    $lines += '  as it was before Aefos. But the version INSIDE that backup does not match the'
    $lines += '  rest of your installation:'
    $lines += ''
    $lines += ('    lazarus.exe restored  : {0,-9}{1}' -f `
        $(if ($Mismatch.ExeVersion) { $Mismatch.ExeVersion } else { 'unknown' }),
        $(if ($Mismatch.ExeDate) { '(file dated ' + $Mismatch.ExeDate + ')' } else { '' }))
    $lines += ('    your Lazarus tree     : {0,-9}({1})' -f `
        $(if ($Mismatch.TreeVersion) { $Mismatch.TreeVersion } else { 'not read' }),
        (Join-Path $LazDir 'ide\packages\ideconfig\version.inc'))
    $lines += ('    your configuration    : {0,-9}({1})' -f `
        $(if ($Mismatch.ConfigVersion) { $Mismatch.ConfigVersion } else { 'not read' }),
        $configFileText)
    $lines += ''
    $lines += '  WHY THIS HAPPENED: the backup of your original lazarus.exe was taken by the OLD'
    $lines += '  Aefos installation, and it PREDATES the update of your Lazarus.'
    if ($BackupName) { $lines += ('  The backup used was ' + $BackupName + '.') }
    $lines += '  While Aefos was installed inside the IDE it rebuilt lazarus.exe from your'
    $lines += '  CURRENT tree, and that unintentionally hid the mismatch. We handed back exactly'
    $lines += '  what was stored - that is what we promised - and with it the mismatch that'
    $lines += '  already existed before Aefos came back into view. The migration did NOT downgrade'
    $lines += '  your Lazarus, and we did not invent a version for the backup.'
    $lines += ''
    $lines += '  WHAT WILL HAPPEN: when you open Lazarus you will see the "Downgrade'
    $lines += '  configuration" window / "Welcome to Lazarus ..., there is already a configuration'
    $lines += '  from version ... the configuration will be downgraded".'
    $lines += ''
    $lines += '  DO NOT CLICK DOWNGRADE / CONVERT. Accepting downgrades your real configuration'
    $lines += ('  and DELETES the bin and units folders inside ' + $pcpText)
    $lines += '  (ide\main.pp:1373-1378). Cancelling only closes the IDE. Neither answer fixes'
    $lines += '  the problem.'
    $lines += ''
    $lines += '  WHAT FIXES IT (once, and this is what worked): rebuild YOUR OWN IDE from YOUR'
    $lines += '  OWN tree, with Lazarus closed:'
    $lines += ''
    $lines += ('      "{0}" --pcp="{1}" --build-ide=' -f (Join-Path $LazDir 'lazbuild.exe'), $pcpText)
    $lines += ''
    $lines += ('  That regenerates lazarus.exe from your {0} tree, and the binary, the tree and' -f `
        $(if ($Mismatch.TreeVersion) { $Mismatch.TreeVersion } else { 'current' }))
    $lines += '  the configuration agree again. The rebuild uses YOUR package list; we do not run'
    $lines += '  it for you, because writing inside your IDE is exactly what this version of Aefos'
    $lines += '  stopped doing. Aefos AI does not depend on it: it runs in an IDE of its own, in'
    $lines += '  another folder.'
    return $lines
}

# ---------------------------------------------------------------------------
# Resolve the user's Lazarus directory. Mirrors the detection in both shipped
# engines (aefos-laz-uninstall.ps1:145-176) so all three agree on which IDE they
# are talking about; kept read-only and non-throwing - "no Lazarus here" is a
# legitimate answer for a machine that never had the in-place edition.
# ---------------------------------------------------------------------------
function Resolve-AefosLazarusDir {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if (Test-Path -LiteralPath (Join-Path $Override 'lazbuild.exe')) { return $Override }
        return $null
    }
    $cmd = Get-Command 'lazbuild.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return (Split-Path -Parent $cmd.Source) }
    $candidates = @(
        'C:\lazarus', 'C:\Lazarus',
        (Join-Path $env:SystemDrive 'lazarus'),
        (Join-Path ${env:ProgramFiles} 'Lazarus'),
        (Join-Path ${env:ProgramFiles(x86)} 'Lazarus')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($dir in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $dir 'lazbuild.exe')) { return $dir }
    }
    foreach ($key in @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\lazarus',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\lazarus',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\lazarus')) {
        try {
            $loc = (Get-ItemProperty -Path $key -Name 'InstallLocation' -ErrorAction Stop).InstallLocation
            if ($loc -and (Test-Path -LiteralPath (Join-Path $loc 'lazbuild.exe'))) { return $loc }
        } catch { }
    }
    return $null
}

# Same plausibility test the install engine gates on (aefos-laz-install.ps1:248-256):
# both markers are written on the IDE's first run, so a folder with neither has
# never been a Lazarus config. An elevated run whose %LOCALAPPDATA% resolved into
# another profile lands here, and guessing from there is how the wrong config
# gets edited.
function Test-AefosPcpPlausible {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    foreach ($marker in @('environmentoptions.xml', 'packagefiles.xml')) {
        if (Test-Path -LiteralPath (Join-Path $Path $marker)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# READ-ONLY readers for the two lists Lazarus reads BY INDEX. They never write;
# every write to these files goes through the shipped engine's
# Set-AefosIndexedList, which is the only copy of that logic we are allowed to
# have.
# ---------------------------------------------------------------------------
function Get-AefosIndexedItems {
    param([System.Xml.XmlNode]$ListNode)
    if (-not $ListNode) { return @() }
    # $_.LocalName and never $_.Name: PowerShell's XML adapter shadows
    # XmlNode.Name with the <Name> CHILD element. That shadowing is what once
    # wrote Count="0" into a real user's packagefiles.xml.
    return @($ListNode.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
}

function Get-AefosUserLinkNames {
    param([string]$Path)
    $names = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $names }
    try { [xml]$doc = Get-Content -LiteralPath $Path -Raw } catch { return $names }
    $list = $doc.SelectSingleNode('//UserPkgLinks')
    foreach ($item in (Get-AefosIndexedItems -ListNode $list)) {
        $n = $item.SelectSingleNode('Name')
        if ($n) { $names += $n.GetAttribute('Value') }
    }
    return $names
}

function Get-AefosInstallListNames {
    param([string]$Path)
    $names = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $names }
    try { [xml]$doc = Get-Content -LiteralPath $Path -Raw } catch { return $names }
    $list = $doc.SelectSingleNode('//StaticAutoInstallPackages')
    foreach ($item in (Get-AefosIndexedItems -ListNode $list)) { $names += $item.GetAttribute('Value') }
    return $names
}

# Is an indexed list still readable by Lazarus? A wrong Count or a numbering
# hole silently discards the USER'S packages (packagelinks.pas:614-619 reads
# Count and then Item1..ItemCount). We check it BEFORE and AFTER: before, because
# a list already broken by the 0.24.7 uninstaller must be reported and not
# blamed on this run; after, because our own edit must leave it consistent.
function Get-AefosListProblem {
    param([string]$Path, [string]$XPath, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try { [xml]$doc = Get-Content -LiteralPath $Path -Raw } catch { return "$Label`: unreadable XML" }
    $list = $doc.SelectSingleNode($XPath)
    if (-not $list) { return '' }
    $items = @(Get-AefosIndexedItems -ListNode $list)
    $count = $list.GetAttribute('Count')
    if ([string]::IsNullOrWhiteSpace($count)) {
        return "$Label`: no Count attribute (Lazarus reads it as 0 and loads NOTHING)"
    }
    if ([int]$count -ne $items.Count) {
        return ("{0}: Count={1} but {2} <ItemN> present" -f $Label, $count, $items.Count)
    }
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].LocalName -ne ('Item' + ($i + 1))) {
            return ("{0}: numbering hole at position {1} (<{2}>)" -f $Label, ($i + 1), $items[$i].LocalName)
        }
    }
    return ''
}

# ---------------------------------------------------------------------------
# THE DETECTOR.
#
# Every artifact an in-place install could have left, classified by how much it
# actually PROVES. The classification is not decoration - it decides behaviour:
#
#   Strong     - only an Aefos in-place install creates this exact artifact.
#                One strong item is enough to run the revert.
#   Weak       - we do create it, but the name is shared with files a user
#                legitimately owns (sqlite3.dll beside lazarus.exe is what every
#                Lazarus SQLdb tutorial tells people to do). NEVER enough on its
#                own, and never removed by this engine - only the install state
#                file can say whose a given DLL is, which is why the shipped
#                uninstaller keys its DLL handling on that file.
#   Ambiguous  - proves HISTORY, not current state, and/or is generated/shared
#                output. Reported, never acted on.
#
# The list was built by reading the shipped installer, not from memory; each
# item carries the file:line that creates it.
# ---------------------------------------------------------------------------
function Get-AefosInPlaceEvidence {
    param([string]$LazDir, [string]$PcpDir)

    function Add-Ev($id, $strength, $detail, $origin) {
        $script:__ev += [pscustomobject]@{ Id = $id; Strength = $strength; Detail = $detail; Origin = $origin }
    }
    $script:__ev = @()

    $lazExe = Join-Path $LazDir 'lazarus.exe'

    # -- STRONG -------------------------------------------------------------
    if (Test-ExeCarriesAefos -Path $lazExe) {
        Add-Ev 'EXE-LINKED' 'Strong' "lazarus.exe carries '$PkgName' (Aefos is compiled INTO the IDE binary)" 'aefos-laz-install.ps1:780 (--build-ide), proven at :922'
    }
    $statePath = Join-Path $LazDir 'aefos-laz-install-state.json'
    if (Test-Path -LiteralPath $statePath) {
        Add-Ev 'STATE-FILE' 'Strong' 'aefos-laz-install-state.json (what was there before us)' 'aefos-laz-install.ps1:320,346'
    }
    $backups = @(Get-ChildItem -Path $LazDir -Filter 'lazarus-aefos-backup-*.exe' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($backups.Count -gt 0) {
        Add-Ev 'EXE-BACKUP' 'Strong' ("stock lazarus.exe backup: " + (($backups | ForEach-Object { $_.Name }) -join ', ')) 'aefos-laz-install.ps1:484-485'
    }
    if (Test-Path -LiteralPath (Join-Path $LazDir 'aefos-laz-buildide.log')) {
        Add-Ev 'BUILD-LOG' 'Strong' 'aefos-laz-buildide.log (our lazbuild transcript, in HIS folder)' 'aefos-laz-install.ps1:733'
    }
    if (Test-Path -LiteralPath (Join-Path $LazDir 'AEFOS-UNINSTALL-README.txt')) {
        Add-Ev 'UNINSTALL-NOTICE' 'Strong' 'AEFOS-UNINSTALL-README.txt - a previous uninstall ran and could NOT restore' 'aefos-laz-uninstall.ps1:663'
    }
    $displaced = @(Get-ChildItem -Path $LazDir -Filter '*.aefos-preexisting-*.bak' -ErrorAction SilentlyContinue)
    if ($displaced.Count -gt 0) {
        Add-Ev 'DISPLACED-DLL' 'Strong' ("the user's own DLL(s) moved aside by our install: " + (($displaced | ForEach-Object { $_.Name }) -join ', ')) 'aefos-laz-install.ps1:429-430'
    }
    if ($PcpDir) {
        $links = Join-Path $PcpDir 'packagefiles.xml'
        if (@(Get-AefosUserLinkNames -Path $links) -contains $PkgName) {
            Add-Ev 'PCP-LINK' 'Strong' 'an Aefos package link in packagefiles.xml (UserPkgLinks)' 'aefos-laz-install.ps1:551'
        }
        $misc = Join-Path $PcpDir 'miscellaneousoptions.xml'
        if (@(Get-AefosInstallListNames -Path $misc) -contains $PkgName) {
            Add-Ev 'PCP-INSTALLLIST' 'Strong' 'Aefos in StaticAutoInstallPackages - every future IDE rebuild of his would try to link us' 'aefos-laz-install.ps1:780 (lazbuild --add-package)'
        }
    }

    # -- WEAK ---------------------------------------------------------------
    $dllsPresent = @()
    foreach ($name in @('WebView2Loader.dll', 'sqlite3.dll', 'libvterm.dll')) {
        if (Test-Path -LiteralPath (Join-Path $LazDir $name)) { $dllsPresent += $name }
    }
    if ($dllsPresent.Count -gt 0) {
        Add-Ev 'RUNTIME-DLLS' 'Weak' ("beside lazarus.exe: " + ($dllsPresent -join ', ') + " - we ship these names, and so do other products and the user himself") 'aefos-laz-install.ps1:756,772,899'
    }

    # -- AMBIGUOUS ----------------------------------------------------------
    $oldExe = Join-Path $LazDir 'lazarus.old.exe'
    if ((Test-Path -LiteralPath $oldExe) -and (Test-ExeCarriesAefos -Path $oldExe)) {
        Add-Ev 'OLD-EXE' 'Ambiguous' "lazarus.old.exe carries '$PkgName' - it is lazbuild's OWN rolling backup, and it is the user's rollback slot, never ours to write or delete" 'aefos-laz-uninstall.ps1:256-262'
    }
    if ($PcpDir) {
        $inc = Join-Path $PcpDir 'staticpackages.inc'
        if ((Test-Path -LiteralPath $inc) -and ((Get-Content -LiteralPath $inc -Raw -ErrorAction SilentlyContinue) -match [Regex]::Escape($PkgName))) {
            Add-Ev 'STATIC-INC' 'Ambiguous' 'staticpackages.inc still names Aefos - GENERATED output, regenerated from the install list on his next rebuild, and it lists EVERYONE''s packages' 'aefos-laz-uninstall.ps1:362-369'
        }
        foreach ($cache in @('lib', 'units')) {
            if (Test-Path -LiteralPath (Join-Path $PcpDir $cache)) {
                Add-Ev ('PCP-CACHE-' + $cache.ToUpper()) 'Ambiguous' "<pcp>\$cache exists - lazbuild build cache. Our install fed it, but so does every IDE rebuild he runs himself. Regenerable; not ours to delete." 'lazbuild output (buildmanager.pas fallback output root)'
            }
        }
    }

    $found = @($script:__ev)
    Remove-Variable -Name '__ev' -Scope Script -ErrorAction SilentlyContinue
    return $found
}

# ---------------------------------------------------------------------------
# THE JOURNAL. Written before anything is undone and updated after every phase,
# so an interrupted migration is RESUMABLE and never a half-state.
#
# It records EVIDENCE (sha-256 of the binary before we start, sha-256 and name
# of the stock backup), not just a phase name: a resumed run reconciles against
# what is actually on disk, because a phase name written before a power cut
# proves nothing about whether the write behind it landed.
# ---------------------------------------------------------------------------
function Read-AefosMigrationJournal {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
    $journal = @{}
    foreach ($prop in $raw.PSObject.Properties) { $journal[$prop.Name] = $prop.Value }
    return $journal
}

function Write-AefosMigrationJournal {
    param([string]$Path, [hashtable]$Journal)
    try {
        $Journal['lastUpdateUtc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        ($Journal | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        Write-WarnMsg "Could not update the migration journal '$Path': $($_.Exception.Message)"
    }
}

function Get-AefosJournalValue {
    param([hashtable]$Journal, [string]$Key)
    if (-not $Journal) { return $null }
    if (-not $Journal.ContainsKey($Key)) { return $null }
    return $Journal[$Key]
}

# ===========================================================================
# 1. RESOLVE + REFUSE TO GUESS
# ===========================================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if ([string]::IsNullOrWhiteSpace($AefosHome)) {
    # %LOCALAPPDATA%, not %APPDATA%: this folder holds a per-machine build
    # artifact, and %APPDATA% roams. The BRAIN (memory.md, config.json, aefos.db,
    # models.json) stays whole in %APPDATA%\Aefos and is shared with the RAD
    # Studio edition - this engine never touches it.
    $AefosHome = Join-Path $env:LOCALAPPDATA 'Aefos\lazarus'
}
$JournalPath  = Join-Path $AefosHome 'migration-state.json'
$ReportPath   = Join-Path $AefosHome 'migration-report.txt'
$EngineLog    = Join-Path $AefosHome 'migration-engine.log'
$SafeguardDir = Join-Path $AefosHome 'migration'

if ([string]::IsNullOrWhiteSpace($UninstallEngine)) {
    foreach ($candidate in @(
        (Join-Path $ScriptDir 'aefos-laz-uninstall.ps1'),                                   # {app} layout
        (Join-Path (Split-Path -Parent $ScriptDir) 'installer\lazarus\aefos-laz-uninstall.ps1'))) {  # repo layout
        if (Test-Path -LiteralPath $candidate) { $UninstallEngine = $candidate; break }
    }
}

Write-Host '=================================================================='
Write-Host ' Aefos AI - Lazarus edition: MIGRATION from the in-place install'
Write-Host '=================================================================='

$LazDir = Resolve-AefosLazarusDir -Override $LazarusDir
if (-not $LazDir) {
    Write-Ok 'No Lazarus installation found on this machine - nothing to migrate.'
    exit $EXIT_OK
}
$LazExe = Join-Path $LazDir 'lazarus.exe'

if ([string]::IsNullOrWhiteSpace($Pcp)) {
    $defaultPcp = Join-Path $env:LOCALAPPDATA 'lazarus'
    if (Test-Path -LiteralPath $defaultPcp) { $Pcp = $defaultPcp }
}
$PcpUsable = Test-AefosPcpPlausible -Path $Pcp

Write-Host "lazarus dir : $LazDir"
Write-Host "pcp         : $(if ($Pcp) { $Pcp } else { '<none found>' })"
Write-Host "aefos home  : $AefosHome"
Write-Host "engine      : $(if ($UninstallEngine) { $UninstallEngine } else { '<NOT FOUND>' })"

# ===========================================================================
# 2. DETECT
# ===========================================================================
Write-Step '-- What an in-place install left on this machine --'
$Evidence = @(Get-AefosInPlaceEvidence -LazDir $LazDir -PcpDir $(if ($PcpUsable) { $Pcp } else { $null }))
$Strong   = @($Evidence | Where-Object { $_.Strength -eq 'Strong' })
$Weak     = @($Evidence | Where-Object { $_.Strength -eq 'Weak' })
$Ambig    = @($Evidence | Where-Object { $_.Strength -eq 'Ambiguous' })

if ($Evidence.Count -eq 0) {
    Write-Ok '  none.'
} else {
    foreach ($ev in $Evidence) {
        $color = switch ($ev.Strength) { 'Strong' { 'Yellow' } 'Weak' { 'DarkYellow' } default { 'DarkGray' } }
        Write-Host ("  [{0,-9}] {1,-17} {2}" -f $ev.Strength, $ev.Id, $ev.Detail) -ForegroundColor $color
    }
}

# The pcp being unreadable is not fatal for the exe restore, but it DOES mean
# the package link and the install-list entry cannot be cleaned - and the
# install-list entry is the time bomb (every future IDE rebuild of his aborts on
# a package whose .lpk we are about to delete). Say it, loudly, and keep it in
# the report.
$PcpWarning = ''
if (-not $PcpUsable) {
    $PcpWarning = "The Lazarus configuration folder '$Pcp' holds no Lazarus config files, so the Aefos package link and the Aefos entry in your IDE install list could NOT be cleaned. If 'Aefos.Lazarus.IDE' is still listed in Package > Install/Uninstall Packages, remove it there."
    Write-WarnMsg $PcpWarning
}

# Damage that predates this run: a list Lazarus can no longer read by index.
# Reported before we touch anything so it is never mistaken for our doing.
$PreExistingListDamage = @()
if ($PcpUsable) {
    foreach ($probe in @(
        @{ File = 'packagefiles.xml';         XPath = '//UserPkgLinks';              Label = 'UserPkgLinks' },
        @{ File = 'miscellaneousoptions.xml'; XPath = '//StaticAutoInstallPackages'; Label = 'StaticAutoInstallPackages' })) {
        $problem = Get-AefosListProblem -Path (Join-Path $Pcp $probe.File) -XPath $probe.XPath -Label $probe.Label
        if ($problem) { $PreExistingListDamage += $problem }
    }
    foreach ($d in $PreExistingListDamage) {
        Write-WarnMsg "  PRE-EXISTING DAMAGE (not caused by this run): $d"
    }
}

$Journal = Read-AefosMigrationJournal -Path $JournalPath
$Resuming = $false
if ($Journal -and (Get-AefosJournalValue -Journal $Journal -Key 'phase') -and
    ((Get-AefosJournalValue -Journal $Journal -Key 'phase') -ne 'done')) {
    $Resuming = $true
    Write-WarnMsg ("  RESUMING an interrupted migration (journal phase '{0}', attempt {1})." -f `
        (Get-AefosJournalValue -Journal $Journal -Key 'phase'), (Get-AefosJournalValue -Journal $Journal -Key 'attempts'))
}

if ($DetectOnly) {
    Write-Step '-- -DetectOnly: nothing was written --'
    if ($Strong.Count -gt 0) {
        Write-WarnMsg ("An IN-PLACE Aefos install IS present ({0} strong indicator(s))." -f $Strong.Count)
        exit $EXIT_PARTIAL   # "there is work to do" - never confused with success
    }
    Write-Ok 'No in-place Aefos install detected.'
    exit $EXIT_OK
}

if ($Strong.Count -eq 0 -and -not $Resuming) {
    if ($Weak.Count -gt 0 -or $Ambig.Count -gt 0) {
        Write-Step '-- Nothing to migrate --'
        Write-Ok 'No in-place Aefos install. The items above are weak/ambiguous evidence only'
        Write-Ok '(shared file names, or generated output), so nothing was changed - guessing'
        Write-Ok 'from them is exactly how someone else''s file gets deleted.'
    } else {
        Write-Step '-- Nothing to migrate --'
        Write-Ok 'This machine has no in-place Aefos install. Nothing was changed.'
    }
    exit $EXIT_OK
}

# ===========================================================================
# 3. GUARDS BEFORE THE FIRST WRITE
# ===========================================================================
if (-not $UninstallEngine -or -not (Test-Path -LiteralPath $UninstallEngine)) {
    Write-BadMsg @"
The shipped uninstall engine (aefos-laz-uninstall.ps1) was not found.

This migration deliberately does NOT contain its own copy of the undo logic -
every rule in that engine (index-safe list edits, DLL provenance, "a value you
changed is yours", the refusal to rebuild your IDE) was paid for with real
damage, and two copies would drift. Pass -UninstallEngine <path>.

NOTHING was changed.
"@
    exit $EXIT_REFUSED
}

if (-not (Test-FileReplaceable -Path $LazExe)) {
    Write-BadMsg @"
Your lazarus.exe is locked, which means Lazarus is running:

    $LazExe

Restoring your stock IDE binary means replacing that file. Doing it while the
IDE is open would fail halfway through and leave you with neither IDE.

Close Lazarus and run this again. NOTHING was changed.
"@
    exit $EXIT_REFUSED
}

$ExeShaNow    = if (Test-Path -LiteralPath $LazExe) { Get-AefosFileHash -Path $LazExe } else { $null }
$ExeHasAefos  = Test-ExeCarriesAefos -Path $LazExe
$BackupFiles  = @(Get-ChildItem -Path $LazDir -Filter 'lazarus-aefos-backup-*.exe' -ErrorAction SilentlyContinue | Sort-Object Name)
$BackupInLaz  = if ($BackupFiles.Count -gt 0) { $BackupFiles[0] } else { $null }

# What the journal remembers from a previous attempt.
$JStockSha    = Get-AefosJournalValue -Journal $Journal -Key 'stockSha256'
$JStockName   = Get-AefosJournalValue -Journal $Journal -Key 'stockBackupName'
$JExeShaStart = Get-AefosJournalValue -Journal $Journal -Key 'exeSha256AtStart'
$JAttempts    = Get-AefosJournalValue -Journal $Journal -Key 'attempts'
if (-not $JAttempts) { $JAttempts = 0 }

$SafeguardExe = $null
if (Test-Path -LiteralPath $SafeguardDir) {
    $cand = @(Get-ChildItem -Path $SafeguardDir -Filter 'lazarus-aefos-backup-*.exe' -ErrorAction SilentlyContinue)
    if ($cand.Count -gt 0) { $SafeguardExe = $cand[0] }
}

# ---------------------------------------------------------------------------
# RESUME RECONCILIATION - by evidence, never by the journal's phase alone.
#
# The one situation we refuse: a resumed run whose lazarus.exe is NEITHER the
# binary we started from NOR the stock one, with no backup anywhere. Something
# else replaced it between the two runs (the user rebuilt his IDE, an antivirus
# quarantined it, a Lazarus update landed). Restoring a stock exe from a
# possibly-stale copy over that would destroy work that is not ours to judge.
# ---------------------------------------------------------------------------
if ($Resuming -and $JStockSha -and $ExeShaNow) {
    $exeIsStock = ($ExeShaNow -eq $JStockSha)
    $exeIsOurs  = ($JExeShaStart -and ($ExeShaNow -eq $JExeShaStart))
    $haveStock  = $false
    if ($BackupInLaz) { $haveStock = ((Get-AefosFileHash -Path $BackupInLaz.FullName) -eq $JStockSha) }
    if (-not $haveStock -and $SafeguardExe) { $haveStock = ((Get-AefosFileHash -Path $SafeguardExe.FullName) -eq $JStockSha) }
    if (-not $exeIsStock -and -not $exeIsOurs -and -not $haveStock) {
        Write-BadMsg @"
STOPPING: this machine is not in a state this migration can reason about.

Your lazarus.exe is neither the binary the interrupted migration started from
nor the stock one it recorded, and no copy of your stock binary is left:

    lazarus.exe now : $ExeShaNow
    was, at start   : $JExeShaStart
    stock recorded  : $JStockSha

Something replaced your IDE binary between the two runs (a rebuild of your own,
a Lazarus update, or a security product). Putting our recorded stock copy over
it could throw away work that has nothing to do with Aefos.

NOTHING was changed. The journal is at:
    $JournalPath
"@
        exit $EXIT_REFUSED
    }
}

# ===========================================================================
# 4. SAFEGUARD - our own copy of the stock binary, before anything is undone.
#
# The shipped engine DELETES the backup as soon as it restores it
# (aefos-laz-uninstall.ps1:283-284). A power cut right after that leaves a
# machine whose exe is already stock but whose recovery path can no longer see a
# backup, so a re-run would decide it restored nothing ($restored=$false, :250),
# skip the DLL step (:495,:586) and exit 1 with a "could not restore" notice.
# Holding our own copy until the whole migration is VERIFIED closes that window
# without duplicating a single line of the undo.
# ===========================================================================
if (-not (Test-Path -LiteralPath $AefosHome)) { New-Item -ItemType Directory -Force -Path $AefosHome | Out-Null }

$Journal = @{
    schema           = 1
    startedUtc       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    lazarusDir       = $LazDir
    pcp              = $Pcp
    aefosHome        = $AefosHome
    attempts         = ([int]$JAttempts + 1)
    phase            = 'safeguard'
    exeSha256AtStart = $ExeShaNow
    exeCarriedAefos  = $ExeHasAefos
    stockBackupName  = $JStockName
    stockSha256      = $JStockSha
    evidence         = @($Evidence | ForEach-Object { @{ id = $_.Id; strength = $_.Strength; detail = $_.Detail } })
}
Write-AefosMigrationJournal -Path $JournalPath -Journal $Journal

Write-Step '-- Safeguarding your stock lazarus.exe --'
$SynthesizedBackup = $false
if ($BackupInLaz) {
    if (-not (Test-Path -LiteralPath $SafeguardDir)) { New-Item -ItemType Directory -Force -Path $SafeguardDir | Out-Null }
    $safeCopy = Join-Path $SafeguardDir $BackupInLaz.Name
    Copy-Item -LiteralPath $BackupInLaz.FullName -Destination $safeCopy -Force
    $Journal['stockBackupName'] = $BackupInLaz.Name
    $Journal['stockSha256']     = Get-AefosFileHash -Path $safeCopy
    $Journal['safeguardPath']   = $safeCopy
    Write-Ok ("Copied {0} into {1} (kept until the migration is verified)." -f $BackupInLaz.Name, $SafeguardDir)
}
elseif (-not $ExeHasAefos) {
    # The binary on disk carries NO Aefos string, so it is already Aefos-free -
    # this is the state a crashed migration (or the 0.24.7 uninstaller stopping
    # halfway) leaves behind: stock exe, but our link/list/DLLs still around.
    #
    # The shipped engine only runs its cleanup-to-the-end path when it actually
    # restored something (:495), so give it a backup to restore: a byte-for-byte
    # copy of the CURRENT, provably Aefos-free binary. Copying that file over
    # itself is a verifiable no-op, and it lets the engine finish its own DLL and
    # state-file handling instead of us re-implementing it. It is recorded here
    # as synthesized so a later run can tell it from a real stock backup.
    if (-not (Test-Path -LiteralPath $SafeguardDir)) { New-Item -ItemType Directory -Force -Path $SafeguardDir | Out-Null }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $synthName = "lazarus-aefos-backup-$stamp.exe"
    $safeCopy = Join-Path $SafeguardDir $synthName
    Copy-Item -LiteralPath $LazExe -Destination $safeCopy -Force
    $Journal['stockBackupName'] = $synthName
    $Journal['stockSha256']     = Get-AefosFileHash -Path $safeCopy
    $Journal['safeguardPath']   = $safeCopy
    $Journal['synthesized']     = $true
    $SynthesizedBackup = $true
    Write-Ok 'Your lazarus.exe carries no Aefos string, so it is already stock; using it as the restore source.'
}
else {
    Write-WarnMsg 'No backup of your stock lazarus.exe exists on this machine, and the one in place has Aefos compiled in.'
    Write-WarnMsg 'The binary will be LEFT EXACTLY AS IT IS. Everything else will still be cleaned up.'
}
Write-AefosMigrationJournal -Path $JournalPath -Journal $Journal

# A previous attempt consumed the real backup: put our safeguarded copy back
# under the SAME name so the shipped engine takes its normal path end to end.
if (-not $BackupInLaz -and $Journal['stockSha256']) {
    $safeguardNow = $null
    if ($Journal.ContainsKey('safeguardPath') -and $Journal['safeguardPath'] -and (Test-Path -LiteralPath $Journal['safeguardPath'])) {
        $safeguardNow = [string]$Journal['safeguardPath']
    } elseif ($SafeguardExe) {
        $safeguardNow = $SafeguardExe.FullName
    }
    if ($safeguardNow -and ((Get-AefosFileHash -Path $safeguardNow) -eq [string]$Journal['stockSha256'])) {
        $target = Join-Path $LazDir ([string]$Journal['stockBackupName'])
        Copy-Item -LiteralPath $safeguardNow -Destination $target -Force
        Write-Ok ("Re-supplied the stock backup a previous attempt had already consumed ({0})." -f (Split-Path -Leaf $target))
    }
}

# ===========================================================================
# 5. REVERT - through the SHIPPED engine. -Method Restore, always. There is no
#    branch, flag or fallback in this file that can reach -Method Rebuild.
# ===========================================================================
$Journal['phase'] = 'revert'
Write-AefosMigrationJournal -Path $JournalPath -Journal $Journal

Write-Step '-- Reverting the in-place install (shipped aefos-laz-uninstall.ps1 -Method Restore) --'
$PowerShellHost = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PowerShellHost)) { $PowerShellHost = 'powershell.exe' }

$engineArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $UninstallEngine,
                '-Method', 'Restore', '-LazarusDir', $LazDir)
if ($PcpUsable) { $engineArgs += @('-Pcp', $Pcp) }

& $PowerShellHost @engineArgs *>&1 | Tee-Object -FilePath $EngineLog
$EngineExit = $LASTEXITCODE
$Journal['engineExit'] = $EngineExit
$Journal['phase'] = 'verify'
Write-AefosMigrationJournal -Path $JournalPath -Journal $Journal
Write-Host ("uninstall engine exit={0} (log: {1})" -f $EngineExit, $EngineLog)

# ===========================================================================
# 6. VERIFY - by evidence on disk, never by the engine's exit code.
#
# The exit code says "did THIS run restore something", not "is the machine
# clean". A resumed migration whose previous attempt already restored the exe
# gets exit 1 from an engine that did its job. Judge the disk.
# ===========================================================================
Write-Step '-- Verifying by evidence (not by exit code) --'
$Reverted   = @()
$Remaining  = @()

$ExeShaAfter = if (Test-Path -LiteralPath $LazExe) { Get-AefosFileHash -Path $LazExe } else { $null }
$ExeStillAefos = Test-ExeCarriesAefos -Path $LazExe

# THE FACT, not the heuristic. "Is the user's stock binary back?" is answered by
# comparing sha-256 against the backup we safeguarded - never by scanning the
# file for our package name.
#
# Found by the migration gate on 2026-07-27: a stock backup can itself contain
# the string (any Lazarus tree that ever had Aefos linked, then had a stock exe
# copied over it, or - as in the gate's own sandbox - a source tree whose
# baseline was already Aefos-linked). Keying off the string there made a
# byte-perfect restore report "your lazarus.exe still has Aefos compiled in",
# which flipped a completed migration to PARTIAL and told the user to go
# rebuild his IDE for nothing. The string scan stays only for the case where
# there is no backup to compare against, which is exactly where a heuristic is
# all anyone has.
$ExeIsRestoredStock = [bool]($Journal['stockSha256'] -and $ExeShaAfter -and ($ExeShaAfter -eq [string]$Journal['stockSha256']))
$ExeStillCarriesUs  = ((-not $ExeIsRestoredStock) -and $ExeStillAefos)

# Two files of OURS that the in-place install/uninstall left in the user's
# Lazarus folder. They are unambiguously ours (nothing else on a machine is
# called that), they are not state, and "your IDE back the way it was" does not
# survive a log of ours sitting in it. They go only once the binary is verified
# stock: on the partial path the notice is the one piece of on-screen help the
# user actually has, and deleting it there would take his instructions away.
if ($ExeIsRestoredStock) {
    foreach ($ours in @('aefos-laz-buildide.log', 'AEFOS-UNINSTALL-README.txt')) {
        $p = Join-Path $LazDir $ours
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $p)) { $Reverted += ("removed $ours (our own file, left in your Lazarus folder by the in-place install).") }
        }
    }
}

if ($Journal['stockSha256']) {
    if ($ExeShaAfter -eq [string]$Journal['stockSha256']) {
        if ($SynthesizedBackup) {
            $Reverted += 'lazarus.exe was already free of Aefos and is unchanged (verified by sha-256).'
        } else {
            $Reverted += ("lazarus.exe restored to your stock binary, byte-exact (sha-256 {0}...)." -f $ExeShaAfter.Substring(0, 16))
        }
    } else {
        $shownNow = if ($ExeShaAfter) { $ExeShaAfter.Substring(0, 16) } else { '<lazarus.exe is GONE>' }
        $Remaining += ("lazarus.exe does NOT match the stock backup we safeguarded (now {0}..., expected {1}...). It was NOT rebuilt by us." -f `
            $shownNow, ([string]$Journal['stockSha256']).Substring(0, 16))
    }
} elseif ($ExeStillCarriesUs) {
    $Remaining += 'lazarus.exe still has Aefos compiled in: there was no backup of your stock binary to put back. It starts and works exactly as it does today.'
}

if ($PcpUsable) {
    $linksPath = Join-Path $Pcp 'packagefiles.xml'
    $miscPath  = Join-Path $Pcp 'miscellaneousoptions.xml'
    $linkNames = @(Get-AefosUserLinkNames -Path $linksPath)
    $listNames = @(Get-AefosInstallListNames -Path $miscPath)
    if ($linkNames -contains $PkgName) { $Remaining += 'the Aefos package link is still in packagefiles.xml.' }
    else { $Reverted += ("the Aefos package link is gone from packagefiles.xml ({0} link(s) of yours kept: {1})." -f $linkNames.Count, ($linkNames -join ', ')) }
    if ($listNames -contains $PkgName) { $Remaining += 'Aefos is still in your IDE install list (StaticAutoInstallPackages).' }
    else { $Reverted += ("Aefos is off your IDE install list ({0} package(s) of yours kept: {1})." -f $listNames.Count, ($listNames -join ', ')) }

    foreach ($probe in @(
        @{ File = 'packagefiles.xml';         XPath = '//UserPkgLinks';              Label = 'UserPkgLinks' },
        @{ File = 'miscellaneousoptions.xml'; XPath = '//StaticAutoInstallPackages'; Label = 'StaticAutoInstallPackages' })) {
        $problem = Get-AefosListProblem -Path (Join-Path $Pcp $probe.File) -XPath $probe.XPath -Label $probe.Label
        if ($problem) { $Remaining += ("your package list is not index-readable after the revert: " + $problem) }
    }
}

if (Test-Path -LiteralPath (Join-Path $LazDir 'aefos-laz-install-state.json')) {
    $Remaining += 'aefos-laz-install-state.json is still in your Lazarus folder (the engine keeps it while a restore is pending).'
} else {
    $Reverted += 'aefos-laz-install-state.json removed from your Lazarus folder.'
}

$leftBackups = @(Get-ChildItem -Path $LazDir -Filter 'lazarus-aefos-backup-*.exe' -ErrorAction SilentlyContinue)
if ($leftBackups.Count -gt 0) {
    $Remaining += ("our backup copy of your exe is still there: " + (($leftBackups | ForEach-Object { $_.Name }) -join ', '))
}

# The user's OWN DLL, moved aside by our install. If it is still sitting there
# under our .bak name, HIS file is the one left in limbo - say so with the exact
# file name and what to do, never silently.
$leftDisplaced = @(Get-ChildItem -Path $LazDir -Filter '*.aefos-preexisting-*.bak' -ErrorAction SilentlyContinue)
foreach ($f in $leftDisplaced) {
    $orig = $f.Name -replace '\.aefos-preexisting-.*\.bak$', ''
    $Remaining += ("YOUR OWN {0} is still parked as {1}. Rename it back over {0} - it is your file, not ours." -f $orig, $f.Name)
}

$ourDlls = @()
foreach ($name in @('WebView2Loader.dll', 'sqlite3.dll', 'libvterm.dll')) {
    if (Test-Path -LiteralPath (Join-Path $LazDir $name)) { $ourDlls += $name }
}
if ($ourDlls.Count -gt 0) {
    if ($ExeStillCarriesUs) {
        $Remaining += ("{0} left beside lazarus.exe ON PURPOSE: your lazarus.exe still has Aefos compiled in and will NOT START without them." -f ($ourDlls -join ', '))
    } else {
        $Remaining += ("still beside lazarus.exe: {0}. A file with one of these names can be yours - sqlite3.dll next to lazarus.exe is what every Lazarus SQLdb setup does - and where the install recorded that the copy there was yours, yours is what is back. Nothing was deleted without proof of ownership; anything here you did not put there is safe to delete." -f ($ourDlls -join ', '))
    }
}

if (Test-Path -LiteralPath (Join-Path $LazDir 'aefos-laz-buildide.log')) {
    $Remaining += 'aefos-laz-buildide.log is still in your Lazarus folder (our build transcript from the in-place install; harmless, and yours to delete).'
}
if (Test-Path -LiteralPath (Join-Path $LazDir 'AEFOS-UNINSTALL-README.txt')) {
    # Kept on purpose while the binary is still ours: it carries the same manual
    # step as this report, in the folder the user is actually looking at.
    $Remaining += 'AEFOS-UNINSTALL-README.txt is in your Lazarus folder. It repeats the manual step below; delete it once you have finished.'
}

# THE LOSS AN OLD INSTALL ALREADY CAUSED, AND THAT NOBODY CAN UNDO.
#
# Before aefos-laz-install-state.json existed, the install copied its three DLLs
# over whatever was beside lazarus.exe with no backup, and the uninstaller's
# legacy path then DELETED them (aefos-laz-uninstall.ps1:538-543). If one of
# those names was a DLL the user kept there himself - and sqlite3.dll beside
# lazarus.exe is what every Lazarus SQLdb tutorial tells people to do - his copy
# was destroyed at INSTALL time, months ago. There is nothing to restore and no
# record of what it was. Saying nothing would be the dishonest option.
if (@($Evidence | Where-Object { $_.Id -eq 'STATE-FILE' }).Count -eq 0 -and
    @($Evidence | Where-Object { $_.Id -eq 'RUNTIME-DLLS' }).Count -gt 0) {
    $Remaining += ('This install predates the record we now keep of what was beside your lazarus.exe. ' +
        'If YOU kept your own WebView2Loader.dll, sqlite3.dll or libvterm.dll there before installing Aefos, ' +
        'that install overwrote it without keeping a copy - our copies have been removed, but yours cannot be ' +
        'brought back from here. Re-copy it from wherever you originally got it.')
}

# The three IDE preferences an install older than 2026-07-27 forced into HIS
# environmentoptions.xml. Without aefos-laz-install-state.json nobody knows what
# they were, and inventing a default is forbidden (the engines' own rule). All
# we can honestly do is name them.
$LegacyPrefsWarning = ''
if ($PcpUsable -and @($Strong | Where-Object { $_.Id -eq 'STATE-FILE' }).Count -eq 0) {
    $envXml = Join-Path $Pcp 'environmentoptions.xml'
    if (Test-Path -LiteralPath $envXml) {
        try {
            [xml]$envDoc = Get-Content -LiteralPath $envXml -Raw
            $hits = @()
            # '//' and not a path relative to DocumentElement: the document
            # element is <CONFIG>, the keys live under <EnvironmentOptions>, and a
            # relative path silently matches nothing - which would look exactly
            # like "the install never touched them".
            foreach ($probe in @(
                @{ Path = '//DebuggerOptions/ShowStopMessage';             Forced = 'False' },
                @{ Path = '//DebuggerOptions/DebuggerShowExitCodeMessage'; Forced = 'False' },
                @{ Path = '//CheckDiskChangesWithLoading';                 Forced = 'True'  })) {
                $leaf = $envDoc.SelectSingleNode($probe.Path)
                # Name them the way the user sees them, not as XPath: '//' is our
                # query syntax and means nothing to the person reading the report.
                if ($leaf -and ($leaf.GetAttribute('Value') -eq $probe.Forced)) { $hits += ($probe.Path -replace '^//', '') }
            }
            if ($hits.Count -gt 0) {
                $LegacyPrefsWarning = ("These IDE preferences hold exactly the values an Aefos install older than " +
                    "2026-07-27 used to force, and that install kept no record of what they were before, so they " +
                    "were LEFT ALONE rather than reset to a default we would be inventing: " + ($hits -join ', ') +
                    ". If your debugger no longer tells you that a program stopped, this is why - Tools > Options > Debugger.")
            }
        } catch { }
    }
}

# Packages that are marked for installation in HIS list but whose name is not in
# the restored binary: they were installed into the IDE AFTER our backup was
# taken, so the stock binary predates them. Cheap, evidence-based, and it turns
# a confusing "my component is gone" into one known menu action.
$StaleAfterRestore = @()
if ($PcpUsable -and $Journal['stockSha256'] -and ($ExeShaAfter -eq [string]$Journal['stockSha256']) -and -not $SynthesizedBackup) {
    foreach ($name in @(Get-AefosInstallListNames -Path (Join-Path $Pcp 'miscellaneousoptions.xml'))) {
        if ($name -eq $PkgName) { continue }
        if (-not (Select-String -Path $LazExe -Pattern $name -SimpleMatch -Quiet -ErrorAction SilentlyContinue)) {
            $StaleAfterRestore += $name
        }
    }
}

# THE CONSEQUENCE OF A HONEST RESTORE, WHEN THE BACKUP PREDATES HIS OWN UPGRADE.
#
# Only on the path where we actually put a stored binary back: with a synthesized
# backup nothing was replaced (the exe on disk is the one that was already
# there), and where no backup existed the binary is HIS current one - in neither
# case did we hand him a different version, so neither is ours to warn about.
# See the version-triangle block at the top for what is compared and why.
$VersionMismatch = $null
if ($ExeIsRestoredStock -and (-not $SynthesizedBackup)) {
    $VersionMismatch = Get-AefosRestoredVersionMismatch -LazDir $LazDir `
        -PcpDir $(if ($PcpUsable) { $Pcp } else { '' }) -ExePath $LazExe
}
$VersionMismatchLines = @()
if ($VersionMismatch) {
    $VersionMismatchLines = @(Get-AefosVersionMismatchLines -Mismatch $VersionMismatch `
        -LazDir $LazDir -PcpDir $Pcp -BackupName ([string]$Journal['stockBackupName']))
    $Journal['versionMismatch'] = @{
        exe    = $VersionMismatch.ExeVersion
        tree   = $VersionMismatch.TreeVersion
        config = $VersionMismatch.ConfigVersion
    }
}

foreach ($line in $Reverted)  { Write-Ok   ("  reverted : " + $line) }
foreach ($line in $Remaining) { Write-WarnMsg ("  remains  : " + $line) }

# ===========================================================================
# 7. REPORT + CLEAN UP THE SAFEGUARD
# ===========================================================================
# What keeps the verdict from being MIGRATED: our package still linked into his
# binary, our entries still in his config, a list he can no longer read - and a
# file of HIS still parked under one of OUR names. That last one is not cosmetic:
# until he renames it back, the DLL he chose to keep beside lazarus.exe is not
# the one in use, and only he can decide which copy wins.
$Blocking = @($Remaining | Where-Object {
    $_ -like '*still has Aefos compiled in*' -or
    $_ -like '*still in packagefiles.xml*' -or
    $_ -like '*still in your IDE install list*' -or
    $_ -like '*not index-readable*' -or
    $_ -like '*is still parked as*' })
$Verdict = if ($Blocking.Count -eq 0) { 'MIGRATED' } else { 'PARTIAL' }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('Aefos AI - Lazarus edition: migration report')
[void]$sb.AppendLine('============================================')
[void]$sb.AppendLine('')
[void]$sb.AppendLine(("date        : {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
[void]$sb.AppendLine(("lazarus dir : {0}" -f $LazDir))
[void]$sb.AppendLine(("config (pcp): {0}" -f $Pcp))
[void]$sb.AppendLine(("verdict     : {0}" -f $Verdict))
[void]$sb.AppendLine('')
# FIRST, not in an appendix. Everything else in this report is history the user
# may never need; this is the only part that changes what he should do in the
# next five minutes, and it has to be read BEFORE he opens Lazarus.
if ($VersionMismatchLines.Count -gt 0) {
    [void]$sb.AppendLine('==============================================================================')
    foreach ($line in $VersionMismatchLines) { [void]$sb.AppendLine($line) }
    [void]$sb.AppendLine('==============================================================================')
    [void]$sb.AppendLine('')
}
[void]$sb.AppendLine('WHY THIS RAN')
[void]$sb.AppendLine('Earlier versions of Aefos AI for Lazarus installed themselves INTO your IDE:')
[void]$sb.AppendLine('your lazarus.exe was relinked with Aefos compiled in, and our package was')
[void]$sb.AppendLine('registered in your Lazarus configuration. The current version does not do that')
[void]$sb.AppendLine('any more - it builds its own IDE in its own folder and leaves yours alone. This')
[void]$sb.AppendLine('step gives your IDE back first.')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('WHAT WAS FOUND')
foreach ($ev in $Evidence) { [void]$sb.AppendLine(("  [{0,-9}] {1,-17} {2}" -f $ev.Strength, $ev.Id, $ev.Detail)) }
if ($Evidence.Count -eq 0) { [void]$sb.AppendLine('  (nothing)') }
[void]$sb.AppendLine('')
[void]$sb.AppendLine('WHAT WAS PUT BACK')
if ($Reverted.Count -eq 0) { [void]$sb.AppendLine('  (nothing)') }
foreach ($line in $Reverted) { [void]$sb.AppendLine('  * ' + $line) }
[void]$sb.AppendLine('')
[void]$sb.AppendLine('WHAT WAS NOT, AND WHY')
# "(nothing)" is only true when NOTHING follows - including the pcp warning, the
# legacy-preferences disclosure and any pre-existing damage. The first cut
# printed "(nothing - your IDE is back the way it was)" and then listed three
# things underneath it.
$NotDone = @($Remaining)
if ($PcpWarning) { $NotDone += $PcpWarning }
if ($LegacyPrefsWarning) { $NotDone += $LegacyPrefsWarning }
if ($NotDone.Count -eq 0 -and $PreExistingListDamage.Count -eq 0) {
    [void]$sb.AppendLine('  (nothing - your IDE is back the way it was)')
}
foreach ($line in $NotDone) { [void]$sb.AppendLine('  * ' + $line) }
foreach ($d in $PreExistingListDamage) {
    [void]$sb.AppendLine('  * Your Lazarus package list was ALREADY unreadable before this ran (' + $d + ').')
    [void]$sb.AppendLine('    That is the 0.24.7 uninstaller bug, not this migration. The list was renumbered')
    [void]$sb.AppendLine('    so Lazarus can read it again, but any package the IDE had already dropped from')
    [void]$sb.AppendLine('    the install list has to be re-added by you in Package > Install/Uninstall Packages.')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('WHAT WE DID NOT DO, ON PURPOSE')
[void]$sb.AppendLine('  * We did not rebuild your IDE. A rebuild uses YOUR list of installed packages,')
[void]$sb.AppendLine('    and if any one of them cannot be opened right now the rebuilt IDE comes back')
[void]$sb.AppendLine('    without them. We are not willing to risk your setup to finish removing our own')
[void]$sb.AppendLine('    product. No lazbuild was run by this migration, at all.')
[void]$sb.AppendLine('  * We did not touch anything of yours that we did not put there.')
if ($StaleAfterRestore.Count -gt 0) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('ONE THING TO CHECK')
    [void]$sb.AppendLine('  Your restored lazarus.exe is the one from before Aefos was installed. These')
    [void]$sb.AppendLine('  packages are marked for installation in your IDE but are not in that binary,')
    [void]$sb.AppendLine('  so you probably installed them after Aefos:')
    foreach ($n in $StaleAfterRestore) { [void]$sb.AppendLine('    - ' + $n) }
    [void]$sb.AppendLine('  Package > Install/Uninstall Packages > "Save and rebuild IDE" brings them back.')
}
if ($ExeStillCarriesUs) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('HOW TO FINISH (about two minutes, at your convenience)')
    [void]$sb.AppendLine('  Your lazarus.exe still has Aefos compiled in because the backup of your stock')
    [void]$sb.AppendLine('  binary is not on this machine any more. Your IDE keeps working exactly as it')
    [void]$sb.AppendLine('  does today; the only leftover is the Aefos menu inside it. When you want it')
    [void]$sb.AppendLine('  gone:')
    [void]$sb.AppendLine('    1. Open Lazarus.')
    [void]$sb.AppendLine('    2. Package > Install/Uninstall Packages.')
    [void]$sb.AppendLine('    3. Aefos is already off the install list - just click "Save and rebuild IDE".')
    [void]$sb.AppendLine('       That is the only rebuild that respects YOUR package list, which is why we')
    [void]$sb.AppendLine('       leave it to you.')
    [void]$sb.AppendLine('    4. After it restarts you may delete WebView2Loader.dll, sqlite3.dll and')
    [void]$sb.AppendLine('       libvterm.dll from your Lazarus folder - but NOT any file named')
    [void]$sb.AppendLine('       *.aefos-preexisting-*.bak: that one is YOUR OWN DLL, which our install had')
    [void]$sb.AppendLine('       to move aside. Rename it back instead.')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('The new Aefos AI builds its own IDE under:')
[void]$sb.AppendLine('    ' + $AefosHome)
[void]$sb.AppendLine('Your Lazarus installation and your Lazarus configuration are not written to any')
[void]$sb.AppendLine('more. Uninstalling deletes that folder.')

$ReportText = $sb.ToString()
try { Set-Content -LiteralPath $ReportPath -Value $ReportText -Encoding UTF8 } catch { }

if ($Verdict -eq 'MIGRATED') {
    # Only now is the safeguarded copy expendable: the machine is verified.
    if (Test-Path -LiteralPath $SafeguardDir) {
        Remove-Item -LiteralPath $SafeguardDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $Journal['phase'] = 'done'
    $Journal['verdict'] = 'MIGRATED'
    Write-AefosMigrationJournal -Path $JournalPath -Journal $Journal
    Write-Step '-- Migration complete --'
    Write-Ok 'Your Lazarus IDE is back the way it was. Report:'
    Write-Host "    $ReportPath"

    # MIGRATED, and yet not silent. The undo is complete and verified - which is
    # why the verdict, the journal and the safeguard cleanup above are exactly
    # what they are for a clean migration - but handing the binary back put an
    # inherited version mismatch back in plain sight, and the next thing this
    # user does is open Lazarus. Exit 3 is what makes the installer show him the
    # report instead of finishing quietly (see $EXIT_ATTENTION).
    if ($VersionMismatchLines.Count -gt 0) {
        Write-Host ''
        Write-WarnMsg '=============================================================================='
        foreach ($line in $VersionMismatchLines) { Write-WarnMsg $line }
        Write-WarnMsg '=============================================================================='
        Write-WarnMsg "This warning is also at the top of: $ReportPath"
        exit $EXIT_ATTENTION
    }
    exit $EXIT_OK
}

# PARTIAL: everything reversible is done. Nothing was rebuilt, nothing that
# could break the IDE was changed, and the leftovers are named. The safeguard is
# KEPT - the migration is not finished, and a later run may still need it.
$Journal['phase'] = 'partial'
$Journal['verdict'] = 'PARTIAL'
$Journal['remaining'] = $Remaining
Write-AefosMigrationJournal -Path $JournalPath -Journal $Journal

Write-Host ''
Write-WarnMsg '============================================================'
Write-WarnMsg $ReportText
Write-WarnMsg '============================================================'
Write-WarnMsg "This report was also saved to: $ReportPath"
exit $EXIT_PARTIAL
