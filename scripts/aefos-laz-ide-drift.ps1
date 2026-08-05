<#
.SYNOPSIS
    MILESTONE 2 / SLICE F6 -- DETECT that the user's Lazarus moved out from under
    the isolated Aefos IDE. One function, Get-AefosIdeDrift, answers "is the IDE we
    built still the IDE he should be running", in milliseconds, from files only.

.DESCRIPTION
    WHY THIS IS NOT COSMETIC
    ------------------------
    Our lazarus.exe is a closed PE linked against the .ppu set of HIS tree at the
    moment we built it, and it reads HIS sources, HIS LCL and HIS FPC at run time
    through --lazarusdir. Every one of those can change without us: he upgrades
    Lazarus, he rebuilds his own IDE, he installs a package, he moves the folder, he
    swaps the FPC. From that instant our binary and his tree disagree, and the ways
    that shows up range from a confusing modal to the IDE deleting our own files.

    THE ONE THAT DELETES FILES, STATED EXACTLY
    ------------------------------------------
    ide\main.pp:1342-1379 (TMainIDE.LoadGlobalOptions):

        OldVer := EnvironmentOptions.OldLazarusVersion;   // <pcp>\environmentoptions.xml
                                                          //   EnvironmentOptions/Version@Lazarus
        NowVer := LazarusVersionStr;                      // {$I version.inc} COMPILED INTO THE EXE
        if FEnvOptsCfgExisted and (OldVer <> NowVer) then begin
          ... Upgrade/Downgrade dialog; Abort terminates the IDE ...
          DeleteDirectory(PCP+'bin', false);
          DeleteDirectory(PCP+'units', false);
        end;

    Note WHAT is compared: the config stamp against the version compiled INTO THE
    RUNNING EXE. His tree is not part of that comparison. So the plain event "he
    upgraded Lazarus to 4.9" does NOT arm it -- our exe still says 4.8 and our
    config still says 4.8. What arms it is a REBUILD of our exe against the newer
    tree, which is exactly what reconciling means. The bomb is on the repair path,
    not on the damage path, and that is the opposite of the intuitive reading.

    It also arms itself with no installer involved: environmentopts.pp:1211 writes
    Version/Lazarus := LazarusVersionStr on every save, and pkgmanager's "Save and
    rebuild IDE" inside our IDE rebuilds our exe from HIS CURRENT sources into our
    own <pcp>\bin. Upgrade his Lazarus, then rebuild from inside the Aefos IDE, and
    the next start has a 4.9 exe against a 4.8 config.

    WHAT SURVIVES THE DELETE, AND WHY IT IS LUCK (measured in F0/EXP-2)
    ------------------------------------------------------------------
    DeleteDirectory (components\lazutils\fileutil.inc:104-134) is ONE FindFirst pass
    that EXITS on the first failure. The running lazarus.exe is locked by Windows and
    sorts before libvterm.dll / sqlite3.dll / units / WebView2Loader.dll, so the loop
    dies on the exe and everything after it survives. Measured live: with a wrong
    stamp exactly one planted file died (aaa-aefos-canary.dll, which sorts BEFORE the
    exe) and <pcp>\units was removed ENTIRELY, directory included. That is why
    Test-AefosIsolatedBinNameSafe exists and why nothing of ours is ever kept in
    <pcp>\units.

    WHAT THIS FILE IS, AND WHAT IT IS NOT
    -------------------------------------
    It is a LIBRARY: no param() block, no side effects, dot-source it from anywhere
    (the same rule as aefos-laz-isolated-layout.ps1 -- a param() block here would run
    in the CALLER's scope and blank same-named variables). The runnable surface is
    scripts\aefos-laz-reconcile-ide.ps1.

    It does NOT decide policy. It reports findings with a severity and a suggested
    action; whether to heal, to offer a rebuild or to say nothing is the reconciler's
    call (slice F7) and, in the end, the user's.

    THE CONTRACT FOR THE IN-IDE (PASCAL) READER -- A SEPARATE SLICE, ON PURPOSE
    ---------------------------------------------------------------------------
    Detection has to run when our IDE STARTS, and starting a PowerShell process from
    IDE startup is not acceptable (a console flash and several hundred ms on the one
    path the user feels most). So the in-IDE check will be Pascal, in our own
    package, and it is NOT improvised here. What it must do is fully specified by
    this file so the two cannot drift:

      1. read <pcp>\aefos-ide.json                       (the stamp this install wrote)
      2. read <lazdir>\ide\packages\ideconfig\version.inc (his version today)
      3. read <lazdir>\ide\revision.inc                   (his revision today)
      4. list <lazdir>\fpc\<x.y.z>                        (his FPC today)
      5. stat <lazdir>\lazarus.exe and <pcp>\bin\lazarus.exe (size + mtime)
      6. read EnvironmentOptions/Version@Lazarus from <pcp>\environmentoptions.xml
      7. read StaticAutoInstallPackages from HIS <pcp>\miscellaneousoptions.xml
    Same comparisons, same finding ids, same severities as Get-AefosIdeDrift, and the
    result is shown as a NON-MODAL bar. Never a modal: a modal on the IDE main thread
    freezes the MCP pipe and deadlocks the agent (house rule, paid for already).
    Everything above is file reads of at most a few KB -- see the ElapsedMs the
    detector reports for the real number.

.EXAMPLE
    . .\scripts\aefos-laz-isolated-layout.ps1
    . .\scripts\aefos-laz-seed-pcp.ps1
    . .\scripts\aefos-laz-import-components.ps1
    . .\scripts\aefos-laz-ide-drift.ps1
    $drift = Get-AefosIdeDrift
    $drift.Status      # Ok | Stale | Broken | NotInstalled
#>

# NOTE: no file-scope $ErrorActionPreference / Set-StrictMode -- dot-sourced.

$Script:AefosDriftStampName   = 'aefos-ide.json'
$Script:AefosDriftEnvFile     = 'environmentoptions.xml'
$Script:AefosDriftIdeExeName  = 'lazarus.exe'
$Script:AefosDriftStampSchema = 2

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    The functions this library builds on, and which file each comes from. Checked
    rather than dot-sourced: two of those files carry a param() block, and
    dot-sourcing them from HERE would blank the caller's own parameters -- the trap
    already documented in aefos-laz-install-isolated.ps1 and reused by
    aefos-laz-import-components.ps1 (Test-AefosImportSeederLoaded).
#>
function Test-AefosDriftDependenciesLoaded {
    $needed = @(
        [pscustomobject]@{ Fn = 'Get-AefosIsolatedInstallPcp';   From = 'scripts\aefos-laz-isolated-layout.ps1' }
        [pscustomobject]@{ Fn = 'Get-AefosIsolatedFullPath';     From = 'scripts\aefos-laz-isolated-layout.ps1' }
        [pscustomobject]@{ Fn = 'Test-AefosIsolatedSamePath';    From = 'scripts\aefos-laz-isolated-layout.ps1' }
        [pscustomobject]@{ Fn = 'Get-AefosIsolatedPayloadDlls';  From = 'scripts\aefos-laz-isolated-layout.ps1' }
        [pscustomobject]@{ Fn = 'Get-AefosLazarusTreeInfo';      From = 'scripts\aefos-laz-seed-pcp.ps1' }
        [pscustomobject]@{ Fn = 'Get-AefosUserInstallList';      From = 'scripts\aefos-laz-import-components.ps1' }
    )
    $missing = @()
    foreach ($n in $needed) {
        if (-not (Get-Command -Name $n.Fn -ErrorAction SilentlyContinue)) { $missing += ("{0} (from {1})" -f $n.Fn, $n.From) }
    }
    if ($missing.Count -gt 0) {
        throw ("aefos-laz-ide-drift.ps1 needs these dot-sourced first: {0}" -f ($missing -join '; '))
    }
    return $true
}

# ---------------------------------------------------------------------------
# The stamp
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Read <pcp>\aefos-ide.json -- what the install recorded about the tree it built
    against. Never throws: a missing or corrupt stamp is a FINDING, not a crash.
.DESCRIPTION
    Schema 1 (the first isolated installs) has no lazarusExeSize / lazarusExeMtimeUtc,
    so "he rebuilt his own IDE" cannot be answered for those installs. That is
    reported as an unanswered comparison, never as a clean bill of health: a detector
    that says "no drift" when it simply could not look is worse than no detector.
#>
function Get-AefosIdeStamp {
    param([Parameter(Mandatory = $true)][string]$Pcp)

    $path = Join-Path $Pcp $Script:AefosDriftStampName
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Ok = $false; Path = $path; Data = $null; Schema = 0; Problem = 'no stamp file' }
    }
    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ Ok = $false; Path = $path; Data = $null; Schema = 0; Problem = 'not readable JSON' }
    }
    $schema = 0
    if ($null -ne $data.schema) { [void][int]::TryParse([string]$data.schema, [ref]$schema) }
    if ([string]::IsNullOrWhiteSpace([string]$data.lazarusVersion) -or [string]::IsNullOrWhiteSpace([string]$data.lazarusDir)) {
        return [pscustomobject]@{ Ok = $false; Path = $path; Data = $data; Schema = $schema
            Problem = 'the stamp has no lazarusVersion/lazarusDir' }
    }
    return [pscustomobject]@{ Ok = $true; Path = $path; Data = $data; Schema = $schema; Problem = '' }
}

