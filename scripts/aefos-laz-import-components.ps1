<#
.SYNOPSIS
    MILESTONE 2 / SLICE F2 -- bring the USER'S OWN component packages into the
    isolated Aefos Lazarus IDE, without ever writing on his side, and without
    letting one dead .lpk of his cost him a working IDE.

.DESCRIPTION
    THE PRODUCT QUESTION THIS FILE ANSWERS
    --------------------------------------
    An isolated IDE that has none of the user's components (RX, Zeos, VirtualTree,
    Fortes, Indy...) is not usable for work. So the Aefos IDE has to be built with
    HIS install list. But seeding that list RAW is exactly what broke a partner's
    machine on 2026-07-25: `lazbuild --build-ide` aborts the WHOLE rebuild when any
    single package on the list cannot be resolved to an .lpk that exists, and it
    aborts before compiling one line of Aefos.

    What changed, and why importing is acceptable NOW: in the isolated model the
    worst consequence of a rotten .lpk is that OUR build fails in OUR directory.
    His IDE is never opened for writing. Same technical decision, completely
    different blast radius -- plus the two safety nets below.

    THE FOUR RULES THIS ENGINE OBEYS
    --------------------------------
    1. READ-ONLY ON HIS SIDE. His miscellaneousoptions.xml (the install list) and
       his packagefiles.xml (his package links) are READ. Never written, never
       "repaired", not even to ADD. Everything we produce goes through
       Write-AefosSeedFile from scripts\aefos-laz-seed-pcp.ps1, which REFUSES a
       destination outside our own pcp -- containment is a property of the code.
    2. FILTER BEFORE SEEDING. Every name on his list is resolved the way lazbuild
       resolves it (a user package link that still points at a real file, or an
       .lpk shipped inside the Lazarus tree). What does not resolve is left out,
       named, and explained.
    3. AUTOMATIC FALLBACK. If the build fails ANYWAY -- a package that resolves but
       does not compile, a missing dependency, a unit path that only existed on his
       old machine -- the engine re-seeds with the MINIMUM list (Aefos + docking)
       and builds again. The user gets a working IDE either way. Never a dead end.
    4. TELL HIM. <pcp>\import-report.txt names every package that got in, every
       package that did not, WHY, and what he does about each one. Without it the
       fallback is indistinguishable from "Aefos ate my components" (risk R9 of the
       milestone design).

    WHY THE RESOLVER IS RE-IMPLEMENTED AND NOT REUSED
    -------------------------------------------------
    installer\lazarus\aefos-laz-install.ps1:682-699 already has
    Test-AefosPackageResolvable and it is the right logic. It cannot be CALLED from
    here: that file is not a function library, it is a top-to-bottom install script
    -- dot-sourcing it would RUN an install. So the concept is re-implemented, with
    two deliberate differences: this one returns WHICH source resolved the name and
    the exact .lpk path (the caller has to register a link for it), and it reports a
    REASON when it fails (the report is the whole point of the slice).
    The duplication is not left on trust: the installer gates 
    run-import-plan-tests.ps1 lifts the installer's function out of that file by AST
    and asserts BOTH implementations return the same verdict over a fixture matrix.
    If someone changes one, the test fails.

    READING THE INSTALL LIST BY INDEX, NOT BY CHILD NODE
    ----------------------------------------------------
    Lazarus does not walk this XML, it reads it BY INDEX (the same fact that makes
    Set-AefosIndexedList necessary in the installer): Count first, then Item1..ItemN.
    So a file whose Count says 2 while 5 elements sit on disk INSTALLS TWO, and a
    file with a hole at Item2 silently loses everything from Item2 on. This reader
    is index-faithful -- it imports what his IDE actually installs -- and it reports
    the disagreement as an anomaly instead of hiding it. (A Count of 0 with items on
    disk is exactly the damage the 0.21.7 uninstaller left behind.)

.PARAMETER LazarusDir
    The USER's Lazarus tree. READ ONLY.

.PARAMETER TargetPcp
    OUR primary config path. The only place anything is written.

.PARAMETER UserPcp
    The USER's own config directory: the source of the install list and of the
    package links. READ ONLY.

.EXAMPLE
    . .\scripts\aefos-laz-seed-pcp.ps1
    . .\scripts\aefos-laz-import-components.ps1
    $plan = New-AefosComponentImportPlan -LazarusDir C:\lazarus -UserPcp $userPcp

.EXAMPLE
    pwsh -File scripts\aefos-laz-import-components.ps1 -LazarusDir C:\lazarus `
         -TargetPcp $env:LOCALAPPDATA\Aefos\lazarus -UserPcp $env:LOCALAPPDATA\lazarus `
         -AefosLpk .\packages\Lazarus\Aefos.Lazarus.IDE.lpk -RunBuild
#>

[CmdletBinding()]
param(
    [string]$LazarusDir,
    [string]$TargetPcp,
    [string]$UserPcp,
    [string]$AefosLpk,
    [string[]]$ExtraPackageLpk = @(),
    # NOT named -IdeOpts, although that is what the function underneath calls it:
    # dot-sourcing this file RE-RUNS this param() block in the CALLER'S scope, and
    # the F0 probe -- the script that dot-sources it -- has its own -IdeOpts
    # parameter that would be blanked. A file-scope parameter name is part of the
    # dot-source contract, not a local detail.
    [string]$BuildIdeOptions = '-g- -Xs',
    [switch]$NoImport,
    [switch]$NoPkgOutDirRedirect,
    # -RunBuild, not -Build, for the same dot-source reason as -BuildIdeOptions: a
    # caller that dot-sources this file gets a [switch]-CONSTRAINED $Build in its own
    # scope, and its next `$build = <object>` then dies with "Boolean parameters
    # accept only Boolean values". Paid for by the F0 probe on the first Exp3 run.
    [switch]$RunBuild
)

# NOTE: no file-scope $ErrorActionPreference / Set-StrictMode -- this file is
# dot-sourced into other scripts and those settings would leak into the caller.
#
# NOTE 2: this file does NOT dot-source scripts\aefos-laz-seed-pcp.ps1 at file
# scope ON PURPOSE. That script has a param() block declaring $LazarusDir,
# $TargetPcp and $UserPcp, so dot-sourcing it AFTER our own parameters are bound
# would blank them in this very scope. The library path REQUIRES the caller to
# have dot-sourced the seeder already (checked, with a clear message); the
# stand-alone entry point at the bottom copies its arguments into locals BEFORE
# it dot-sources. Same trap the F0 probe documents at its own dot-source site.

$Script:AefosImportReportFile = 'import-report.txt'
$Script:AefosImportLogDir     = 'logs'

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function Test-AefosImportSeederLoaded {
    param([switch]$Throw)
    $ok = $null -ne (Get-Command -Name 'New-AefosIsolatedPcpSeed' -ErrorAction SilentlyContinue)
    if ((-not $ok) -and $Throw) {
        throw "scripts\aefos-laz-seed-pcp.ps1 must be dot-sourced before this engine (it owns the write-containment guard and the version stamp)."
    }
    return $ok
}

