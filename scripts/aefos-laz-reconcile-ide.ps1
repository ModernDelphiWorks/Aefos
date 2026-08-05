<#
.SYNOPSIS
    MILESTONE 2 / SLICE F7 -- RECONCILE the isolated Aefos IDE with the Lazarus the
    user has TODAY. Reports the drift (slice F6), repairs by hand only what is ours
    and invisible, and rebuilds only when asked.

.DESCRIPTION
    THE POLICY, DECIDED AND OWNED
    -----------------------------
    Three tiers, and which tier a finding belongs to is the whole design:

      AUTO      Things that are ENTIRELY on our side, cost milliseconds, and whose
                absence breaks the product silently. Applied without asking:
                  * the version stamp of OUR config put back in step with OUR exe,
                    so the next start cannot show an Upgrade/Downgrade prompt and
                    delete <pcp>\bin (ide\main.pp:1373-1378),
                  * runtime DLLs copied back beside our exe when one is missing
                    (chat, terminal and session store fail silently without them),
                  * our exe marked as the newer of the two binaries, so his
                    startlazarus cannot bring up his IDE instead of ours or ask
                    which one to start (ide\lazarusmanager.pas:328-360).
                None of these touches his tree, his config or the shared brain, and
                none of them changes a decision he made.

      OFFER     A REBUILD. Never automatic. Reasons, in order of how much they cost
                to get wrong: a rebuild takes 65 s cold / 10 s incremental (measured
                in F0) and lands on the exact moment he opened the IDE to work; it
                can FAIL, because it compiles HIS component packages and one of them
                may have gone bad since -- and a failed automatic rebuild would leave
                him with no working IDE from an event he never asked about; and our
                exe is LOCKED while the IDE is running, so a rebuild started from
                inside implies a restart cycle. He is told, in one non-modal line,
                what changed and what it costs. He clicks or he does not.

      REFUSE    His Lazarus is gone. We do not rebuild, we do not guess a new
                location, and we say exactly what we cannot do and why. Guessing a
                tree here is how an installer picks the wrong Lazarus and builds an
                IDE against sources the user does not use.

    AND THE RULE THAT OUTRANKS THE POLICY: NOTHING IS EVER WRITTEN ON HIS SIDE --
    not his tree, not his config, not even to ADD. Reconciling is not a licence.
    Every repair below writes inside <pcp> and nowhere else, through
    Write-AefosSeedFile / Copy-AefosIsolatedPayload, which REFUSE a destination
    outside it. The rebuild path delegates to the install engine, which carries the
    same containment and is proven by the round-trip gate to leave his side byte
    for byte as it was.

    WHY A REBUILD IS DELEGATED AND NOT REIMPLEMENTED
    -----------------------------------------------
    Reconciling and installing are the same operation: seed the pcp (which is what
    re-derives the version stamp from HIS tree and therefore disarms the bomb),
    build, stage the DLLs, prove the exe starts, stamp what it was built against.
    Writing a second, slightly different version of that here is how an installer and
    a repair tool drift apart until only one of them is correct. So -Rebuild runs
    scripts\aefos-laz-install-isolated.ps1. One engine, one behaviour, one gate.

    THE ORDER OF OPERATIONS THAT MATTERS
    ------------------------------------
    Heal BEFORE rebuilding, and detect again AFTER. The rebuild is the step that can
    ARM the version bomb (a new exe against a config the old exe wrote), so a run
    that ends without re-checking would be the one that leaves it armed. The final
    check is not decoration: it is the proof that the reconcile converged.

.PARAMETER TargetPcp
    The isolated install. Default %LOCALAPPDATA%\Aefos\lazarus.

.PARAMETER LazarusDir
    Compare against (and, with -Rebuild, build against) THIS tree instead of the one
    the stamp recorded. This is how "I moved my Lazarus" is answered, and it is
    always the user saying where it went -- never a guess of ours.

.PARAMETER SourceRoot
    The payload root ({app} under Inno, the repo in a checkout). Needed to copy a
    missing runtime DLL back and to rebuild.

.PARAMETER Heal
    Apply the AUTO tier. Without it this script only reports.

.PARAMETER Rebuild
    Heal, then rebuild through the install engine, then re-check.

.PARAMETER NoImport
    Passed through to the rebuild: do not bring his component packages across.