<#
.SYNOPSIS
    The revision TOKEN out of whatever shape a revision came in as.
.DESCRIPTION
    Get-AefosLazarusTreeInfo hands back the raw contents of ide\revision.inc, which
    upstream writes as two lines:

        // Created by Svn2RevisionInc
        const RevisionStr = 'lazarus_4_8';

    Comparing raw text would work, but it would also print two lines of Pascal in a
    user-facing report, and it would call a stamp written by an older engine
    "different" for a formatting reason. So both sides are reduced to the quoted
    token ('lazarus_4_8') before they are compared or shown; a value that carries no
    quoted token is returned trimmed, unchanged.
#>
function Get-AefosIdeRevisionToken {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $m = [Regex]::Match($Raw, "'([^']*)'")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $Raw.Trim()
}

<#
.SYNOPSIS
    Read EnvironmentOptions/Version@Lazarus out of OUR pcp. '' when absent.
#>
function Get-AefosIdeConfigVersionStamp {
    param([Parameter(Mandatory = $true)][string]$Pcp)
    $path = Join-Path $Pcp $Script:AefosDriftEnvFile
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($path)
        $node = $doc.SelectSingleNode('/CONFIG/EnvironmentOptions/Version')
        if ($null -eq $node) { return '' }
        return $node.GetAttribute('Lazarus')
    } catch {
        return ''
    }
}