function Get-AefosImportXml {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($Path)
        return $doc
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Public: READ the user's side (and nothing else)
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    The user's package links (<pcp>\packagefiles.xml, UserPkgLinks), keyed by
    package name. READ ONLY.
.DESCRIPTION
    Shape per entry: <Item1><Name Value="rxtools"/><Filename Value="..."/></Item1>.
    A name can appear MORE THAN ONCE (dev worktrees, moved checkouts -- the
    installer has seen three dead ones plus a live one for a single package), so
    every entry is kept and a LIVE one wins over a dead one when resolving.
    Read strictly by index, Count first: that is how packagelinks.pas:614-619 reads
    it, so a hole means the tail does not exist as far as the IDE is concerned.
#>
function Get-AefosUserPackageLinks {
    param([Parameter(Mandatory = $true)][string]$UserPcp)

    # A PLAIN hashtable whose VALUES ARE PLAIN ARRAYS. Both halves of that sentence
    # were paid for:
    #  * not [ordered] -- an OrderedDictionary that crosses a function-parameter
    #    boundary arrives PSObject-wrapped and $dict[$key] then binds the INT
    #    overload of the indexer, throwing "Argument types do not match";
    #  * not List[object] as the value -- @($hash[$key]) on a generic list read from
    #    a [hashtable] PARAMETER throws the same "Argument types do not match" out of
    #    PSEnumerableBinder.MaybeDebase (bare enumeration works, the wrapped form does
    #    not), so the caller would blow up on a package that HAS a link. Arrays
    #    enumerate identically in every form.
    # A hashtable also matches names case-insensitively, which is what Lazarus does
    # and what the installer's resolver does.
    $acc = @{}
    $result = @{}
    $anomaly = ''
    $path = Join-Path $UserPcp 'packagefiles.xml'
    $doc = Get-AefosImportXml -Path $path
    if ($null -eq $doc) {
        return [pscustomobject]@{ Path = $path; Links = $result; Anomaly = $(if (Test-Path -LiteralPath $path) { 'unreadable' } else { 'missing' }) }
    }
    $list = $doc.SelectSingleNode('/CONFIG/UserPkgLinks')
    if ($null -eq $list) {
        return [pscustomobject]@{ Path = $path; Links = $result; Anomaly = 'no-UserPkgLinks' }
    }
    $declared = 0
    [void][int]::TryParse($list.GetAttribute('Count'), [ref]$declared)
    $elements = @($list.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
    if ($declared -ne $elements.Count) {
        $anomaly = ("Count={0} but {1} entry(ies) on disk -- your IDE only sees the first {0}" -f $declared, $elements.Count)
    }
    for ($i = 1; $i -le $declared; $i++) {
        $item = $list.SelectSingleNode(('Item{0}' -f $i))
        if ($null -eq $item) { continue }
        $nameNode = $item.SelectSingleNode('Name')
        $fileNode = $item.SelectSingleNode('Filename')
        if (($null -eq $nameNode) -or ($null -eq $fileNode)) { continue }
        $name = $nameNode.GetAttribute('Value')
        $file = $fileNode.GetAttribute('Value')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (-not $acc.ContainsKey($name)) { $acc[$name] = New-Object System.Collections.Generic.List[object] }
        $acc[$name].Add([pscustomobject]@{
            Name     = $name
            Filename = $file
            Exists   = ((-not [string]::IsNullOrWhiteSpace($file)) -and (Test-Path -LiteralPath $file))
        })
    }
    foreach ($key in $acc.Keys) { $result[$key] = $acc[$key].ToArray() }
    return [pscustomobject]@{ Path = $path; Links = $result; Anomaly = $anomaly }
}

<#
.SYNOPSIS
    The user's IDE install list (<pcp>\miscellaneousoptions.xml,
    BuildLazarusOptions/StaticAutoInstallPackages). READ ONLY, index-faithful.
#>
function Get-AefosUserInstallList {
    param([Parameter(Mandatory = $true)][string]$UserPcp)

    $names = New-Object System.Collections.Generic.List[string]
    $path = Join-Path $UserPcp 'miscellaneousoptions.xml'
    $doc = Get-AefosImportXml -Path $path
    if ($null -eq $doc) {
        return [pscustomobject]@{
            Path = $path; Names = $names.ToArray(); DeclaredCount = 0; ElementCount = 0
            Anomaly = $(if (Test-Path -LiteralPath $path) { 'unreadable' } else { 'missing' })
        }
    }
    $list = $doc.SelectSingleNode('//StaticAutoInstallPackages')
    if ($null -eq $list) {
        return [pscustomobject]@{ Path = $path; Names = $names.ToArray(); DeclaredCount = 0; ElementCount = 0; Anomaly = 'no-list' }
    }
    $declared = 0
    [void][int]::TryParse($list.GetAttribute('Count'), [ref]$declared)
    $elements = @($list.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
    for ($i = 1; $i -le $declared; $i++) {
        $item = $list.SelectSingleNode(('Item{0}' -f $i))
        if ($null -eq $item) { continue }
        $value = $item.GetAttribute('Value')
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        [void]$names.Add($value)
    }
    $anomaly = ''
    if ($declared -ne $elements.Count) {
        $anomaly = ("Count={0} but {1} entry(ies) on disk -- your IDE only installs the first {0}" -f $declared, $elements.Count)
    }
    return [pscustomobject]@{
        Path = $path; Names = $names.ToArray(); DeclaredCount = $declared
        ElementCount = $elements.Count; Anomaly = $anomaly
    }
}

<#
.SYNOPSIS
    Every .lpk that ships inside the Lazarus tree, keyed by file base name.
    ONE recursive pass (a per-package scan would be N times the cost for the same
    answer -- the installer learned that at :703-708).
#>
function Get-AefosTreePackageMap {
    param([Parameter(Mandatory = $true)][string]$LazarusDir)
    $map = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $LazarusDir -Recurse -Filter '*.lpk' -ErrorAction SilentlyContinue)) {
        if (-not $map.ContainsKey($file.BaseName)) { $map[$file.BaseName] = $file.FullName }
    }
    return $map
}

<#
.SYNOPSIS
    The package NAME declared inside an .lpk (<Package><Name Value="..."/>).
    The install list is keyed by that name, not by the file name, and the two do
    differ (anchordockingdsgn.lpk declares "AnchorDockingDsgn").
#>
function Get-AefosLpkPackageName {
    param([Parameter(Mandatory = $true)][string]$Path)
    $doc = Get-AefosImportXml -Path $Path
    if ($null -eq $doc) { return '' }
    $node = $doc.SelectSingleNode('/CONFIG/Package/Name')
    if ($null -eq $node) { return '' }
    return $node.GetAttribute('Value')
}