.OUTPUTS
    Exit codes, meant to be read by a caller and not just by a human:
      0   in step (or everything that was wrong got healed)
      1   the rebuild was attempted and failed
      2   nothing is installed here / arguments make no sense
      3   refused: the Aefos IDE is running, so its files cannot be replaced
      10  STALE -- a rebuild is what fixes this, and it was not requested
      11  BROKEN -- his Lazarus (or our binary) is not usable; a rebuild is impossible
          or did not converge
      12  REPAIRABLE -- repairs are pending and -Heal was not passed

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\aefos-laz-reconcile-ide.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\aefos-laz-reconcile-ide.ps1 -Rebuild
#>

[CmdletBinding()]
param(
    [string]$TargetPcp,
    [string]$LazarusDir,
    [string]$SourceRoot,
    [switch]$Heal,
    [switch]$Rebuild,
    [switch]$NoImport
)

$ErrorActionPreference = 'Stop'

# -- arguments into locals, BEFORE any dot-source ---------------------------
# aefos-laz-seed-pcp.ps1 and aefos-laz-import-components.ps1 both carry a param()
# block declaring $LazarusDir / $TargetPcp / $UserPcp / $NoImport. Dot-sourcing runs
# those blocks IN THIS SCOPE and would blank our own bound parameters. Copy first,
# then load -- the same order the install engine documents at its own dot-source.
$RunTargetPcp  = $TargetPcp
$RunLazarusDir = $LazarusDir
$RunSourceRoot = $SourceRoot
$RunHeal       = $Heal.IsPresent
$RunRebuild    = $Rebuild.IsPresent
$RunNoImport   = $NoImport.IsPresent

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot  = Split-Path -Parent $ScriptDir

foreach ($lib in @('aefos-laz-isolated-layout.ps1', 'aefos-laz-seed-pcp.ps1',
                   'aefos-laz-import-components.ps1', 'aefos-laz-ide-drift.ps1')) {
    $libPath = Join-Path $ScriptDir $lib
    if (-not (Test-Path -LiteralPath $libPath)) { throw "Required engine not found: '$libPath'." }
    . $libPath
}

function Write-Head($m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host $m -ForegroundColor Green }
function Write-Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Write-Bad($m)  { Write-Host $m -ForegroundColor Red }

$Script:Did = New-Object System.Collections.Generic.List[string]
function Add-Did {
    param([string]$Text)
    [void]$Script:Did.Add($Text)
    Write-Host ("HEALED: {0}" -f $Text) -ForegroundColor Green
}

<#
.SYNOPSIS
    Is the isolated IDE running? Probe the FILE, not a window class: Windows locks a
    running image against writes, and 'TApplication' is the window class of every
    LCL app including an Inno setup -- a class probe once trapped a user in an
    unclosable Retry loop.