<#
.SYNOPSIS
    A UTC instant out of a stamp field, on ANY PowerShell and in ANY locale.
.DESCRIPTION
    NOT [DateTime]::Parse([string]$field), and this is not defensive programming -
    that expression silently disabled two of this engine's findings on a whole
    class of machines. Measured, both hosts, same file:

      * Windows PowerShell 5.1: ConvertFrom-Json leaves 'builtUtc' a STRING
        ("2026-07-28T14:21:16Z"), and Parse reads it correctly.
      * PowerShell 7: ConvertFrom-Json deserialises it into a [DateTime] with
        Kind=Utc. Casting that to [string] renders "07/28/2026 14:21:16" - month
        first, no zone - and [DateTime]::Parse of THAT throws in any culture
        where day-first is the rule (pt-BR, en-GB, de-DE, ...).

    The throw was swallowed by a `catch { $null }`, so the timestamp became
    "unknown", 'SelfRebuilt' and 'VersionStampArmed' could never be reported, and
    the version-stamp bomb - the one that makes ide\main.pp DeleteDirectory our
    own <pcp>\bin - went undetected. Silently, and only for pwsh users outside
    en-US. The IDE-drift gate failed 3/3 under pwsh
    and passed under powershell.exe on the same tree, which is how it surfaced.

    So: take the [DateTime] as it is when it already IS one, and parse a string
    with ROUND-TRIP/universal rules against the invariant culture, never the
    user's. Returns $null when the field is absent or unreadable - the caller
    still has to cope with an old schema.
#>
function Get-AefosStampUtc {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = [DateTime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
              [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
    }
    return $null
}

<#
.SYNOPSIS
    A stamp timestamp as the user should READ it: always the ISO-8601 UTC form the
    installer wrote, never the host's rendering of a deserialised [DateTime]
    (which is where "07/28/2026 14:21:16" would come from on pwsh). Falls back to
    the raw text when it cannot be understood, because showing something odd beats
    showing nothing.
#>
function Format-AefosStampUtc {
    param($Value)
    $utc = Get-AefosStampUtc -Value $Value
    if ($null -ne $utc) { return $utc.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    if ($null -eq $Value) { return '' }
    return ([string]$Value)
}

<#
.SYNOPSIS
    Which Lazarus version is COMPILED INTO <pcp>\bin\lazarus.exe, and how we know.
.DESCRIPTION
    This is the value main.pp compares against, so getting it wrong turns the repair
    into the damage. It cannot be read from the PE with any confidence, so it is
    INFERRED, and the inference is reported alongside the answer:

      * our exe is NEWER than the stamp  -> the IDE rebuilt itself after our install
        (Package > Install/Uninstall Packages > Save and rebuild IDE writes into our
        own <pcp>\bin, because that is the TargetDirectory of our build profile).
        A rebuild compiles HIS SOURCES AS THEY ARE NOW, so the exe carries the tree's
        CURRENT version.                                   Source = 'tree (self-rebuilt)'
      * otherwise the exe is the one our installer produced, and it carries the
        version the stamp recorded.                        Source = 'stamp'
      * self-rebuilt but his tree is unreachable           Source = 'unknown'
        -> we refuse to guess, and nothing is healed from a guess.

    The 5-second slack absorbs filesystem timestamp granularity between writing the
    exe and writing the stamp in the same install; it is not a tolerance for drift.
#>
function Get-AefosIdeExeVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Pcp,
        $Stamp,
        [string]$TreeVersion
    )
    $exe = Join-Path (Join-Path $Pcp 'bin') $Script:AefosDriftIdeExeName
    if (-not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{ Version = ''; Source = 'no exe'; SelfRebuilt = $false }
    }
    $stampVersion = ''
    $stampUtc = $null
    if ($null -ne $Stamp -and $Stamp.Ok) {
        $stampVersion = [string]$Stamp.Data.lazarusVersion
        $stampUtc = Get-AefosStampUtc -Value $Stamp.Data.builtUtc
    }
    $exeUtc = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
    $selfRebuilt = $false
    if ($null -ne $stampUtc) { $selfRebuilt = ($exeUtc -gt $stampUtc.AddSeconds(5)) }

    if ($selfRebuilt) {
        if (-not [string]::IsNullOrWhiteSpace($TreeVersion)) {
            return [pscustomobject]@{ Version = $TreeVersion; Source = 'tree (self-rebuilt)'; SelfRebuilt = $true }
        }
        return [pscustomobject]@{ Version = ''; Source = 'unknown (rebuilt outside the installer, and his tree is unreachable)'; SelfRebuilt = $true }
    }
    if (-not [string]::IsNullOrWhiteSpace($stampVersion)) {
        return [pscustomobject]@{ Version = $stampVersion; Source = 'stamp'; SelfRebuilt = $false }
    }
    return [pscustomobject]@{ Version = ''; Source = 'unknown (no usable stamp)'; SelfRebuilt = $false }
}