# ---------------------------------------------------------------------------
# Public: resolution
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Can this package name still be resolved to an .lpk that exists? Returns WHICH
    source answered and the file, or the reason it could not.
.DESCRIPTION
    The two sources lazbuild itself uses, in the same order: a user package link
    that still points at a real file, then a package shipped inside the Lazarus
    tree. Faithful twin of Test-AefosPackageResolvable
    (installer\lazarus\aefos-laz-install.ps1:682-699) -- see the header for why it
    is duplicated and how the duplication is policed.

    Comparison is case-insensitive on both paths, because it is in the original:
    PowerShell's -eq and a default hashtable both ignore case, and so does Lazarus
    when it matches package names.
#>
function Resolve-AefosImportedPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Links,
        [hashtable]$LpkMap
    )

    # A LIVE link wins over a dead one with the same name: the installer has seen a
    # single package carry three dead links (deleted dev worktrees) plus one live
    # one, and taking the first entry would have thrown the working one away.
    $deadPath = ''
    if (($null -ne $Links) -and $Links.ContainsKey($Name)) {
        foreach ($entry in @($Links[$Name])) {
            if ($entry.Exists) {
                return [pscustomobject]@{
                    Resolved = $true; Source = 'link'; Lpk = $entry.Filename; Reason = ''; Detail = ''
                }
            }
            if ([string]::IsNullOrWhiteSpace($deadPath)) { $deadPath = $entry.Filename }
        }
    }
    if (($null -ne $LpkMap) -and $LpkMap.ContainsKey($Name)) {
        return [pscustomobject]@{
            Resolved = $true; Source = 'tree'; Lpk = $LpkMap[$Name]; Reason = ''; Detail = ''
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($deadPath)) {
        return [pscustomobject]@{
            Resolved = $false; Source = ''; Lpk = ''
            Reason   = 'link-dead'
            Detail   = $deadPath
        }
    }
    return [pscustomobject]@{
        Resolved = $false; Source = ''; Lpk = ''
        Reason   = 'not-found'
        Detail   = ''
    }
}

<#
.SYNOPSIS
    The package's GENERATED MAIN UNIT: <package dir>\<PackageName>.pas.