#>
function Test-AefosReconcileIdeRunning {
    param([string]$IdeExe)
    if (-not (Test-Path -LiteralPath $IdeExe)) { return $false }
    try {
        $stream = [System.IO.File]::Open($IdeExe, 'Open', 'Write', 'None')
        $stream.Dispose()
        return $false
    } catch [System.IO.IOException] {
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    THE AUTO TIER. Applies the repairs that are ours, cheap and invisible, and
    returns what it did. Everything it writes is inside $Pcp, through the guarded
    writers, so containment does not depend on this function being careful.
.DESCRIPTION
    VersionStampArmed is the interesting one. Upstream's own reaction to a version
    mismatch is: prompt, then delete <pcp>\bin and <pcp>\units. The INTENT behind
    that delete is to drop a stale ppu cache; the COLLATERAL is that <pcp>\bin is
    where our IDE lives. So we do the intent and skip the collateral: remove
    <pcp>\units ourselves (nothing of ours is ever kept there -- our units are in
    <pcp>\bin\units, which survives only because the locked exe sorts before it and
    stops the delete loop), then put the config stamp in step so the prompt never
    happens. F0 measured the alternative: with a wrong stamp, <pcp>\units was
    removed entirely and every file in <pcp>\bin sorting before lazarus.exe died.
#>
function Repair-AefosIsolatedIde {
    param(
        [Parameter(Mandatory = $true)][string]$Pcp,
        [Parameter(Mandatory = $true)]$Drift,
        [string]$SourceRoot
    )
    $binDir = Join-Path $Pcp 'bin'
    $ourExe = Join-Path $binDir 'lazarus.exe'
    $healed = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    foreach ($f in @($Drift.Findings | Where-Object { $_.Action -eq 'Heal' })) {
        switch ($f.Id) {

            'VersionStampArmed' {
                $target = $Drift.ExeVersion.Version
                if ([string]::IsNullOrWhiteSpace($target)) {
                    [void]$failed.Add('VersionStampArmed: the version inside our exe could not be established, and a guessed stamp is exactly what causes the delete')
                    break
                }
                # The stale unit cache upstream wanted gone. Ours, inside our install.
                $units = Join-Path $Pcp 'units'
                if (Test-Path -LiteralPath $units) {
                    Remove-Item -LiteralPath $units -Recurse -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path -LiteralPath $units)) {
                        [void]$healed.Add('cleared the stale <pcp>\units cache (what the IDE wanted, without deleting <pcp>\bin with it)')
                    }
                }
                $envPath = Join-Path $Pcp 'environmentoptions.xml'
                $doc = New-AefosSeedXmlDocument -SeedFrom $envPath -RootName 'CONFIG'
                $envNode = Get-AefosSeedXmlChild -Parent $doc.DocumentElement -Name 'EnvironmentOptions'
                [void](Set-AefosSeedXmlValue -Parent $envNode -ElementName 'Version' -AttributeName 'Lazarus' -Value $target)
                Write-AefosSeedFile -Root $Pcp -Path $envPath -Content (ConvertTo-AefosSeedXmlText -Doc $doc)
                [void]$healed.Add(("put the config version stamp back in step: Version@Lazarus '{0}' -> '{1}' (the version inside our exe, known from the {2}). The Upgrade/Downgrade prompt that deletes <pcp>\bin cannot happen now" -f `
                    $Drift.ConfigVersion, $target, $Drift.ExeVersion.Source))
            }

            'MissingRuntime' {
                if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
                    [void]$failed.Add('MissingRuntime: no payload root to copy from (pass -SourceRoot)')
                    break
                }
                foreach ($dll in (Get-AefosIsolatedPayloadDlls -SourceRoot $SourceRoot)) {
                    $dest = Join-Path $binDir $dll.Name
                    if (Test-Path -LiteralPath $dest) { continue }
                    $src = ''
                    foreach ($candidate in $dll.Candidates) {
                        if (Test-Path -LiteralPath $candidate) { $src = $candidate; break }
                    }
                    if ([string]::IsNullOrWhiteSpace($src)) {
                        [void]$failed.Add(("MissingRuntime: {0} is not in the payload either ({1}) -- {2}" -f $dll.Name, $SourceRoot, $dll.Why))
                        continue
                    }
                    # Copy-AefosIsolatedPayload re-checks the <pcp>\bin sort-order rule
                    # before writing, so a repair cannot introduce the very file the
                    # IDE would destroy on the next mismatch.
                    Copy-AefosIsolatedPayload -Root $Pcp -Source $src -Destination $dest
                    [void]$healed.Add(("restored {0} beside the Aefos IDE -- {1}" -f $dll.Name, $dll.Why))
                }
            }

            'OurExeOlderThanHis' {
                if (-not (Test-Path -LiteralPath $ourExe)) {
                    [void]$failed.Add('OurExeOlderThanHis: there is no Aefos IDE binary to mark')
                    break
                }
                try {
                    # Timestamp only: not one byte of the binary changes. It is what
                    # startlazarus compares (lazarusmanager.pas:328-340), and making
                    # ours the newer one is the whole fix.
                    (Get-Item -LiteralPath $ourExe).LastWriteTime = (Get-Date)
                    [void]$healed.Add('marked the Aefos IDE binary as the newer of the two, so a restart after installing a package cannot open your IDE instead of this one')
                } catch {
                    [void]$failed.Add(("OurExeOlderThanHis: could not restamp '{0}': {1}" -f $ourExe, $_.Exception.Message))
                }
            }
        }
    }
    # No leading comma on either: these are hashtable VALUES. ",$array" is the idiom
    # for a pipeline RETURN; in a property assignment it only nests, and an empty
    # result then prints as one blank repair (and formats "{0}" with no argument).
    return [pscustomobject]@{ Healed = $healed.ToArray(); Failed = $failed.ToArray() }
}

# ===========================================================================
# 1. WHERE, AND IS ANYTHING THERE
# ===========================================================================
Write-Host '=================================================================='
Write-Host ' Aefos AI - Lazarus edition - RECONCILE the isolated IDE'
Write-Host '=================================================================='

if ([string]::IsNullOrWhiteSpace($RunTargetPcp))  { $RunTargetPcp = Get-AefosIsolatedInstallPcp }
if ([string]::IsNullOrWhiteSpace($RunSourceRoot)) { $RunSourceRoot = $RepoRoot }
$Pcp    = Get-AefosIsolatedFullPath $RunTargetPcp
$BinDir = Join-Path $Pcp 'bin'
$IdeExe = Join-Path $BinDir 'lazarus.exe'

Write-Head '-- 1. What changed on your side --'
$Drift = Get-AefosIdeDrift -Pcp $Pcp -LazarusDir $RunLazarusDir -SourceRoot $RunSourceRoot
Write-AefosIdeDriftReport -Drift $Drift

if ($Drift.Status -eq 'NotInstalled') {
    Write-Warn 'There is no isolated Aefos IDE here, so there is nothing to reconcile.'
    Write-Host ("  looked in: {0}" -f $Pcp)
    exit 2
}

# ===========================================================================
# 2. THE AUTO TIER
# ===========================================================================
$HealResult = $null
if ($RunHeal -or $RunRebuild) {
    Write-Head '-- 2. Repairing what is ours (nothing on your side is touched) --'
    if (Test-AefosReconcileIdeRunning -IdeExe $IdeExe) {
        Write-Bad 'The Aefos IDE is RUNNING. Close it and run this again -- its files cannot be replaced while it holds them.'
        exit 3
    }
    $HealResult = Repair-AefosIsolatedIde -Pcp $Pcp -Drift $Drift -SourceRoot $RunSourceRoot
    foreach ($h in @($HealResult.Healed)) { Add-Did $h }
    foreach ($x in @($HealResult.Failed)) { Write-Bad ("COULD NOT HEAL: {0}" -f $x) }
    if (@($HealResult.Healed).Count -eq 0 -and @($HealResult.Failed).Count -eq 0) {
        Write-Ok 'Nothing needed repairing.'
    }
} elseif (@($Drift.Findings | Where-Object { $_.Action -eq 'Heal' }).Count -gt 0) {
    Write-Head '-- 2. Repairs available --'
    Write-Warn 'This run only REPORTS. Re-run with -Heal to apply the repairs listed above.'
}

# ===========================================================================
# 3. THE OFFER: a rebuild, and only when asked
# ===========================================================================
$NeedsRebuild = @($Drift.Findings | Where-Object { $_.Action -eq 'Rebuild' })
$TreeGone     = @($Drift.Findings | Where-Object { $_.Id -eq 'TreeMissing' })

if ($TreeGone.Count -gt 0) {
    Write-Head '-- 3. Your Lazarus is not where it was --'
    Write-Bad ("The Aefos IDE was built against '{0}', and there is no usable Lazarus there now." -f $Drift.LazarusDir)
    Write-Host ''
    Write-Host '  What still works : the Aefos IDE starts. Editing, the chat and the terminal do not need his tree.'
    Write-Host '  What does not    : compiling anything. The compiler, the LCL, the sources and the'
    Write-Host '                     translations all live in that folder -- they were never copied here.'
    Write-Host ''
    Write-Host '  Your options, in the order they cost you least:'
    Write-Host '    1. Reinstall Lazarus at the same path, and everything works again with no rebuild.'
    Write-Host '    2. Moved it? Run this again with -LazarusDir "<new folder>" -Rebuild.'
    Write-Host '    3. Uninstalled Lazarus for good? Uninstall Aefos AI for Lazarus too -- it is one'
    Write-Host '       directory, and removing it changes nothing else on the machine.'
    if ($RunRebuild) {
        Write-Bad 'REFUSING to rebuild: there is no Lazarus to build against. Nothing was changed.'
    }
    Write-Host ''
    Write-Host '=================================================================='
    exit 11
}

$RebuildExit = 0
if ($RunRebuild) {
    if ($NeedsRebuild.Count -eq 0) {
        Write-Head '-- 3. Rebuild --'
        Write-Warn 'Nothing needed a rebuild, but one was requested. Rebuilding anyway (it is incremental).'
    } else {
        Write-Head '-- 3. Rebuilding the Aefos IDE against your Lazarus --'
        foreach ($f in $NeedsRebuild) { Write-Host ("  because: {0}" -f $f.What) }
    }
    if (Test-AefosReconcileIdeRunning -IdeExe $IdeExe) {
        Write-Bad 'The Aefos IDE is RUNNING. Close it and run this again.'
        exit 3
    }
    $installEngine = Join-Path $ScriptDir 'aefos-laz-install-isolated.ps1'
    if (-not (Test-Path -LiteralPath $installEngine)) { throw "Install engine not found: '$installEngine'." }
    $engineArgs = @('-TargetPcp', $Pcp, '-SourceRoot', $RunSourceRoot)
    $buildTree = $Drift.LazarusDir
    if (-not [string]::IsNullOrWhiteSpace($RunLazarusDir)) { $buildTree = $RunLazarusDir }
    if (-not [string]::IsNullOrWhiteSpace($buildTree)) { $engineArgs += @('-LazarusDir', $buildTree) }
    if ($Drift.Stamp.Ok -and (-not [string]::IsNullOrWhiteSpace([string]$Drift.Stamp.Data.userPcp))) {
        $engineArgs += @('-UserPcp', [string]$Drift.Stamp.Data.userPcp)
    }
    if ($RunNoImport) { $engineArgs += '-NoImport' }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -NoProfile -ExecutionPolicy Bypass -File $installEngine @engineArgs *>&1 | Out-Host
    $RebuildExit = $LASTEXITCODE
    $sw.Stop()
    Write-Host ("rebuild exit={0} in {1:N0}s" -f $RebuildExit, $sw.Elapsed.TotalSeconds)
    if ($RebuildExit -ne 0) {
        Write-Bad 'The rebuild failed. The Aefos IDE you had is still there, and your own Lazarus was not touched.'
        exit 1
    }
}
elseif ($NeedsRebuild.Count -gt 0) {
    Write-Head '-- 3. A rebuild is what fixes the rest --'
    foreach ($f in $NeedsRebuild) { Write-Host ("  * {0}" -f $f.What) }
    Write-Host ''
    Write-Host '  It takes about a minute (much less when little changed), it builds into our own'
    Write-Host '  directory, and your Lazarus is only read. Run this again with -Rebuild when it suits you.'
}

# ===========================================================================
# 4. RE-CHECK -- the proof that the reconcile converged
# ===========================================================================
Write-Head '-- 4. Where things stand now --'
$After = Get-AefosIdeDrift -Pcp $Pcp -LazarusDir $RunLazarusDir -SourceRoot $RunSourceRoot
Write-AefosIdeDriftReport -Drift $After

Write-Host ''
Write-Host '=================================================================='
if (@($Script:Did).Count -gt 0) {
    Write-Host 'REPAIRED:'
    foreach ($d in $Script:Did) { Write-Host ("  - {0}" -f $d) }
}
switch ($After.Status) {
    'Ok'         { Write-Ok 'IN STEP: the Aefos IDE matches the Lazarus you have now.'; exit 0 }
    'Repairable' {
        if ($RunHeal -or $RunRebuild) {
            # Repairs were applied and the re-check still asks for them: the reconcile
            # did not converge, and reporting that as success is how a silent
            # regression ships.
            Write-Bad 'REPAIRS DID NOT STICK: the same repairs are still pending after applying them.'
            exit 11
        }
        Write-Warn 'REPAIRS PENDING: re-run with -Heal to apply them (they are ours, and they take milliseconds).'
        exit 12
    }
    'Stale'   {
        if ($RunRebuild) {
            # A rebuild that exits 0 and leaves the install stale is not a success,
            # and letting it report as one is how a silent regression ships.
            Write-Bad 'STILL STALE after a rebuild that reported success. Something in the reconcile did not converge.'
            exit 1
        }
        Write-Warn 'STALE: a rebuild is what puts this right. Re-run with -Rebuild.'
        exit 10
    }
    'Broken'  {
        # Critical: the Aefos binary is gone, or his Lazarus is unusable. Neither is
        # something the AUTO tier can put back.
        Write-Bad 'BROKEN: see the findings above. This one is not something we can repair on our own.'
        exit 11
    }
    default   { Write-Warn ("Nothing to reconcile ({0})." -f $After.Status); exit 2 }
}