# ---------------------------------------------------------------------------
# THE DETECTOR
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    One finding. Id is stable and is what the Pascal side will use too.
#>
function New-AefosDriftFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')][string]$Severity,
        [ValidateSet('Rebuild', 'Heal', 'Reinstall', 'Install', 'None')][string]$Action = 'None',
        [string]$Was = '',
        [string]$Now = '',
        [Parameter(Mandatory = $true)][string]$What,
        [string]$Fix = ''
    )
    return [pscustomobject]@{
        Id = $Id; Severity = $Severity; Action = $Action; Was = $Was; Now = $Now; What = $What; Fix = $Fix
    }
}

<#
.SYNOPSIS
    Is the isolated Aefos IDE still in step with the Lazarus it was built against?
    Cheap by construction: a handful of small file reads and stats, no hashing, no
    tree walk. The elapsed time is measured and returned so "cheap enough to run at
    startup" is a number and not a claim.

.PARAMETER Pcp
    The isolated install. Defaults to the production location.

.PARAMETER LazarusDir
    Override the tree to compare against. Normally omitted: the stamp records the
    tree this IDE was built against, and that is the one that matters. Passing a
    different one is how "he moved Lazarus and told us where" is expressed.

.PARAMETER SourceRoot
    Where the payload DLLs can be fetched from ({app}), used only to say whether a
    missing runtime DLL is healable right now.

.OUTPUTS
    Status : Ok | Repairable | Stale | Broken | NotInstalled
      Ok           nothing to do.
      Repairable   only things we can put right ourselves, on our own side, in
                   milliseconds (the version stamp bomb, a missing runtime DLL, our
                   binary looking older than his).
      Stale        our binary no longer matches his tree; a rebuild is the answer,
                   and it is an OFFER (F7), never automatic.
      Broken       something a rebuild alone cannot fix: his tree is gone, or our
                   exe is gone.
      NotInstalled there is no isolated IDE here.