.DESCRIPTION
    Lazarus compiles a package through a main unit it generates itself ("This file
    was automatically created by Lazarus. Do not edit!"), which does nothing but
    call RegisterUnit for every unit of the package. It is written into the
    PACKAGE'S OWN directory, and there is no knob that moves it: the compiler has
    to find it next to the package sources. It is created on the FIRST compile,
    by whoever compiles first.

    That makes it the one file an isolated Aefos build can add on the user's side,
    and EXP-3 caught it live: a package in his install list that had never been
    compiled got its <name>.pas created by OUR build. For a package he really has
    installed the file is already there and nothing is written -- which is why the
    measured number for a realistic user is still zero. We predict it instead of
    hoping, so the report can say it before he finds it.
#>
function Get-AefosPackageMainUnit {
    param([Parameter(Mandatory = $true)][string]$Lpk, [Parameter(Mandatory = $true)][string]$Name)
    return (Join-Path (Split-Path -Parent $Lpk) ($Name + '.pas'))
}

<#
.SYNOPSIS
    THE PLAN: what of the user's install list can come into the Aefos IDE, what
    cannot, and why. Pure reading -- writes nothing, builds nothing.
.PARAMETER AlwaysInclude
    Package names that must be in the list whatever the user has (ours + docking).
    Matched case-insensitively against his list so a package he ALSO has is not
    imported twice.
#>
function New-AefosComponentImportPlan {
    param(
        [Parameter(Mandatory = $true)][string]$LazarusDir,
        [string]$UserPcp,
        [string[]]$AlwaysInclude = @(),
        [switch]$NoImport
    )

    if (-not (Test-Path -LiteralPath $LazarusDir)) {
        throw "Lazarus directory not found: '$LazarusDir'."
    }

    $imported = New-Object System.Collections.Generic.List[object]
    $skipped  = New-Object System.Collections.Generic.List[object]
    $requested = @()
    $listInfo = $null
    $linkInfo = $null

    $always = @($AlwaysInclude | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ((-not $NoImport) -and (-not [string]::IsNullOrWhiteSpace($UserPcp)) -and (Test-Path -LiteralPath $UserPcp)) {
        $listInfo = Get-AefosUserInstallList -UserPcp $UserPcp
        $linkInfo = Get-AefosUserPackageLinks -UserPcp $UserPcp
        $requested = @($listInfo.Names)
        if ($requested.Count -gt 0) {
            $lpkMap = Get-AefosTreePackageMap -LazarusDir $LazarusDir
            $seen = @{}
            foreach ($name in $requested) {
                if ($seen.ContainsKey($name)) { continue }
                $seen[$name] = $true
                # Ours and the docking packages are added by file further down; do
                # not re-judge them here and do not list them twice.
                $isAlways = $false
                foreach ($a in $always) { if ($a -ieq $name) { $isAlways = $true; break } }
                if ($isAlways) { continue }

                $res = Resolve-AefosImportedPackage -Name $name -Links $linkInfo.Links -LpkMap $lpkMap
                if ($res.Resolved) {
                    $main = Get-AefosPackageMainUnit -Lpk $res.Lpk -Name $name
                    $imported.Add([pscustomobject]@{
                        Name = $name; Source = $res.Source; Lpk = $res.Lpk
                        MainUnit = $main
                        # MEASURED, not assumed (probe EXP-3, poisoned run): compiling a
                        # package Lazarus has never compiled CREATES this generated main
                        # unit in the package's OWN directory -- the single file that can
                        # break "we write nothing on your side". Predict it here so the
                        # report can declare it instead of the user finding it.
                        NeedsFirstCompile = (-not (Test-Path -LiteralPath $main))
                    })
                } else {
                    $skipped.Add([pscustomobject]@{
                        Name     = $name
                        Reason   = $res.Reason
                        Detail   = $res.Detail
                        Recovery = (Get-AefosImportRecoveryText -Name $name -Reason $res.Reason -Detail $res.Detail)
                    })
                }
            }
        }
    }

    # The list we will seed: ours first (the IDE must link Aefos even if every one
    # of his packages is dropped), then his, in HIS order.
    $installList = New-Object System.Collections.Generic.List[string]
    foreach ($a in $always) { [void]$installList.Add($a) }
    foreach ($p in $imported) { [void]$installList.Add($p.Name) }

    return [pscustomobject]@{
        LazarusDir    = $LazarusDir
        UserPcp       = $UserPcp
        Requested     = $requested
        Imported      = $imported.ToArray()
        Skipped       = $skipped.ToArray()
        InstallList   = $installList.ToArray()
        MinimalList   = $always
        # The exact files our build will create on HIS side, predicted BEFORE the
        # build runs. Empty is the normal case: a package he actually has installed
        # has been compiled, so its main unit already exists.
        FirstCompile  = @($imported.ToArray() | Where-Object { $_.NeedsFirstCompile })
        ListPath      = $(if ($listInfo) { $listInfo.Path } else { '' })
        ListAnomaly   = $(if ($listInfo) { $listInfo.Anomaly } else { '' })
        LinksPath     = $(if ($linkInfo) { $linkInfo.Path } else { '' })
        LinkAnomaly   = $(if ($linkInfo) { $linkInfo.Anomaly } else { '' })
        ImportEnabled = (-not $NoImport)
    }
}

<#
.SYNOPSIS
    What the user DOES about a package that could not be imported. One sentence per
    reason, in his terms, naming the menu path -- "left out" without a way back is
    the same as losing it.
#>
function Get-AefosImportRecoveryText {
    param([string]$Name, [string]$Reason, [string]$Detail)
    switch ($Reason) {
        'link-dead' {
            return ("Your Lazarus still has a package link for '{0}', but the file it points at is gone ({1}). " -f $Name, $Detail) +
                   "Put that .lpk back, or open the package again in your own Lazarus (Package > Open Package File, then Use > Install), then run the Aefos setup again."
        }
        'not-found' {
            return ("No package link for '{0}' and no {0}.lpk inside your Lazarus folder. " -f $Name) +
                   "Install it in your own Lazarus first (Package > Open Package File, then Use > Install), then run the Aefos setup again. " +
                   "It is also worth checking whether your own IDE still starts without warnings about this package."
        }
        'build-failed' {
            return ("The Aefos IDE build stopped on '{0}', so it was left out and the IDE was built without it. " -f $Name) +
                   "Your own Lazarus is untouched and still has it. Fix or remove that package in your own IDE " +
                   "(Package > Install/Uninstall Packages), then run the Aefos setup again."
        }
        'fallback' {
            # NOT "see above": this package is innocent, and the user needs to know
            # that fixing ONE package brings ALL of them back in one run.
            return ("Nothing is wrong with '{0}' itself -- it was dropped because the whole import had to be given up. " -f $Name) +
                   $(if ($Detail) { "Fix '$Detail' (the package the build stopped on) in your own Lazarus and run the Aefos setup again: they all come back together." }
                     else { 'Fix the package named as the cause above and run the Aefos setup again: they all come back together.' })
        }
    }
    return 'No recovery step is known for this case; please report it.'
}

# ---------------------------------------------------------------------------
# Public: the report
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Writes <pcp>\import-report.txt: what got in, what did not, why, and what to do.
    Goes through Write-AefosSeedFile, so it CANNOT land outside our pcp.
.PARAMETER Outcome
    Imported | Fallback | Minimal | Failed -- the honest headline. 'Fallback' is the
    one that must never look like success: his components are NOT in the IDE.
#>
function Write-AefosImportReport {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$TargetPcp,
        [string]$Outcome = 'Imported',
        [string]$LazarusVersion = '',
        [string]$FailureCulprit = '',
        [string]$FailureLog = '',
        [string[]]$Attempts = @()
    )
    [void](Test-AefosImportSeederLoaded -Throw)

    $pcp = [System.IO.Path]::GetFullPath($TargetPcp).TrimEnd('\')
    $sb = New-Object System.Text.StringBuilder
    # CRLF, written through Write-AefosSeedFile (UTF-8, no BOM): the user opens this
    # in Notepad, and a report that renders as one long line is a report nobody reads.
    function Add-Line {
        param([string]$Text = '')
        [void]$sb.Append($Text)
        [void]$sb.Append("`r`n")
    }

    Add-Line 'Aefos AI - isolated Lazarus IDE - component import report'
    Add-Line '========================================================='
    Add-Line ("generated     : {0:yyyy-MM-dd HH:mm:ss} UTC" -f [DateTime]::UtcNow)
    Add-Line ("your Lazarus  : {0}{1}" -f $Plan.LazarusDir, $(if ($LazarusVersion) { "  (version $LazarusVersion)" } else { '' }))
    Add-Line ("your config   : {0}" -f $(if ($Plan.UserPcp) { $Plan.UserPcp } else { '(not read)' }))
    Add-Line ("Aefos IDE     : {0}" -f (Join-Path (Join-Path $pcp 'bin') 'lazarus.exe'))
    Add-Line ''
    Add-Line 'Your own Lazarus was NOT modified. Everything below happened on the Aefos'
    Add-Line 'side only; your IDE keeps every package it had, exactly as it had them.'
    Add-Line ''

    switch ($Outcome) {
        'Imported' {
            Add-Line ("RESULT: {0} of your component package(s) are installed in the Aefos IDE." -f @($Plan.Imported).Count)
        }
        'Partial' {
            Add-Line ("RESULT: {0} of your component package(s) are installed in the Aefos IDE, and {1} could not be." -f `
                @($Plan.Imported).Count, @($Plan.Skipped).Count)
            Add-Line ''
            Add-Line 'One or more of your packages stopped the build, so the Aefos IDE was built'
            Add-Line 'again WITHOUT them and with everything else kept. They are named below.'
            Add-Line 'Your own Lazarus still has all of them, exactly as before.'
        }
        'Fallback' {
            Add-Line 'RESULT: FALLBACK - your components are NOT in the Aefos IDE.'
            Add-Line ''
            Add-Line 'The Aefos IDE was built with your component packages first, and that build'
            Add-Line 'failed. Rather than leave you with no IDE, it was rebuilt with the minimum'
            Add-Line 'set (Aefos + docking). The Aefos IDE works; your components are missing from'
            Add-Line 'it. Your own Lazarus still has all of them.'
        }
        'Minimal' {
            Add-Line 'RESULT: the Aefos IDE was built with the minimum set (Aefos + docking).'
            if (-not $Plan.ImportEnabled) { Add-Line 'Importing your components was turned off for this install.' }
        }
        'Failed' {
            Add-Line 'RESULT: FAILED - no Aefos IDE was produced.'
        }
    }
    Add-Line ''

    if ($FailureCulprit) {
        Add-Line ("the build stopped on : {0}" -f $FailureCulprit)
    }
    if ($FailureLog) {
        Add-Line ("full build log       : {0}" -f $FailureLog)
    }
    if (@($Attempts).Count -gt 0) {
        Add-Line 'build attempts       :'
        foreach ($a in @($Attempts)) { Add-Line ("  - {0}" -f $a) }
    }
    Add-Line ''

    $inIde = ($Outcome -in @('Imported', 'Partial'))
    Add-Line ("IMPORTED ({0}){1}" -f @($Plan.Imported).Count, $(if ($inIde) { ' - installed in the Aefos IDE:' } else { ' - RESOLVED but NOT in the Aefos IDE (see RESULT above):' }))
    if (@($Plan.Imported).Count -eq 0) {
        Add-Line '  (none)'
    } else {
        foreach ($p in @($Plan.Imported)) {
            $origin = if ($p.Source -eq 'link') { 'your package link' } else { 'shipped inside your Lazarus' }
            Add-Line ("  {0}" -f $p.Name)
            Add-Line ("      from : {0}  ({1})" -f $p.Lpk, $origin)
        }
    }
    Add-Line ''

    Add-Line ("LEFT OUT ({0}) - the Aefos IDE does NOT have these:" -f @($Plan.Skipped).Count)
    if (@($Plan.Skipped).Count -eq 0) {
        Add-Line '  (none)'
    } else {
        foreach ($s in @($Plan.Skipped)) {
            Add-Line ("  {0}" -f $s.Name)
            Add-Line ("      why : {0}" -f (Get-AefosImportReasonText -Reason $s.Reason -Detail $s.Detail))
            Add-Line ("      fix : {0}" -f $s.Recovery)
        }
    }
    Add-Line ''

    Add-Line 'MINIMUM SET (always present):'
    foreach ($m in @($Plan.MinimalList)) { Add-Line ("  {0}" -f $m) }
    Add-Line ''

    # The ONE thing an isolated build can add on his side, declared up front rather
    # than discovered. Empty for a user whose packages are really installed.
    $firstCompile = @()
    if ($Plan.PSObject.Properties.Name -contains 'FirstCompile') { $firstCompile = @($Plan.FirstCompile) }
    if ($firstCompile.Count -gt 0) {
        Add-Line ("FILES CREATED IN YOUR COMPONENT FOLDERS ({0}):" -f $firstCompile.Count)
        Add-Line '  These packages had never been compiled on this machine. Compiling one'
        Add-Line '  makes Lazarus generate the small "do not edit" unit it always generates'
        Add-Line '  for a package, in the package own folder. Your own IDE creates exactly the'
        Add-Line '  same file the first time you build that package. Nothing else of yours is'
        Add-Line '  written, and your Lazarus installation itself is not touched.'
        foreach ($f in $firstCompile) { Add-Line ("    {0}" -f $f.MainUnit) }
        Add-Line ''
    }

    if ($Plan.ListAnomaly) {
        Add-Line ("NOTE about {0}:" -f $Plan.ListPath)
        Add-Line ("  {0}" -f $Plan.ListAnomaly)
        Add-Line ''
    }
    if ($Plan.LinkAnomaly) {
        Add-Line ("NOTE about {0}:" -f $Plan.LinksPath)
        Add-Line ("  {0}" -f $Plan.LinkAnomaly)
        Add-Line ''
    }

    Add-Line 'Nothing was removed from your Lazarus, and your Lazarus installation itself'
    if ($firstCompile.Count -gt 0) {
        Add-Line 'was not written to. The only files added on your side are the generated'
        Add-Line 'package units listed above. This report describes the Aefos IDE only.'
    } else {
        Add-Line 'was not written to at all. This report describes the Aefos IDE only.'
    }

    $written = New-Object System.Collections.Generic.List[string]
    $path = Join-Path $pcp $Script:AefosImportReportFile
    Write-AefosSeedFile -Root $pcp -Path $path -Content $sb.ToString() -Written $written
    return $path
}

function Get-AefosImportReasonText {
    param([string]$Reason, [string]$Detail)
    switch ($Reason) {
        'link-dead'    { return ("your Lazarus has a package link for it, but the file it points at no longer exists ({0})" -f $Detail) }
        'not-found'    { return 'no package link for it, and no .lpk with that name inside your Lazarus folder' }
        'build-failed' { return ("the Aefos IDE build failed on it{0}" -f $(if ($Detail) { " ($Detail)" } else { '' })) }
        'fallback'     { return ("dropped when the build fell back to the minimum set{0}" -f $(if ($Detail) { " after '$Detail' failed" } else { '' })) }
    }
    return $Reason
}

# ---------------------------------------------------------------------------
# Public: THE BUILD, with the fallback
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    WHICH package killed the build. Naming it is the difference between "Aefos
    failed" and "this component of yours is broken".
.DESCRIPTION
    Three passes, because a rebuild dies in two different ways and only one of them
    was known before EXP-3 ran:
      1. RESOLUTION failure -- 'Unable to open the package "X"' (EN + the PT this
         product also ships). This is the one the installer already matches at
         aefos-laz-install.ps1:792-796, and the partner's field case.
      2. COMPILE failure -- 'Error: (lazarus) Compile package X 1.0: stopped with
         exit code 1'. A package that resolves fine and then does not build; the
         filter cannot catch it, only the fallback can, and without this pass the
         report blamed nobody.
      3. Language-agnostic net -- the LAST package name from the plan that appears
         on a line containing 'Error'. Passes 1 and 2 match English text; a package
         NAME is not translated, so this one still works on a localized IDE.
    A miss is not fatal: the report then points at the log.
#>
function Get-AefosImportBuildCulprit {
    param([string]$LogPath, [string[]]$Names = @())
    if (-not (Test-Path -LiteralPath $LogPath)) { return '' }
    $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
    foreach ($line in $lines) {
        if ($line -match 'Unable to open the package "([^"]+)"' -or
            $line -match 'Incapaz de abrir o pacote "([^"]+)"') {
            return $Matches[1]
        }
    }
    foreach ($line in $lines) {
        if ($line -match 'Compile package\s+(.+?)\s+[\d][\d.]*:\s*stopped with exit code') {
            return $Matches[1]
        }
    }
    # "Broken dependency: A 1.2->B 3.4->C" -- the shape a package with a MISSING
    # dependency produces, and the one a real partner machine actually hit three
    # times in a row. It used to be caught only by the loose scan below, which
    # takes the LAST name that matches anywhere on the line: on a CHAIN that is
    # the innermost link (ibnongui) rather than the package HE asked for
    # (dclibx). Dropping the wrong end can leave the same failure standing and
    # burn a retry round for nothing.
    #
    # So walk the chain left to right and blame the FIRST element that is one of
    # OURS to drop. That is the entry in his install list; everything after it is
    # a dependency he never listed and we cannot remove.
    foreach ($line in $lines) {
        if ($line -notmatch '(?i)Broken dependency:\s*(.+)$') { continue }
        foreach ($part in ($Matches[1] -split '->')) {
            # Strip the trailing version ("dclibx 2.7.11.1673" -> "dclibx").
            $cand = ($part.Trim() -replace '\s+[\d][\d.]*\s*$', '').Trim()
            if ([string]::IsNullOrWhiteSpace($cand)) { continue }
            foreach ($n in @($Names)) {
                if ([string]::IsNullOrWhiteSpace($n)) { continue }
                if ($n -ieq $cand) { return $n }
            }
        }
    }
    $found = ''
    foreach ($line in $lines) {
        if ($line -notmatch 'Error') { continue }
        foreach ($n in @($Names)) {
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            if ($line -match ('(?i)\b' + [Regex]::Escape($n) + '\b')) { $found = $n }
        }
    }
    return $found
}

<#
.SYNOPSIS
    Seeds OUR pcp with the FILTERED install list, builds the isolated IDE, and --
    if that fails -- rebuilds with the MINIMUM list so the user still gets a
    working IDE. Writes <pcp>\import-report.txt either way.
.DESCRIPTION
    Order of operations, and why:
      1. plan      - read his side, resolve every name (nothing is written yet).
      2. links     - `lazbuild --pcp=<ours> --add-package-link <lpk>` for EVERY
                     package we intend to install, ours and the docking ones
                     included. Registering the link for a TREE package too may look
                     redundant: it is not. A package that merely sits inside the
                     Lazarus folder is only auto-known to the IDE when it has a
                     .lpl in packager\globallinks; the resolver accepts a bare .lpk
                     because lazbuild will accept it once a link exists -- so we
                     create that link, in OUR pcp, instead of hoping.
      3. seed      - New-AefosIsolatedPcpSeed with -StaticAutoInstallPackages, which
                     REPLACES the list in our miscellaneousoptions.xml. That is what
                     makes step 5 able to drop the imported names again.
      4. build     - lazbuild --build-ide with our .lpk and the docking .lpk passed
                     by file, so the IDE links Aefos even if his list were empty.
      5. fallback  - on failure, re-seed with the minimum list and build again. The
                     package LINKS are deliberately left in place: a link is inert,
                     only the install list drives the build.
      6. hygiene   - sweep lazarus.old.exe (20.9 MB per rebuild) and assert the
                     <pcp>\bin sort-order invariant.
    lazbuild is taken from the user's tree (this whole model builds with HIS
    toolchain through --lazarusdir).
#>
function Invoke-AefosIsolatedIdeBuild {
    param(
        [Parameter(Mandatory = $true)][string]$LazarusDir,
        [Parameter(Mandatory = $true)][string]$TargetPcp,
        [Parameter(Mandatory = $true)][string]$AefosLpk,
        [string]$UserPcp,
        [string[]]$ExtraPackageLpk = @(),
        [string]$IdeOpts = '-g- -Xs',
        # How many times a build may be retried with the offending package removed
        # before the import is abandoned for the minimum set. 0 reproduces the plain
        # all-or-nothing fallback (and is how the probe proves that path still works).
        #
        # WAS 2, AND A REAL MACHINE PAID FOR IT. A partner's Lazarus carried THREE
        # packages with missing dependencies (CEF4Delphi_Lazarus -> dcpcrypt,
        # dclibx/ibnongui -> fbintf, rxdbgrid_export_spreadsheet -> laz_fpspreadsheet).
        # The escalation named all three correctly, one per round -- and then ran out
        # of budget on the third and fell back to the minimum set, so he lost EVERY
        # component he had, including the ones that would have compiled. The logic was
        # right; the number was invented. 8 is still bounded (a failing attempt dies
        # in about a second, at the first package that will not compile), but it is
        # now above what a real, lived-in IDE actually carries.
        [int]$MaxCulpritRetries = 8,
        [switch]$NoImport,
        [switch]$NoPkgOutDirRedirect,
        [switch]$SkipReport
    )

    [void](Test-AefosImportSeederLoaded -Throw)
    if (-not (Test-Path -LiteralPath $AefosLpk)) { throw "Aefos package not found at '$AefosLpk'." }

    $info = Get-AefosLazarusTreeInfo -LazarusDir $LazarusDir
    $pcp = [System.IO.Path]::GetFullPath($TargetPcp).TrimEnd('\')
    $lazBuild = $info.LazBuild
    $logDir = Join-Path $pcp $Script:AefosImportLogDir
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    # The packages that are OURS, by the name declared inside each .lpk (the install
    # list is keyed by that name, and it is not the file name).
    $ourLpks = @($AefosLpk) + @($ExtraPackageLpk | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $minimal = New-Object System.Collections.Generic.List[string]
    foreach ($lpk in $ourLpks) {
        if (-not (Test-Path -LiteralPath $lpk)) { throw "Package file not found: '$lpk'." }
        $name = Get-AefosLpkPackageName -Path $lpk
        if ([string]::IsNullOrWhiteSpace($name)) { $name = [System.IO.Path]::GetFileNameWithoutExtension($lpk) }
        [void]$minimal.Add($name)
    }

    $plan = New-AefosComponentImportPlan -LazarusDir $info.LazarusDir -UserPcp $UserPcp `
        -AlwaysInclude $minimal.ToArray() -NoImport:$NoImport

    # -- step 2: package links, in OUR pcp only ----------------------------
    # SEED FIRST. This line is the whole difference between importing the user's
    # components and never importing a single one, and it was found by the F4
    # round-trip gate on 2026-07-27, on the only path nobody had exercised: a
    # FRESH install.
    #   MEASURED: on a pcp that has not been seeded yet, `lazbuild --pcp=<empty dir>
    #   --add-package-link <lpk>` exits 7 and writes NOTHING -- not even a
    #   packagefiles.xml. Seed the same pcp first and the identical three commands
    #   all exit 0 and all three links land.
    # The bug hid because the F0/F2 probe runs EXP-3 against a pcp a previous EXP-1
    # had already seeded, so the links landed there; and because the automatic
    # fallback then produces a WORKING IDE with an honest report, the failure looked
    # like a degradation instead of "the feature never runs".
    # Re-seeding is idempotent and additive by design (see New-AefosIsolatedPcpSeed),
    # and Invoke-AefosIdeLazbuild seeds again per attempt with the install list.
    [void](New-AefosIsolatedPcpSeed -LazarusDir $info.LazarusDir -TargetPcp $pcp -UserPcp $UserPcp `
        -NoPkgOutDirRedirect:$NoPkgOutDirRedirect)

    # POSITIONAL, never --add-package-link=<file>: lazbuild's own --help documents
    # the '=' form and its parser REJECTS it, then exits 0 anyway (both traps paid
    # for in the installer on 2026-07-17).
    #
    # And the result is VERIFIED, not assumed. The old comment here argued that a
    # lost link "cannot hide, because the very next build fails" -- which is true and
    # was exactly the problem: the build failed, the fallback produced a working IDE,
    # and the user silently got none of his components with a report blaming an
    # innocent package. A link that does not land is now named as what it is.
    $linkTargets = @($ourLpks) + @($plan.Imported | ForEach-Object { $_.Lpk })
    $linkFailures = New-Object System.Collections.Generic.List[string]
    foreach ($lpk in $linkTargets) {
        if ([string]::IsNullOrWhiteSpace($lpk) -or -not (Test-Path -LiteralPath $lpk)) { continue }
        & $lazBuild "--pcp=$pcp" --add-package-link "$lpk" *>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            [void]$linkFailures.Add(("{0} (lazbuild exit {1})" -f (Split-Path -Leaf $lpk), $LASTEXITCODE))
        }
    }
    # Exit 0 is not proof either (that trap is already on the record): read the file
    # back and check the package NAME is really registered. The name inside the .lpk
    # is what the list is keyed by, and it is not always the file name.
    $registered = @{}
    $linksXml = Get-AefosImportXml -Path (Join-Path $pcp 'packagefiles.xml')
    if ($null -ne $linksXml) {
        foreach ($nameNode in @($linksXml.SelectNodes('/CONFIG/UserPkgLinks/*/Name'))) {
            $registered[$nameNode.GetAttribute('Value')] = $true
        }
    }
    foreach ($lpk in $linkTargets) {
        if ([string]::IsNullOrWhiteSpace($lpk) -or -not (Test-Path -LiteralPath $lpk)) { continue }
        $pkgName = Get-AefosLpkPackageName -Path $lpk
        if ([string]::IsNullOrWhiteSpace($pkgName)) { $pkgName = [System.IO.Path]::GetFileNameWithoutExtension($lpk) }
        # A package that SHIPS INSIDE the Lazarus tree is already known through
        # packager\globallinks and needs no user link, so a missing user link for one
        # of those is not a failure.
        if ($registered.ContainsKey($pkgName)) { continue }
        if (Test-AefosSeedInside -Child $lpk -Parent $info.LazarusDir) { continue }
        [void]$linkFailures.Add(("{0} (no user package link landed in our pcp)" -f $pkgName))
    }

    $attempts = New-Object System.Collections.Generic.List[string]
    $addPkgArgs = @()
    foreach ($lpk in $ourLpks) { $addPkgArgs += @('--add-package', $lpk) }

    function Invoke-AefosIdeLazbuild {
        param([string[]]$InstallList, [string]$LogPath)
        [void](New-AefosIsolatedPcpSeed -LazarusDir $info.LazarusDir -TargetPcp $pcp -UserPcp $UserPcp `
            -NoPkgOutDirRedirect:$NoPkgOutDirRedirect -StaticAutoInstallPackages $InstallList)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $lazBuild "--pcp=$pcp" "--lazarusdir=$($info.LazarusDir)" @addPkgArgs "--build-ide=$IdeOpts" *>&1 |
            Tee-Object -FilePath $LogPath | Out-Null
        $code = $LASTEXITCODE
        $sw.Stop()
        return [pscustomobject]@{ ExitCode = $code; Seconds = $sw.Elapsed.TotalSeconds; Log = $LogPath }
    }

    # THE ESCALATION. "One broken package costs you every component you have" is a
    # bad trade when we can name the broken one: lazbuild says which package it died
    # on, so the next attempt drops THAT package and keeps the rest. Only when the
    # culprit cannot be named -- or after MaxCulpritRetries of them -- do we give up
    # on the import and build the minimum set. Bounded on purpose: every attempt
    # costs the user install time, and a failing attempt dies fast (measured: 1 s,
    # it stops at the first package that will not compile).
    #   attempt 1 : everything that resolved
    #   attempt 2..n : minus the packages that killed the previous attempt
    #   last      : the minimum set, which is the promise that he always gets an IDE
    $withComponents = @($plan.Imported).Count -gt 0
    $importedNames = @($plan.Imported | ForEach-Object { $_.Name })
    $currentList = @($plan.InstallList)
    $droppedByBuild = New-Object System.Collections.Generic.List[string]
    $culprit = ''
    $failLog = ''
    $outcome = $(if ($withComponents) { 'Imported' } else { 'Minimal' })

    $log1 = Join-Path $logDir 'build-import.log'
    $final = Invoke-AefosIdeLazbuild -InstallList $currentList -LogPath $log1
    [void]$attempts.Add(("with {0} imported package(s): lazbuild exit {1} in {2:N0}s" -f @($plan.Imported).Count, $final.ExitCode, $final.Seconds))

    $round = 0
    while (($final.ExitCode -ne 0) -and $withComponents -and ($round -lt $MaxCulpritRetries)) {
        $blame = Get-AefosImportBuildCulprit -LogPath $final.Log -Names $importedNames
        if ([string]::IsNullOrWhiteSpace($culprit)) { $culprit = $blame }
        $failLog = $final.Log
        # Only a package WE added can be dropped. If the blame lands on one of ours
        # or on nothing at all, dropping is not an option and the minimum set is the
        # only honest next step.
        $canDrop = $false
        foreach ($n in $importedNames) { if (($n -ieq $blame) -and (-not ($droppedByBuild -contains $n))) { $canDrop = $true; break } }
        if (-not $canDrop) { break }
        $round++
        [void]$droppedByBuild.Add($blame)
        $currentList = @($currentList | Where-Object { -not ($droppedByBuild -contains $_) })
        $logN = Join-Path $logDir ("build-import-retry{0}.log" -f $round)
        $final = Invoke-AefosIdeLazbuild -InstallList $currentList -LogPath $logN
        [void]$attempts.Add(("without '{0}': lazbuild exit {1} in {2:N0}s" -f $blame, $final.ExitCode, $final.Seconds))
    }

    if ($final.ExitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($culprit)) {
            $culprit = Get-AefosImportBuildCulprit -LogPath $final.Log -Names $importedNames
        }
        $failLog = $final.Log
        if ($withComponents) {
            $logMin = Join-Path $logDir 'build-minimal.log'
            $final = Invoke-AefosIdeLazbuild -InstallList $plan.MinimalList -LogPath $logMin
            [void]$attempts.Add(("fallback to the minimum set: lazbuild exit {0} in {1:N0}s" -f $final.ExitCode, $final.Seconds))
            if ($final.ExitCode -eq 0) {
                $outcome = 'Fallback'
                foreach ($n in $importedNames) { if (-not ($droppedByBuild -contains $n)) { [void]$droppedByBuild.Add($n) } }
            } else {
                $outcome = 'Failed'
                $failLog = $logMin
            }
        } else {
            $outcome = 'Failed'
        }
    }
    elseif ($droppedByBuild.Count -gt 0) {
        # Partial: he keeps everything except the package(s) that would not build.
        $outcome = 'Partial'
    }

    # The plan is rewritten so the report cannot claim an import that did not
    # survive: Imported must mean "it is in the IDE".
    if ($droppedByBuild.Count -gt 0) {
        $reason = $(if ($culprit) { $culprit } else { 'see the build log' })
        $kept = New-Object System.Collections.Generic.List[object]
        $dropped = New-Object System.Collections.Generic.List[object]
        foreach ($s in @($plan.Skipped)) { [void]$dropped.Add($s) }
        foreach ($p in @($plan.Imported)) {
            if (-not ($droppedByBuild -contains $p.Name)) { [void]$kept.Add($p); continue }
            # A package that was dropped because IT failed gets the truth; one dropped
            # only because the whole import was abandoned is told it is innocent.
            $itFailed = $false
            foreach ($n in $droppedByBuild) { if (($n -ieq $p.Name) -and ($outcome -ne 'Fallback')) { $itFailed = $true } }
            if ($culprit -and ($p.Name -ieq $culprit)) { $itFailed = $true }
            $why = $(if ($itFailed) { 'build-failed' } else { 'fallback' })
            [void]$dropped.Add([pscustomobject]@{
                Name     = $p.Name
                Reason   = $why
                Detail   = $(if ($itFailed) { '' } else { $reason })
                Recovery = (Get-AefosImportRecoveryText -Name $p.Name -Reason $why -Detail $reason)
            })
        }
        $plan = [pscustomobject]@{
            LazarusDir = $plan.LazarusDir; UserPcp = $plan.UserPcp; Requested = $plan.Requested
            Imported = $kept.ToArray(); Skipped = $dropped.ToArray(); InstallList = $currentList
            # KEPT even for packages that were dropped: the failed attempt already
            # compiled some of them, so those files exist on his side. A report that
            # stopped declaring them would be a lie by omission.
            FirstCompile = $plan.FirstCompile
            MinimalList = $plan.MinimalList; ListPath = $plan.ListPath; ListAnomaly = $plan.ListAnomaly
            LinksPath = $plan.LinksPath; LinkAnomaly = $plan.LinkAnomaly; ImportEnabled = $plan.ImportEnabled
        }
    }

    # -- step 6: hygiene ----------------------------------------------------
    $binDir = Join-Path $pcp 'bin'
    $cleared = Clear-AefosIsolatedBin -BinDir $binDir
    $binRisk = Get-AefosIsolatedBinRisk -BinDir $binDir

    $reportPath = ''
    if (-not $SkipReport) {
        $reportPath = Write-AefosImportReport -Plan $plan -TargetPcp $pcp -Outcome $outcome `
            -LazarusVersion $info.Version -FailureCulprit $culprit -FailureLog $failLog `
            -Attempts $attempts.ToArray()
    }

    return [pscustomobject]@{
        Outcome     = $outcome
        Plan        = $plan
        ExitCode    = $final.ExitCode
        Attempts    = $attempts.ToArray()
        Culprit     = $culprit
        # Surfaced rather than swallowed: a link that did not land is the difference
        # between "your components are in the Aefos IDE" and a fallback that looks
        # like success. The caller (and the gate) can see it.
        LinkFailures = $linkFailures.ToArray()
        IdeExe      = (Join-Path $binDir 'lazarus.exe')
        IdeProduced = (Test-Path -LiteralPath (Join-Path $binDir 'lazarus.exe'))
        ReportPath  = $reportPath
        LogDir      = $logDir
        BinCleared  = $cleared
        BinRisk     = $binRisk
    }
}

# ---------------------------------------------------------------------------
# Stand-alone entry point. Dot-sourcing ('. .\aefos-laz-import-components.ps1')
# defines the functions and runs nothing.
#
# The arguments are copied into locals BEFORE the seeder is dot-sourced: that
# script's own param() block declares $LazarusDir/$TargetPcp/$UserPcp and would
# blank ours in this scope.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $RunLazarusDir = $LazarusDir
    $RunTargetPcp  = $TargetPcp
    $RunUserPcp    = $UserPcp
    $RunAefosLpk   = $AefosLpk
    $RunExtraLpk   = $ExtraPackageLpk
    $RunIdeOpts    = $BuildIdeOptions
    $RunNoImport   = $NoImport.IsPresent
    $RunNoOutDir   = $NoPkgOutDirRedirect.IsPresent
    $RunBuildIde   = $RunBuild.IsPresent

    if ([string]::IsNullOrWhiteSpace($RunLazarusDir)) { throw '-LazarusDir is required when running this script directly.' }

    $SeedEngine = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'aefos-laz-seed-pcp.ps1'
    if (-not (Test-Path -LiteralPath $SeedEngine)) { throw "Seeding engine not found at '$SeedEngine'." }
    . $SeedEngine

    if ($RunBuildIde) {
        if ([string]::IsNullOrWhiteSpace($RunTargetPcp)) { throw '-TargetPcp is required with -RunBuild.' }
        if ([string]::IsNullOrWhiteSpace($RunAefosLpk)) { throw '-AefosLpk is required with -RunBuild.' }
        $result = Invoke-AefosIsolatedIdeBuild -LazarusDir $RunLazarusDir -TargetPcp $RunTargetPcp `
            -UserPcp $RunUserPcp -AefosLpk $RunAefosLpk -ExtraPackageLpk $RunExtraLpk -IdeOpts $RunIdeOpts `
            -NoImport:$RunNoImport -NoPkgOutDirRedirect:$RunNoOutDir
        Write-Host '-- Aefos isolated IDE build --'
        Write-Host ("  outcome  : {0}" -f $result.Outcome)
        Write-Host ("  ide exe  : {0} (produced: {1})" -f $result.IdeExe, $result.IdeProduced)
        Write-Host ("  imported : {0}" -f @($result.Plan.Imported).Count)
        Write-Host ("  left out : {0}" -f @($result.Plan.Skipped).Count)
        Write-Host ("  report   : {0}" -f $result.ReportPath)
        foreach ($a in $result.Attempts) { Write-Host ("  attempt  : {0}" -f $a) }
        if ($result.Outcome -eq 'Failed') { exit 1 }
        exit 0
    }

    $plan = New-AefosComponentImportPlan -LazarusDir $RunLazarusDir -UserPcp $RunUserPcp -NoImport:$RunNoImport
    Write-Host '-- Aefos component import PLAN (nothing was written) --'
    Write-Host ("  lazarus tree : {0}" -f $plan.LazarusDir)
    Write-Host ("  user config  : {0}" -f $(if ($plan.UserPcp) { $plan.UserPcp } else { '(none)' }))
    Write-Host ("  his list     : {0} package(s)" -f @($plan.Requested).Count)
    if ($plan.ListAnomaly) { Write-Host ("  list anomaly : {0}" -f $plan.ListAnomaly) }
    if ($plan.LinkAnomaly) { Write-Host ("  link anomaly : {0}" -f $plan.LinkAnomaly) }
    Write-Host ("  importable   : {0}" -f @($plan.Imported).Count)
    foreach ($p in $plan.Imported) { Write-Host ("    + {0,-32} {1}" -f $p.Name, $p.Lpk) }
    Write-Host ("  left out     : {0}" -f @($plan.Skipped).Count)
    foreach ($s in $plan.Skipped) { Write-Host ("    - {0,-32} {1} {2}" -f $s.Name, $s.Reason, $s.Detail) }
}