#>
function Get-AefosIdeDrift {
    param(
        [string]$Pcp,
        [string]$LazarusDir,
        [string]$SourceRoot
    )
    [void](Test-AefosDriftDependenciesLoaded)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ([string]::IsNullOrWhiteSpace($Pcp)) { $Pcp = Get-AefosIsolatedInstallPcp }
    $Pcp = Get-AefosIsolatedFullPath $Pcp
    $findings = New-Object System.Collections.Generic.List[object]
    $binDir = Join-Path $Pcp 'bin'
    $ourExe = Join-Path $binDir $Script:AefosDriftIdeExeName

    # -- 0. is anything installed at all? -----------------------------------
    $stamp = Get-AefosIdeStamp -Pcp $Pcp
    if ((-not (Test-Path -LiteralPath $ourExe)) -and (-not $stamp.Ok)) {
        $sw.Stop()
        return [pscustomobject]@{
            Status = 'NotInstalled'; Pcp = $Pcp; LazarusDir = ''; Stamp = $stamp; Tree = $null
            ExeVersion = $null; Findings = @(); ElapsedMs = $sw.Elapsed.TotalMilliseconds
        }
    }
    if (-not (Test-Path -LiteralPath $ourExe)) {
        [void]$findings.Add((New-AefosDriftFinding -Id 'IdeMissing' -Severity 'Critical' -Action 'Rebuild' `
            -What "the Aefos IDE binary is gone from $ourExe" `
            -Fix 'rebuild it, or reinstall Aefos AI for Lazarus'))
    }
    if (-not $stamp.Ok) {
        # An install with no readable stamp cannot answer ANY of the questions below.
        # Rebuilding through our own engine is what puts one back.
        [void]$findings.Add((New-AefosDriftFinding -Id 'StampMissing' -Severity 'High' -Action 'Rebuild' `
            -What ("this install carries no usable build stamp ({0}), so it cannot be told whether your Lazarus moved on" -f $stamp.Problem) `
            -Fix 'rebuild the Aefos IDE once; the rebuild writes the stamp'))
    }

    # -- 1. his tree: there, and what is in it now? -------------------------
    $treeDir = $LazarusDir
    if ([string]::IsNullOrWhiteSpace($treeDir) -and $stamp.Ok) { $treeDir = [string]$stamp.Data.lazarusDir }
    $tree = $null
    $treeProblem = ''
    if ([string]::IsNullOrWhiteSpace($treeDir)) {
        $treeProblem = 'no Lazarus directory is recorded and none was given'
    } else {
        try { $tree = Get-AefosLazarusTreeInfo -LazarusDir $treeDir } catch { $treeProblem = $_.Exception.Message }
    }
    if ($null -eq $tree) {
        [void]$findings.Add((New-AefosDriftFinding -Id 'TreeMissing' -Severity 'Critical' -Action 'Reinstall' `
            -Was $treeDir -Now '(not there)' `
            -What ("the Lazarus this IDE was built against is not usable any more: {0}" -f $treeProblem) `
            -Fix 'the Aefos IDE still starts, but it cannot compile: it needs his sources, his LCL and his FPC. Reinstall Lazarus at that path, or run the reconciler with -LazarusDir <new location> to rebuild against it'))
    }

    # -- 2. version / revision / FPC ----------------------------------------
    $exeVer = Get-AefosIdeExeVersion -Pcp $Pcp -Stamp $stamp -TreeVersion $(if ($null -ne $tree) { $tree.Version } else { '' })
    if ($exeVer.SelfRebuilt) {
        [void]$findings.Add((New-AefosDriftFinding -Id 'SelfRebuilt' -Severity 'Info' -Action 'None' `
            -Was (Format-AefosStampUtc -Value $(if ($stamp.Ok) { $stamp.Data.builtUtc } else { $null })) `
            -Now ((Get-Item -LiteralPath $ourExe).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')) `
            -What 'the Aefos IDE binary is newer than the stamp: it was rebuilt from inside the IDE, not by the installer' `
            -Fix 'nothing to do by itself -- but it is why the version stamp below is judged against your tree instead of against the stamp'))
    }

    if (($null -ne $tree) -and $stamp.Ok) {
        if ([string]$stamp.Data.lazarusVersion -ne $tree.Version) {
            [void]$findings.Add((New-AefosDriftFinding -Id 'LazarusVersion' -Severity 'High' -Action 'Rebuild' `
                -Was ([string]$stamp.Data.lazarusVersion) -Now $tree.Version `
                -What 'your Lazarus was updated to a different version. The Aefos IDE is still the binary linked against the old one: it opens, but it reads sources that no longer match what is inside it, and compiling a package from inside it can fail on unit version mismatches' `
                -Fix 'rebuild the Aefos IDE against your current Lazarus'))
        }
        elseif ((-not [string]::IsNullOrWhiteSpace((Get-AefosIdeRevisionToken ([string]$stamp.Data.lazarusRevision)))) -and
                (-not [string]::IsNullOrWhiteSpace((Get-AefosIdeRevisionToken $tree.Revision))) -and
                ((Get-AefosIdeRevisionToken ([string]$stamp.Data.lazarusRevision)) -ne (Get-AefosIdeRevisionToken $tree.Revision))) {
            # Same version, different revision: a fixes-branch update or a source
            # refresh. Milder, but it is still a different source tree than the one
            # inside our binary.
            [void]$findings.Add((New-AefosDriftFinding -Id 'LazarusRevision' -Severity 'Medium' -Action 'Rebuild' `
                -Was (Get-AefosIdeRevisionToken ([string]$stamp.Data.lazarusRevision)) -Now (Get-AefosIdeRevisionToken $tree.Revision) `
                -What 'your Lazarus sources changed revision without changing version number' `
                -Fix 'rebuild the Aefos IDE when convenient'))
        }
        if ((-not [string]::IsNullOrWhiteSpace([string]$stamp.Data.fpcVersion)) -and
            ([string]$stamp.Data.fpcVersion -ne $tree.FpcVersion)) {
            [void]$findings.Add((New-AefosDriftFinding -Id 'FpcVersion' -Severity 'High' -Action 'Rebuild' `
                -Was ([string]$stamp.Data.fpcVersion) -Now $tree.FpcVersion `
                -What 'the FPC that ships with your Lazarus changed. The compiled units the Aefos IDE keeps in <pcp>\bin\units are for the previous compiler, so anything that recompiles the IDE will have to start over' `
                -Fix 'rebuild the Aefos IDE against your current Lazarus'))
        }
        if (-not (Test-AefosIsolatedSamePath ([string]$stamp.Data.lazarusDir) $tree.LazarusDir)) {
            [void]$findings.Add((New-AefosDriftFinding -Id 'TreeMoved' -Severity 'High' -Action 'Rebuild' `
                -Was ([string]$stamp.Data.lazarusDir) -Now $tree.LazarusDir `
                -What 'the Aefos IDE is being compared against a Lazarus at a different path than the one it was built against' `
                -Fix 'rebuild so the recorded LazarusDirectory and the real one agree'))
        }
    }

    # -- 3. did HE rebuild his own IDE? -------------------------------------
    # Size + mtime of his lazarus.exe, never a hash: hashing a 21 MB file at every
    # IDE startup is exactly the kind of cost that gets a startup check deleted.
    if (($null -ne $tree) -and $stamp.Ok) {
        if ($stamp.Schema -lt 2 -or ($null -eq $stamp.Data.lazarusExeSize)) {
            [void]$findings.Add((New-AefosDriftFinding -Id 'HisIdeRebuiltUnknown' -Severity 'Info' -Action 'None' `
                -What 'whether you rebuilt your own Lazarus IDE cannot be told: this install predates the stamp field that records it' `
                -Fix 'it will be answerable after the next rebuild of the Aefos IDE'))
        } else {
            $hisExe = Join-Path $tree.LazarusDir $Script:AefosDriftIdeExeName
            if (Test-Path -LiteralPath $hisExe) {
                $his = Get-Item -LiteralPath $hisExe
                $wasSize = 0
                [void][int64]::TryParse([string]$stamp.Data.lazarusExeSize, [ref]$wasSize)
                # Same host/locale trap as builtUtc, and here it degrades the check
                # instead of killing it: with $wasUtc lost, a rebuild of his IDE that
                # happens to produce the same byte count stops being noticed at all.
                $wasUtc = Get-AefosStampUtc -Value $stamp.Data.lazarusExeMtimeUtc
                $changed = ($wasSize -ne $his.Length)
                if ((-not $changed) -and ($null -ne $wasUtc)) {
                    $changed = ([Math]::Abs(($his.LastWriteTimeUtc - $wasUtc).TotalSeconds) -gt 2)
                }
                if ($changed) {
                    [void]$findings.Add((New-AefosDriftFinding -Id 'HisIdeRebuilt' -Severity 'Low' -Action 'None' `
                        -Was ("{0} bytes @ {1}" -f $wasSize, $(if ($null -ne $wasUtc) { $wasUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '?' })) `
                        -Now ("{0} bytes @ {1}" -f $his.Length, $his.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')) `
                        -What 'you rebuilt your own Lazarus IDE. That does not affect the Aefos IDE binary -- the two are independent -- but the packages you installed into your own IDE are not in this one' `
                        -Fix 'nothing is required; rebuild the Aefos IDE if you want the same package list in both'))
                }
            }
        }
    }

    # -- 4. the startlazarus "Which Lazarus should be started?" trap --------
    # ide\lazarusmanager.pas:328-360: startlazarus compares <pcp>\bin\lazarus.exe
    # (ours) with <lazdir>\lazarus.exe (his) and starts the NEWER one, and asks when
    # it cannot decide. TMainIDE.DoRestart (main.pp:7786-7791) launches HIS
    # startlazarus, so this is on the "restart after installing a package" path
    # INSIDE our IDE.
    if ($null -ne $tree) {
        $hisExe = Join-Path $tree.LazarusDir $Script:AefosDriftIdeExeName
        if ((Test-Path -LiteralPath $hisExe) -and (Test-Path -LiteralPath $ourExe)) {
            $hisUtc = (Get-Item -LiteralPath $hisExe).LastWriteTimeUtc
            $ourUtc = (Get-Item -LiteralPath $ourExe).LastWriteTimeUtc
            if ($hisUtc -gt $ourUtc) {
                [void]$findings.Add((New-AefosDriftFinding -Id 'OurExeOlderThanHis' -Severity 'Medium' -Action 'Heal' `
                    -Was $ourUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') -Now $hisUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') `
                    -What 'your own lazarus.exe is newer than the Aefos one. When the Aefos IDE restarts itself after installing a package it goes through YOUR startlazarus, which starts whichever exe is newer -- so it could bring up your IDE instead of this one, or ask which to start' `
                    -Fix 'no rebuild needed: the reconciler marks the Aefos binary as the newer one'))
            }
        }
    }

    # -- 5. THE BOMB: our config stamp vs the version inside our exe --------
    $cfgVer = Get-AefosIdeConfigVersionStamp -Pcp $Pcp
    if ((-not [string]::IsNullOrWhiteSpace($exeVer.Version)) -and (-not [string]::IsNullOrWhiteSpace($cfgVer)) -and
        ($cfgVer -ne $exeVer.Version)) {
        [void]$findings.Add((New-AefosDriftFinding -Id 'VersionStampArmed' -Severity 'High' -Action 'Heal' `
            -Was $cfgVer -Now $exeVer.Version `
            -What ("the next start of the Aefos IDE would show an Upgrade/Downgrade prompt and then DELETE <pcp>\bin and <pcp>\units (ide\main.pp:1373-1378). Its config says Lazarus {0}, the binary is {1} (known from the {2}). Neither answer in that prompt is safe: confirming runs the delete, aborting closes the IDE" -f $cfgVer, $exeVer.Version, $exeVer.Source) `
            -Fix 'the reconciler puts the two back in step and clears the stale unit cache itself -- no prompt, nothing of ours deleted'))
    }
    elseif ((-not [string]::IsNullOrWhiteSpace($cfgVer)) -and [string]::IsNullOrWhiteSpace($exeVer.Version)) {
        [void]$findings.Add((New-AefosDriftFinding -Id 'VersionStampUnknown' -Severity 'Medium' -Action 'Rebuild' `
            -Was $cfgVer -Now '(unknown)' `
            -What ("the version compiled into the Aefos IDE cannot be established ({0}), so it cannot be told whether the next start would delete <pcp>\bin" -f $exeVer.Source) `
            -Fix 'rebuild the Aefos IDE: a build we performed always leaves the two in step'))
    }

    # -- 6. our own runtime payload still there? ----------------------------
    # After the delete above has run once, or after antivirus quarantine, the exe
    # starts and the chat or the terminal fail with no visible cause. Cheap to check,
    # cheap to heal, and invisible if we do not look.
    $dllNames = @()
    foreach ($dll in (Get-AefosIsolatedPayloadDlls -SourceRoot $(if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $Pcp } else { $SourceRoot }))) {
        $dllNames += $dll.Name
    }
    $missingDlls = @()
    if (Test-Path -LiteralPath $binDir) {
        foreach ($name in $dllNames) {
            if (-not (Test-Path -LiteralPath (Join-Path $binDir $name))) { $missingDlls += $name }
        }
    }
    if ($missingDlls.Count -gt 0) {
        [void]$findings.Add((New-AefosDriftFinding -Id 'MissingRuntime' -Severity 'High' -Action 'Heal' `
            -Was ($dllNames -join ', ') -Now (($dllNames | Where-Object { $missingDlls -notcontains $_ }) -join ', ') `
            -What ("{0} runtime file(s) are missing from the Aefos IDE folder: {1}. WebView2Loader is the chat, libvterm is the terminal, sqlite3 is the session store -- each one goes silent, not loud" -f $missingDlls.Count, ($missingDlls -join ', ')) `
            -Fix 'the reconciler copies them back from the installed payload'))
    }

    # -- 7. his package list vs what we imported ----------------------------
    # Read from HIS pcp, which we only ever read. The comparison is against what the
    # install RECORDED importing, so it answers "he changed his IDE since", not
    # "the import failed" (that one is the install's own report).
    if ($stamp.Ok -and (-not [string]::IsNullOrWhiteSpace([string]$stamp.Data.userPcp))) {
        $hisPcp = [string]$stamp.Data.userPcp
        if (Test-Path -LiteralPath $hisPcp) {
            $hisList = Get-AefosUserInstallList -UserPcp $hisPcp
            $known = @()
            foreach ($n in @($stamp.Data.imported)) { if ($n) { $known += [string]$n } }
            foreach ($n in @($stamp.Data.leftOut))  { if ($n) { $known += [string]$n } }
            $added   = @(@($hisList.Names) | Where-Object { $known -notcontains $_ })
            $removed = @($known | Where-Object { @($hisList.Names) -notcontains $_ })
            if ($added.Count -gt 0) {
                [void]$findings.Add((New-AefosDriftFinding -Id 'PackagesAdded' -Severity 'Medium' -Action 'Rebuild' `
                    -Now ($added -join ', ') `
                    -What ("you installed {0} package(s) into your own Lazarus that the Aefos IDE does not have: {1}. The two IDEs keep separate package lists on purpose -- neither can change the other" -f $added.Count, ($added -join ', ')) `
                    -Fix 'rebuild the Aefos IDE to bring them across'))
            }
            if ($removed.Count -gt 0) {
                [void]$findings.Add((New-AefosDriftFinding -Id 'PackagesRemoved' -Severity 'Low' -Action 'None' `
                    -Was ($removed -join ', ') `
                    -What ("{0} package(s) that were in your Lazarus when the Aefos IDE was built are not in your install list any more: {1}" -f $removed.Count, ($removed -join ', ')) `
                    -Fix 'nothing is required; the next rebuild of the Aefos IDE will follow your current list'))
            }
        }
    }

    # STATUS, by precedence, and the order says what the user has to DO:
    #   Broken     something a rebuild cannot fix (his tree is gone, our exe is gone).
    #   Stale      a rebuild is the answer, and it is an offer, never automatic.
    #   Repairable only things we can put right ourselves in milliseconds.
    #   Ok         nothing.
    # Repairable ranks BELOW Stale on purpose: the repairs happen either way, so when
    # both are present the only thing still needing a decision is the rebuild, and
    # that is what the headline should say.
    $sw.Stop()
    $status = 'Ok'
    if (@($findings | Where-Object { $_.Action -eq 'Heal' }).Count -gt 0) { $status = 'Repairable' }
    if (@($findings | Where-Object { $_.Action -eq 'Rebuild' }).Count -gt 0) { $status = 'Stale' }
    if (@($findings | Where-Object { $_.Severity -eq 'Critical' }).Count -gt 0) { $status = 'Broken' }

    return [pscustomobject]@{
        Status     = $status
        Pcp        = $Pcp
        LazarusDir = $(if ($null -ne $tree) { $tree.LazarusDir } else { $treeDir })
        Stamp      = $stamp
        Tree       = $tree
        ExeVersion = $exeVer
        ConfigVersion = $cfgVer
        # NO leading comma: this is a hashtable VALUE, not a pipeline return. The
        # ",$array" idiom exists to stop the pipeline unrolling an empty array on the
        # way out of a function; in a property assignment nothing unrolls, so the
        # comma just NESTS it -- and an empty result then reads as one blank finding.
        Findings   = $findings.ToArray()
        ElapsedMs  = $sw.Elapsed.TotalMilliseconds
    }
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Print a drift result the way the user should read it: what changed on HIS side,
    what it costs HIM, and what the one action is. No jargon, no file paths where a
    sentence works.
#>
function Write-AefosIdeDriftReport {
    param([Parameter(Mandatory = $true)]$Drift)

    Write-Host ("Aefos IDE      : {0}" -f (Join-Path (Join-Path $Drift.Pcp 'bin') $Script:AefosDriftIdeExeName))
    Write-Host ("your Lazarus   : {0}" -f $(if ($Drift.LazarusDir) { $Drift.LazarusDir } else { '(unknown)' }))
    if ($Drift.Stamp.Ok) {
        $stampRev = Get-AefosIdeRevisionToken ([string]$Drift.Stamp.Data.lazarusRevision)
        Write-Host ("built against  : Lazarus {0}{1}, FPC {2}, on {3}" -f `
            [string]$Drift.Stamp.Data.lazarusVersion,
            $(if ($stampRev) { ' (' + $stampRev + ')' } else { '' }),
            [string]$Drift.Stamp.Data.fpcVersion, (Format-AefosStampUtc -Value $Drift.Stamp.Data.builtUtc))
    }
    if ($null -ne $Drift.Tree) {
        $treeRev = Get-AefosIdeRevisionToken $Drift.Tree.Revision
        Write-Host ("your tree now  : Lazarus {0}{1}, FPC {2}" -f `
            $Drift.Tree.Version,
            $(if ($treeRev) { ' (' + $treeRev + ')' } else { '' }),
            $Drift.Tree.FpcVersion)
    }
    Write-Host ("checked in     : {0:N1} ms" -f $Drift.ElapsedMs)
    Write-Host ''
    if (@($Drift.Findings).Count -eq 0) {
        Write-Host 'Nothing changed: the Aefos IDE matches the Lazarus it was built against.' -ForegroundColor Green
        return
    }
    foreach ($f in @($Drift.Findings)) {
        $colour = 'Yellow'
        if ($f.Severity -eq 'Critical') { $colour = 'Red' }
        elseif ($f.Severity -eq 'High') { $colour = 'Red' }
        elseif ($f.Severity -in @('Low', 'Info')) { $colour = 'DarkGray' }
        Write-Host ("  [{0,-8}] {1,-22} {2}" -f $f.Severity, $f.Id, $f.What) -ForegroundColor $colour
        if ($f.Was -or $f.Now) {
            Write-Host ("             was: {0}   now: {1}" -f $(if ($f.Was) { $f.Was } else { '-' }), $(if ($f.Now) { $f.Now } else { '-' })) -ForegroundColor DarkGray
        }
        if ($f.Fix) { Write-Host ("             -> {0}" -f $f.Fix) -ForegroundColor DarkGray }
    }
}
