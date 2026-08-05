<#
.SYNOPSIS
    MILESTONE 2 / SLICE F1 -- the SEEDER for the ISOLATED Aefos Lazarus IDE.
    It produces OUR primary config path (pcp) so that `lazbuild --build-ide`
    lands <ourpcp>\bin\lazarus.exe with Aefos statically linked, reusing the
    user's own Lazarus tree through --lazarusdir, and WRITES NOTHING outside
    our own directory.

.DESCRIPTION
    WHY THIS FILE EXISTS
    --------------------
    Milestone 2 replaces the in-place install (rebuild the user's lazarus.exe,
    edit the user's XML) with an isolated IDE. Slice F0 measured the model and
    proved it can reach ZERO files written into the user's tree. This file is
    the reusable engine that reproduces that measured configuration. It is NOT
    wired into the installer yet -- that is a later slice.

    THE OWNER'S HARD RULE (2026-07-27)
    ----------------------------------
    "Do not remove anything from the XMLs Lazarus updates, only ADD, and on
    uninstall remove only what belongs to us."  For the SEED this is stronger:
    the seed must not touch ANY file of the user -- not even to add. Everything
    we need is registered in OUR pcp. That is enforced structurally, not by
    convention: every write goes through Write-AefosSeedFile, which REFUSES a
    destination that is not under the target pcp, and the returned result lists
    every file written so a caller/gate can assert containment.

    THE THREE THINGS F0 PROVED ARE MANDATORY
    ----------------------------------------
    1. VERSION STAMP, DERIVED -- NEVER LITERAL.
       ide\main.pp TMainIDE.LoadGlobalOptions (~1341-1379) compares
       EnvironmentOptions/Version@Lazarus in the pcp against LazarusVersionStr
       compiled into the running exe. On a mismatch it shows an Upgrade/
       Downgrade modal and then runs DeleteDirectory(PCP+'bin') and
       DeleteDirectory(PCP+'units'). Our exe LIVES in <pcp>\bin, so a wrong
       stamp aims a delete at our own install -- F0 ran it live: <pcp>\units
       was deleted ENTIRELY and a canary file in <pcp>\bin died.
       scripts\build-lazarus.ps1:529 hardcodes Lazarus="2.2.6" against a 4.8
       tree; that literal is exactly the bomb. Here the value is read from the
       user's tree: ide\packages\ideconfig\version.inc, which lazconf.pp:54
       compiles as LazarusVersionStr. Same source, so it can never disagree.

    2. THE <pcp>\bin SORT-ORDER INVARIANT.
       DeleteDirectory (components\lazutils\fileutil.inc:104-134) walks the
       directory in FindFirst order (NTFS: case-insensitive name order) and
       EXITS on the FIRST failure. In F0 our binary survived only because the
       running lazarus.exe is locked by Windows AND sorts before our DLLs. That
       is an ACCIDENT, not a protection: anything in <pcp>\bin whose name sorts
       BEFORE 'lazarus.exe' (a digit, a symbol, 'a'..'k', or a subdirectory
       like 'addons\') gets deleted before the loop reaches the lock.
       Get-AefosIsolatedBinRisk is the guard; it must stay at zero.

    3. lazarus.old.exe MUST BE SWEPT.
       lazbuild rolls the previous IDE exe aside on every --build-ide, so a
       20.9 MB copy reappears in <pcp>\bin after each rebuild. Clear-AefosIsolatedBin
       removes it. (It sorts AFTER lazarus.exe, so it is waste, not danger.)

    THE CONFIGURATION THAT BUYS "ZERO FILES" (measured in F0)
    ---------------------------------------------------------
    A BuildMatrix entry of Type="OutDir" overrides -FU for every package the
    matrix fits (ide\packages\ideconfig\modematrixopts.pas:41,49,565-578, hooked
    by ide\buildmanager.pas:2978-2988), so package output goes to
    <ourpcp>\pkglib\<pkg>\<cpu>-<os> instead of into the user's tree. Without
    it a redirected build still rewrote 1538 files / 123 MB of compiler cache
    inside the user's tree -- because --build-ide=<opts> becomes the
    $(IDEBuildOptions) macro that the BASE .lpk files ask for in their own
    CustomOptions (lcl\lclbase.lpk:22), which invalidates every .compiled stamp.
    TWO gotchas, both already paid for in F0:
      (a) <BuildMatrix> does NOT live inside <EnvironmentOptions>.
          environmentopts.pp:1579 builds FConfigStore with NO base path, so
          :943 AppendBasePath('BuildMatrix') resolves at the XML ROOT. Put it in
          the wrong place and it is ignored IN SILENCE -- no error, no warning,
          and the build writes into the user's tree as if nothing happened.
      (b) Modes must literally NAME a mode. An empty pattern does not fit, and
          with no project loaded the active mode is 'default'.

    WHERE THIS FILE LIVES, AND WHY
    ------------------------------
    scripts\, next to build-lazarus.ps1 -- the script this engine supersedes.
    It is product logic (the future install engine), not a test, so a test tree is
    wrong; installer\ is off-limits for this slice, and shipping it later costs
    ONE line in the .iss ("Source: ..\..\scripts\aefos-laz-seed-pcp.ps1"), so
    nothing has to move. Plain .ps1, dot-sourceable -- the repo has no .psm1
    anywhere and Inno calls plain .ps1 files.

.PARAMETER LazarusDir
    The USER's Lazarus tree. READ ONLY. Everything derived (version stamp, FPC
    version, LCL sources) comes from here.

.PARAMETER TargetPcp
    OUR primary config path. In production %LOCALAPPDATA%\Aefos\lazarus (see
    Get-AefosIsolatedPcpPath); in tests a disposable directory. The ONLY place
    this script is allowed to write.

.PARAMETER UserPcp
    The user's own config directory. READ ONLY, optional. When given, our
    environmentoptions.xml starts as a COPY of his and is then patched, so the
    isolated IDE inherits his settings. Nothing is ever written back.

.EXAMPLE
    . .\scripts\aefos-laz-seed-pcp.ps1          # dot-source, then call the functions
    $seed = New-AefosIsolatedPcpSeed -LazarusDir 'C:\lazarus' -TargetPcp $pcp

.EXAMPLE
    pwsh -File scripts\aefos-laz-seed-pcp.ps1 -LazarusDir C:\lazarus -TargetPcp D:\tmp\pcp
#>

[CmdletBinding()]
param(
    [string]$LazarusDir,
    [string]$TargetPcp,
    [string]$UserPcp,
    [string]$ProfileName = 'AefosIDE',
    [switch]$NoPkgOutDirRedirect,
    [string[]]$StaticAutoInstallPackages = @()
)

# NOTE: no file-scope $ErrorActionPreference / Set-StrictMode here ON PURPOSE.
# This file is dot-sourced into other scripts (the F0 probe, later the install
# engine) and those settings would leak into the caller's scope. Every failure
# mode that matters throws explicitly.

$Script:AefosSeedBuildMatrixId = 'AefosPkgOutDir'
$Script:AefosSeedProfileFile   = 'miscellaneousoptions.xml'
$Script:AefosSeedEnvFile       = 'environmentoptions.xml'
$Script:AefosSeedIdeExeName    = 'lazarus.exe'

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function Get-AefosSeedFullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-AefosSeedSamePath {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    try { return ((Get-AefosSeedFullPath $A) -ieq (Get-AefosSeedFullPath $B)) } catch { return $false }
}

function Test-AefosSeedInside {
    param([string]$Child, [string]$Parent)
    if ([string]::IsNullOrWhiteSpace($Child) -or [string]::IsNullOrWhiteSpace($Parent)) { return $false }
    try {
        $p = (Get-AefosSeedFullPath $Parent) + '\'
        $c = (Get-AefosSeedFullPath $Child) + '\'
        return $c.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

# The containment guard. Every byte this engine writes goes through here, so
# "we never write outside our pcp" is a property of the code, not a promise in
# a comment. UTF-8 WITHOUT BOM: that is what Lazarus itself writes, and a BOM in
# a config the IDE re-reads is the kind of difference that bites silently.
function Write-AefosSeedFile {
    param(
        [string]$Root,
        [string]$Path,
        [string]$Content,
        [System.Collections.Generic.List[string]]$Written
    )
    if (-not (Test-AefosSeedInside -Child $Path -Parent $Root)) {
        throw "REFUSING to write outside the isolated pcp: '$Path' is not under '$Root'."
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    if ($null -ne $Written) { [void]$Written.Add((Get-AefosSeedFullPath $Path)) }
}

function Get-AefosSeedXmlChild {
    param([System.Xml.XmlNode]$Parent, [string]$Name)
    $node = $Parent.SelectSingleNode($Name)
    if ($null -eq $node) {
        $doc = $Parent.OwnerDocument
        if ($null -eq $doc) { $doc = [System.Xml.XmlDocument]$Parent }
        $node = $doc.CreateElement($Name)
        [void]$Parent.AppendChild($node)
    }
    return $node
}

# OnlyWhenEmpty is how "only ADD" is honoured inside our own copy of the user's
# file: a value HE set is kept; we only fill what is missing. The few keys that
# MUST be ours (the version stamp, the Lazarus directory, the scratch dirs) are
# written without it, and each one says why at the call site.
function Set-AefosSeedXmlValue {
    param(
        [System.Xml.XmlNode]$Parent,
        [string]$ElementName,
        [string]$AttributeName,
        [string]$Value,
        [switch]$OnlyWhenEmpty
    )
    $node = Get-AefosSeedXmlChild -Parent $Parent -Name $ElementName
    if ($OnlyWhenEmpty) {
        $current = $node.GetAttribute($AttributeName)
        if (-not [string]::IsNullOrWhiteSpace($current)) { return $node }
    }
    $node.SetAttribute($AttributeName, $Value)
    return $node
}

# Serializes through an XmlWriter over a MemoryStream, never a StringWriter: a
# StringWriter is UTF-16 and the writer would stamp encoding="utf-16" into the
# declaration of a file we then save as UTF-8. The declaration is written by
# hand (Lazarus style, uppercase UTF-8) and OmitXmlDeclaration keeps the writer
# from emitting a second one.
function ConvertTo-AefosSeedXmlText {
    param([System.Xml.XmlDocument]$Doc)
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.IndentChars = '  '
    $settings.OmitXmlDeclaration = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $stream = New-Object System.IO.MemoryStream
    $writer = [System.Xml.XmlWriter]::Create($stream, $settings)
    try {
        $Doc.Save($writer)
        $writer.Flush()
    } finally {
        $writer.Dispose()
    }
    $body = (New-Object System.Text.UTF8Encoding($false)).GetString($stream.ToArray())
    return "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n" + $body + "`r`n"
}

function New-AefosSeedXmlDocument {
    param([string]$SeedFrom, [string]$RootName)
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $false
    if (-not [string]::IsNullOrWhiteSpace($SeedFrom) -and (Test-Path -LiteralPath $SeedFrom)) {
        $doc.Load($SeedFrom)
    }
    if ($null -eq $doc.DocumentElement) {
        [void]$doc.AppendChild($doc.CreateElement($RootName))
    }
    # Drop any declaration node; ConvertTo-AefosSeedXmlText writes ours.
    foreach ($node in @($doc.ChildNodes)) {
        if ($node.NodeType -eq [System.Xml.XmlNodeType]::XmlDeclaration) { [void]$doc.RemoveChild($node) }
    }
    return $doc
}

# ---------------------------------------------------------------------------
# Public: read-only facts about the user's tree
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Everything the seed needs to DERIVE from the user's Lazarus tree.
    Reads only. Throws instead of guessing -- a guessed version stamp is the
    bomb this whole slice exists to defuse.
#>
function Get-AefosLazarusTreeInfo {
    param([Parameter(Mandatory = $true)][string]$LazarusDir)

    if ([string]::IsNullOrWhiteSpace($LazarusDir) -or -not (Test-Path -LiteralPath $LazarusDir)) {
        throw "Lazarus directory not found: '$LazarusDir'."
    }
    $root = Get-AefosSeedFullPath $LazarusDir
    foreach ($needed in @('lazbuild.exe', $Script:AefosSeedIdeExeName)) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $needed))) {
            throw "'$root' is not a usable Lazarus tree: '$needed' is missing."
        }
    }

    # lazconf.pp:54  LazarusVersionStr = {$I version.inc};  -- the SAME file the
    # running exe compiles in, which is why deriving from it can never disagree
    # with what main.pp compares against.
    $verInc = Join-Path $root 'ide\packages\ideconfig\version.inc'
    if (-not (Test-Path -LiteralPath $verInc)) {
        throw "Cannot derive the Lazarus version: '$verInc' is missing. Refusing to guess (a wrong Version@Lazarus makes the IDE delete <pcp>\bin and <pcp>\units)."
    }
    $version = ((Get-Content -LiteralPath $verInc -Raw).Trim() -replace "^'", '' -replace "'$", '').Trim()
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Cannot derive the Lazarus version: '$verInc' is empty."
    }

    # ide\revision.inc is a staleness marker only (it is NOT what main.pp
    # compares), so a missing one is not fatal.
    $revision = ''
    $revInc = Join-Path $root 'ide\revision.inc'
    if (Test-Path -LiteralPath $revInc) {
        $revision = ((Get-Content -LiteralPath $revInc -Raw).Trim() -replace "^'", '' -replace "'$", '').Trim()
    }

    $fpcDir = Get-ChildItem -LiteralPath (Join-Path $root 'fpc') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $fpcDir) {
        throw "No FPC version directory under '$root\fpc'. The isolated IDE builds with the FPC that ships with the user's Lazarus."
    }

    # THE TOOLCHAIN TRIPLE, READ FROM DISK INSTEAD OF ASSUMED.
    #
    # Every value below used to be the literal 'i386-win32'. That was not a
    # simplification, it was an assumption that only ever held because every
    # machine we tested on ran a 32-bit Lazarus -- and it is invisible until it
    # is not: on a 64-bit tree the seeded CompilerFilename names an fpc.exe that
    # does not exist, and the fppkg default declares CPU=i386 for an x86_64
    # install. Neither stops lazbuild (it uses its own default target), so this
    # would never announce itself in a build log; it surfaces later, as an IDE
    # whose compiler setting points at nothing.
    #
    # The directory that actually holds fpc.exe IS the answer, so ask it. A tree
    # with exactly one - which is every stock Lazarus, 32-bit or 64-bit - needs
    # no judgement at all. More than one means a cross-compiler install, and
    # there we keep the historical value rather than pick a winner by guesswork:
    # the architecture that decides whether the product WORKS is checked on real
    # machine words elsewhere (Test-AefosPayloadDllArchitecture), not here.
    $fpcPrefix = (Join-Path (Join-Path $root 'fpc') $fpcDir.Name).TrimEnd('\') + '\'
    $triple    = 'i386-win32'
    $tripleDirs = @(Get-ChildItem -LiteralPath (Join-Path $fpcPrefix 'bin') -Directory -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -match '^[A-Za-z0-9_]+-win(32|64)$') -and
                       (Test-Path -LiteralPath (Join-Path $_.FullName 'fpc.exe')) })
    if ($tripleDirs.Count -eq 1) { $triple = $tripleDirs[0].Name }

    return [pscustomobject]@{
        LazarusDir = $root
        Version    = $version
        Revision   = $revision
        FpcVersion = $fpcDir.Name
        FpcPrefix  = $fpcPrefix
        FpcTriple  = $triple
        FpcCpu     = $triple.Split('-')[0]
        FpcOs      = $triple.Split('-')[1]
        LazBuild   = (Join-Path $root 'lazbuild.exe')
        LazarusExe = (Join-Path $root $Script:AefosSeedIdeExeName)
    }
}

<#
.SYNOPSIS
    The production location of OUR pcp: %LOCALAPPDATA%\Aefos\lazarus.
.DESCRIPTION
    LOCALAPPDATA, not APPDATA, and that divergence from the "one brain" rule is
    deliberate: APPDATA roams, and ~240 MB of build output crossing a roaming
    profile in a corporate domain is unacceptable. This is a per-machine BUILD
    CACHE, not the brain. The brain (memory.md, config.json, aefos.db, models)
    stays in %APPDATA%\Aefos and is untouched by this engine.
#>
function Get-AefosIsolatedPcpPath {
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'Aefos') 'lazarus')
}

# ---------------------------------------------------------------------------
# Public: the <pcp>\bin invariants
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Entries in <pcp>\bin that would be destroyed BEFORE DeleteDirectory hits the
    locked lazarus.exe and gives up. Must be empty. Returns @() when there is no
    bin dir or no lazarus.exe yet (nothing to protect).
.DESCRIPTION
    fileutil.inc:104-134 walks with FindFirst (NTFS = case-insensitive name
    order) and EXITS on the first failure. So the ONLY thing standing between
    our install and main.pp:1374 is that lazarus.exe is locked and sorts first.
    Both orderings are checked (ordinal and invariant-culture, ignore case) and
    the union is reported: when they disagree we assume the dangerous answer.
    Directories count too -- DeleteDirectory recurses into a subdirectory that
    sorts earlier and empties it before ever reaching the exe.

    CALLING CONVENTION: assign the call directly ($r = Get-AefosIsolatedBinRisk ...).
    Do NOT write @(Get-AefosIsolatedBinRisk ...): the leading comma in the return
    already hands the array over as ONE pipeline item so an EMPTY result survives,
    and re-wrapping NESTS it -- three planted files then report as "1 risk", which
    is exactly how this was caught. Same for Clear-AefosIsolatedBin.
#>
function Get-AefosIsolatedBinRisk {
    param([Parameter(Mandatory = $true)][string]$BinDir)

    $risks = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $BinDir)) { return , $risks.ToArray() }
    $exe = Join-Path $BinDir $Script:AefosSeedIdeExeName
    if (-not (Test-Path -LiteralPath $exe)) { return , $risks.ToArray() }

    foreach ($entry in (Get-ChildItem -LiteralPath $BinDir -Force)) {
        if ($entry.Name -ieq $Script:AefosSeedIdeExeName) { continue }
        $ordinal   = [string]::Compare($entry.Name, $Script:AefosSeedIdeExeName, [System.StringComparison]::OrdinalIgnoreCase)
        $invariant = [string]::Compare($entry.Name, $Script:AefosSeedIdeExeName, [System.StringComparison]::InvariantCultureIgnoreCase)
        if (($ordinal -lt 0) -or ($invariant -lt 0)) {
            $kind = if ($entry.PSIsContainer) { 'directory' } else { 'file' }
            $risks.Add([pscustomobject]@{
                Name   = $entry.Name
                Kind   = $kind
                Reason = ("sorts before {0} (ordinal={1}, invariant={2}); DeleteDirectory would destroy it before the locked exe stops the loop" -f `
                          $Script:AefosSeedIdeExeName, $ordinal, $invariant)
            })
        }
    }
    # Sorted into its OWN variable first: ",( @() | Sort-Object )" would hand the
    # caller a one-element array containing $null, i.e. the perfect result would
    # be reported as one risk and then blow up on $null.Name.
    $sorted = @($risks.ToArray() | Sort-Object Name)
    return , $sorted
}

<#
.SYNOPSIS
    Post-build hygiene for <pcp>\bin: removes the rolled-aside lazarus.old.exe
    (20.9 MB per rebuild) and reports what is left. Returns the removed names.
#>
function Clear-AefosIsolatedBin {
    param([Parameter(Mandatory = $true)][string]$BinDir)

    $removed = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $BinDir)) { return , $removed.ToArray() }
    foreach ($stale in @('lazarus.old.exe', 'startlazarus.old.exe')) {
        $path = Join-Path $BinDir $stale
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $path)) { [void]$removed.Add($stale) }
        }
    }
    return , $removed.ToArray()
}

# ---------------------------------------------------------------------------
# Public: verify a seeded pcp (used by tests and, later, by the staleness check)
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Does the seeded EnvironmentOptions/Version@Lazarus match the version
    compiled into the exe our own build will produce (= the user's tree)?
    This is check #1 of milestone 2: a False here means main.pp will offer
    Upgrade/Downgrade and then delete <pcp>\bin and <pcp>\units.
#>
function Test-AefosIsolatedPcpStamp {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPcp,
        [Parameter(Mandatory = $true)][string]$LazarusDir
    )
    $expected = (Get-AefosLazarusTreeInfo -LazarusDir $LazarusDir).Version
    $envPath = Join-Path $TargetPcp $Script:AefosSeedEnvFile
    $seeded = ''
    if (Test-Path -LiteralPath $envPath) {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($envPath)
        $node = $doc.SelectSingleNode('/CONFIG/EnvironmentOptions/Version')
        if ($null -ne $node) { $seeded = $node.GetAttribute('Lazarus') }
    }
    return [pscustomobject]@{
        Ok       = ($seeded -eq $expected)
        Seeded   = $seeded
        Expected = $expected
        Path     = $envPath
    }
}

# ---------------------------------------------------------------------------
# Public: THE SEED
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Seeds OUR pcp so `lazbuild --pcp=<TargetPcp> --lazarusdir=<LazarusDir>
    --add-package ... --build-ide=<opts>` produces <TargetPcp>\bin\lazarus.exe
    and writes nothing into the user's tree or the user's config.
.DESCRIPTION
    Files written (all under TargetPcp, all listed in the returned .FilesWritten):
      environmentoptions.xml    the user's file COPIED then patched, or a fresh
                                minimal one; carries the DERIVED version stamp
                                and the BuildMatrix OutDir entry at the XML ROOT
      miscellaneousoptions.xml  the build profile: TargetDirectory=<pcp>\bin,
                                IdeBuildMode=Build, UpdateRevisionInc=False
      fppkg\fppkg.cfg           isolated fppkg so the first launch does not open
      fppkg\config\default      the configure wizard (and so we never touch the
                                machine-global fppkg config the wizard rewrites)

    WHY <pcp>\bin AND NOT A PRETTIER DIRECTORY: ide\lazarusmanager.pas:314 is the
    only place startlazarus looks for an alternative IDE ("<pcp>\bin"), and it
    does NOT read the profile's TargetDirectory. main.pp:1289 also treats
    <pcp>\bin\<exe> as the canonical IDE of that pcp and skips the "this config
    was used by another lazarus" warning. Both facts make the location a
    requirement, not a preference.

    RE-SEEDING IS IDEMPOTENT AND ADDITIVE: when our files already exist they are
    LOADED and patched, never rewritten from scratch -- otherwise a re-seed after
    a build would wipe the StaticAutoInstallPackages list that lazbuild
    --add-package wrote into our own miscellaneousoptions.xml.
#>
function New-AefosIsolatedPcpSeed {
    param(
        [Parameter(Mandatory = $true)][string]$LazarusDir,
        [Parameter(Mandatory = $true)][string]$TargetPcp,
        [string]$UserPcp,
        [string]$ProfileName = 'AefosIDE',
        [switch]$NoPkgOutDirRedirect,
        [string[]]$StaticAutoInstallPackages = @()
    )

    $info = Get-AefosLazarusTreeInfo -LazarusDir $LazarusDir
    $pcp  = Get-AefosSeedFullPath $TargetPcp

    # -- refuse anything that could make US the vandal ----------------------
    if (Test-AefosSeedInside -Child $pcp -Parent $info.LazarusDir) {
        throw "Refusing: the isolated pcp '$pcp' is INSIDE the user's Lazarus tree '$($info.LazarusDir)'."
    }
    if (Test-AefosSeedSamePath $pcp $info.LazarusDir) {
        throw "Refusing: the isolated pcp '$pcp' IS the user's Lazarus tree."
    }
    $realUserPcp = Join-Path $env:LOCALAPPDATA 'lazarus'
    if (Test-AefosSeedSamePath $pcp $realUserPcp) {
        throw "Refusing: '$pcp' is the user's own Lazarus config directory ('$realUserPcp'). The seed never writes there."
    }
    if (-not [string]::IsNullOrWhiteSpace($UserPcp)) {
        if (Test-AefosSeedSamePath $pcp $UserPcp) {
            throw "Refusing: the isolated pcp and the user's pcp are the same directory ('$pcp')."
        }
    }

    New-Item -ItemType Directory -Force -Path $pcp | Out-Null
    $written = New-Object System.Collections.Generic.List[string]

    $binDir      = Join-Path $pcp 'bin'
    $pkgLibDir   = Join-Path $pcp 'pkglib'
    $testBuild   = Join-Path $pcp 'testbuild'
    $fppkgDir    = Join-Path $pcp 'fppkg'
    $fppkgCfgDir = Join-Path $fppkgDir 'config'
    $fppkgCfg    = Join-Path $fppkgDir 'fppkg.cfg'
    $envPath     = Join-Path $pcp $Script:AefosSeedEnvFile
    $miscPath    = Join-Path $pcp $Script:AefosSeedProfileFile

    # -- 1. environmentoptions.xml -----------------------------------------
    # Precedence: our own previous seed > the user's file > nothing. Copying HIS
    # file matters beyond convenience: the --scp seed-once copy
    # (lazconf.pp CopySecondaryConfigFile) only copies a file that does NOT yet
    # exist in the primary config, so once we create this one his own will never
    # be copied in. If we want his settings, we have to bring them here now.
    $seedFrom = ''
    if (Test-Path -LiteralPath $envPath) { $seedFrom = $envPath }
    elseif (-not [string]::IsNullOrWhiteSpace($UserPcp)) {
        $candidate = Join-Path $UserPcp $Script:AefosSeedEnvFile
        if (Test-Path -LiteralPath $candidate) { $seedFrom = $candidate }
    }
    $envDoc = New-AefosSeedXmlDocument -SeedFrom $seedFrom -RootName 'CONFIG'
    $envRoot = $envDoc.DocumentElement
    $envOpts = Get-AefosSeedXmlChild -Parent $envRoot -Name 'EnvironmentOptions'

    # THE STAMP. Forced, never "only when empty": the exe we are about to build
    # is compiled from THIS tree, so this value is a fact about the binary, not a
    # user preference. main.pp:1341-1379 deletes <pcp>\bin and <pcp>\units when
    # it disagrees.
    [void](Set-AefosSeedXmlValue -Parent $envOpts -ElementName 'Version' -AttributeName 'Lazarus' -Value $info.Version)
    # EnvOptsVersion of the file format itself: keep whatever the user's IDE
    # wrote (it knows its own schema); only supply one when there is none.
    [void](Set-AefosSeedXmlValue -Parent $envOpts -ElementName 'Version' -AttributeName 'Value' -Value '110' -OnlyWhenEmpty)

    # Forced: this is where our LCL, sources and translations come from.
    [void](Set-AefosSeedXmlValue -Parent $envOpts -ElementName 'LazarusDirectory' -AttributeName 'Value' -Value $info.LazarusDir)
    # Forced: scratch directories must be on OUR side or the "zero files in the
    # user's tree" claim depends on where his own TestBuildDirectory points.
    [void](Set-AefosSeedXmlValue -Parent $envOpts -ElementName 'TestBuildDirectory' -AttributeName 'Value' -Value ($testBuild.TrimEnd('\') + '\'))
    # Forced: never the machine-global fppkg config -- the IDE's configure wizard
    # REWRITES that file's compiler config to a stub, which would then break the
    # user's own IDE (already learned in build-lazarus.ps1 stage 3).
    [void](Set-AefosSeedXmlValue -Parent $envOpts -ElementName 'FppkgConfigFile' -AttributeName 'Value' -Value $fppkgCfg)
    # Forced: main.pp:1288-1291 compares this against the running exe to decide
    # whether to warn that the config belongs to another lazarus.exe. Copied from
    # the user's file it would name HIS binary.
    [void](Set-AefosSeedXmlValue -Parent $envOpts -ElementName 'LastCalledByLazarusFullPath' -AttributeName 'Value' -Value (Join-Path $binDir $Script:AefosSeedIdeExeName))

    # Only when empty: these are legitimate user choices (he may point at another
    # FPC). A fresh pcp gets the toolchain that ships with his tree.
    # The toolchain triple comes from the tree (Get-AefosLazarusTreeInfo), not from
    # a literal: a 64-bit Lazarus keeps its fpc.exe under x86_64-win64, and naming
    # i386-win32 there points the IDE's compiler setting at a file that is not
    # there.
    #
    # CURE AN OLD PCP BEFORE THE OnlyWhenEmpty WRITE. Deriving the triple fixed
    # FRESH installs only: these two values are written "only when empty", so a pcp
    # seeded by an EARLIER Aefos - which hardcoded i386-win32 - keeps the broken
    # path forever, and reinstalling does not help. A partner's build log carried
    # it four times over:
    #
    #   SetupCompilerFilename: The compiler path "$(Lazarusdir)\fpc\3.2.2\bin\
    #   i386-win32\fpc.exe" => "C:\lazarus64\...\i386-win32\fpc.exe" is invalid
    #   (Error: arquivo nao encontrado) Searching a proper one ...
    #
    # Lazarus recovers by searching, so the build survives - which is exactly why
    # it stayed invisible - but his Options page still names a compiler that does
    # not exist.
    #
    # TWO REASONS TO CURE, and the second one came from a partner's real file.
    #
    # (a) OUR OWN STALE MACRO. A pcp seeded by an earlier Aefos hardcoded
    #     i386-win32; the file it names is simply gone.
    #
    # (b) A COMPILER FOR THE WRONG ARCHITECTURE. His config carried
    #     'C:\lazarus\fpc\3.2.2\bin\i386-win32\fpc.exe' - an ABSOLUTE path, to a
    #     file that EXISTS, in a DIFFERENT Lazarus install (C:\lazarus, 32-bit)
    #     while LazarusDirectory was C:\lazarus64. Neither earlier rule caught it:
    #     it is not our macro, and the file is right there. It arrived because this
    #     function copies his environmentoptions.xml wholesale, so it is not his
    #     choice FOR THIS IDE - it is his choice for his OTHER one.
    #
    # The test that separates the two is architecture, not existence: a path whose
    # <cpu>-<os> segment disagrees with the tree we are building can never be right
    # for this IDE. A path with no recognisable triple ('C:\his-own-fpc\fpc.exe')
    # is left alone - that IS a deliberate choice, and run-pcp-seed-tests guards it
    # (KEEPS-HIS-COMPILER).
    foreach ($cureElement in @('CompilerFilename', 'MakeFilename')) {
        $node = $envOpts.SelectSingleNode($cureElement)
        if ($null -eq $node) { continue }
        $cur = $node.GetAttribute('Value')
        if ([string]::IsNullOrWhiteSpace($cur)) { continue }
        $cure = $false
        # (b) architecture mismatch -- checked FIRST, because it also catches an
        # absolute path, which is the shape that actually reached a user.
        if ($cur -match '(?i)[\\/]([A-Za-z0-9_]+-win(?:32|64))[\\/]') {
            if ($Matches[1] -ine $info.FpcTriple) { $cure = $true }
        }
        # (a) our own macro, now naming a file that is not there.
        if ((-not $cure) -and ($cur -match '(?i)^\$\(Lazarusdir\)')) {
            $resolved = $cur -replace '(?i)\$\(Lazarusdir\)', $info.LazarusDir
            if (($resolved -notmatch '\$\(') -and (-not (Test-Path -LiteralPath $resolved))) { $cure = $true }
        }
        if ($cure) { $node.SetAttribute('Value', '') }
    }

    # HIS WINDOW LAYOUT IS NOT PORTABLE TO OUR BINARY -- drop it.
    #
    # A desktop records which IDE forms were open and how they were docked, BY
    # FORM ID. Those ids belong to the packages installed in the IDE that saved
    # them, and ours is by construction a DIFFERENT binary with a different set:
    # we install a FILTERED subset of his packages, and any package that fails to
    # build is deliberately left out.
    #
    # A partner's file showed exactly what that produces. His active desktop was a
    # custom one, "Mauricio docker", and its form list named
    # 'PackageEditor_CEF4Delphi_Lazarus' -- the package editor of CEF4Delphi_Lazarus,
    # one of the three packages whose broken dependencies kept it OUT of his Aefos
    # IDE. So our IDE was starting up told to restore a docked arrangement built
    # around a form it does not have, and he reported an access violation when
    # opening Options.
    #
    # That AV is NOT proven to come from here, and this is not being sold as its
    # fix. The justification stands on its own: importing a layout that references
    # forms we did not install is wrong whether or not it is what faulted. Losing
    # it costs him nothing he did not already lack - the arrangement was for a
    # different IDE - and our IDE builds its own default layout on first run.
    # AT THE XML ROOT, not under <EnvironmentOptions> -- the same placement trap
    # this function already documents for <BuildMatrix> below (environmentopts.pp
    # resolves both from the ROOT). Removing it from $envOpts silently does
    # nothing, which is exactly what the first attempt here did.
    $desktops = $envRoot.SelectSingleNode('Desktops')
    if ($null -ne $desktops) {
        [void]$envRoot.RemoveChild($desktops)
        Write-Host '  dropped his saved window layout (Desktops): it names forms of packages this IDE does not install' -ForegroundColor DarkGray
    }
    [void](Set-AefosSeedXmlValue -Parent $envOpts -ElementName 'CompilerFilename' -AttributeName 'Value' `
        -Value ('$(Lazarusdir)\fpc\' + $info.FpcVersion + '\bin\' + $info.FpcTriple + '\fpc.exe') -OnlyWhenEmpty)
    [void](Set-AefosSeedXmlValue -Parent $envOpts -ElementName 'FPCSourceDirectory' -AttributeName 'Value' `
        -Value '$(LazarusDir)\fpc\$(FPCVer)\source' -OnlyWhenEmpty)
    [void](Set-AefosSeedXmlValue -Parent $envOpts -ElementName 'MakeFilename' -AttributeName 'Value' `
        -Value ('$(Lazarusdir)\fpc\' + $info.FpcVersion + '\bin\' + $info.FpcTriple + '\make.exe') -OnlyWhenEmpty)

    # Debugger: the configure wizard demands one. Add FpDebug only when the user
    # has no debugger configured at all -- his own choice wins.
    $dbgNode = $envOpts.SelectSingleNode('Debugger/Configs/Config')
    if ($null -eq $dbgNode) {
        $dbg     = Get-AefosSeedXmlChild -Parent $envOpts -Name 'Debugger'
        $configs = Get-AefosSeedXmlChild -Parent $dbg -Name 'Configs'
        $cfg     = Get-AefosSeedXmlChild -Parent $configs -Name 'Config'
        $cfg.SetAttribute('ConfigName', 'FpDebug')
        $cfg.SetAttribute('ConfigClass', 'TFpDebugDebugger')
        $cfg.SetAttribute('Active', 'True')
        $cfg.SetAttribute('UID', '{B843F352-7E49-4510-A431-3A26F3BC7E58}')
    }

    # THE BUILD MATRIX -- at the XML ROOT, next to <EnvironmentOptions> and NOT
    # inside it (environmentopts.pp:1579 + :943; see the header). Additive: an
    # entry the user already had is preserved, ours is appended as Item<Count+1>
    # (or updated in place when a previous seed already added it).
    if (-not $NoPkgOutDirRedirect) {
        $matrix = Get-AefosSeedXmlChild -Parent $envRoot -Name 'BuildMatrix'
        $count = 0
        $countAttr = $matrix.GetAttribute('Count')
        if (-not [string]::IsNullOrWhiteSpace($countAttr)) { [void][int]::TryParse($countAttr, [ref]$count) }
        $ours = $null
        for ($i = 1; $i -le $count; $i++) {
            $item = $matrix.SelectSingleNode(('Item{0}' -f $i))
            if (($null -ne $item) -and ($item.GetAttribute('ID') -eq $Script:AefosSeedBuildMatrixId)) { $ours = $item; break }
        }
        if ($null -eq $ours) {
            $count++
            $ours = $envDoc.CreateElement(('Item{0}' -f $count))
            [void]$matrix.AppendChild($ours)
        }
        $ours.SetAttribute('ID', $Script:AefosSeedBuildMatrixId)
        $ours.SetAttribute('Targets', '*')
        # 'default' literally: BuildMatrixModeFits rejects an empty pattern and,
        # with no project loaded, the active build mode is named 'default'.
        $ours.SetAttribute('Modes', 'default')
        $ours.SetAttribute('Type', 'OutDir')
        $ours.SetAttribute('Value', (Join-Path $pkgLibDir '$(PkgName)\$(TargetCPU)-$(TargetOS)'))
        $matrix.SetAttribute('Count', [string]$count)
    }

    Write-AefosSeedFile -Root $pcp -Path $envPath -Content (ConvertTo-AefosSeedXmlText -Doc $envDoc) -Written $written

    # -- 2. miscellaneousoptions.xml (the build profile) --------------------
    # The FILE is miscellaneousoptions.xml (ide\miscoptions.pas MiscOptsFilename).
    # Seeding a file named miscoptions.xml is ignored IN SILENCE and the build
    # falls back to CalcTargets case 4, which writes INTO the user's tree.
    $miscDoc = New-AefosSeedXmlDocument -SeedFrom $(if (Test-Path -LiteralPath $miscPath) { $miscPath } else { '' }) -RootName 'CONFIG'
    $miscOpts = Get-AefosSeedXmlChild -Parent $miscDoc.DocumentElement -Name 'MiscellaneousOptions'
    [void](Set-AefosSeedXmlValue -Parent $miscOpts -ElementName 'Version' -AttributeName 'Value' -Value '3' -OnlyWhenEmpty)
    $buildOpts = Get-AefosSeedXmlChild -Parent $miscOpts -Name 'BuildLazarusOptions'
    $profiles  = Get-AefosSeedXmlChild -Parent $buildOpts -Name 'Profiles'
    $profiles.SetAttribute('Count', '1')
    $profile0 = Get-AefosSeedXmlChild -Parent $profiles -Name 'Profile0'
    $profile0.SetAttribute('Name', $ProfileName)
    # TargetDirectory is what makes buildlazdialog.pas CalcTargets take case 1
    # (the user set a target dir) instead of case 4 (write into the tree), and
    # what puts BOTH the exe and its units on our side.
    [void](Set-AefosSeedXmlValue -Parent $profile0 -ElementName 'TargetDirectory' -AttributeName 'Value' -Value $binDir)
    [void](Set-AefosSeedXmlValue -Parent $profile0 -ElementName 'IdeBuildMode' -AttributeName 'Value' -Value 'Build')
    # False: regenerating ide\revision.inc would be a WRITE into the user's tree.
    [void](Set-AefosSeedXmlValue -Parent $profile0 -ElementName 'UpdateRevisionInc' -AttributeName 'Value' -Value 'False')
    [void](Set-AefosSeedXmlValue -Parent $buildOpts -ElementName 'ProfileIndex' -AttributeName 'Value' -Value '0')

    # Optional pre-seeded install list. lazbuild --add-package maintains this list
    # itself, so the normal path passes nothing; the parameter exists for the
    # component-import slice, where the list is built from the user's own (after
    # filtering out packages that no longer resolve). Item1..ItemN with a real
    # Count and no holes -- a hole makes the IDE drop the tail in silence.
    if (@($StaticAutoInstallPackages).Count -gt 0) {
        $old = $buildOpts.SelectSingleNode('StaticAutoInstallPackages')
        if ($null -ne $old) { [void]$buildOpts.RemoveChild($old) }
        $list = Get-AefosSeedXmlChild -Parent $buildOpts -Name 'StaticAutoInstallPackages'
        $index = 0
        foreach ($pkg in $StaticAutoInstallPackages) {
            if ([string]::IsNullOrWhiteSpace($pkg)) { continue }
            $index++
            $item = $miscDoc.CreateElement(('Item{0}' -f $index))
            $item.SetAttribute('Value', $pkg)
            [void]$list.AppendChild($item)
        }
        $list.SetAttribute('Count', [string]$index)
    }

    Write-AefosSeedFile -Root $pcp -Path $miscPath -Content (ConvertTo-AefosSeedXmlText -Doc $miscDoc) -Written $written

    # -- 3. isolated fppkg --------------------------------------------------
    # fppkg's IsProperlyConfigured (fppkghelper.pas) must resolve the 'rtl'
    # package or the IDE opens the configure wizard on first launch. Shape
    # mirrors scripts\build-lazarus.ps1 stage 3. {LocalRepository} is a literal
    # fppkg macro, hence the single-quoted here-strings.
    New-Item -ItemType Directory -Force -Path $fppkgCfgDir | Out-Null
    $fppkgBody = @'
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
    $fppkgBody = $fppkgBody.Replace('__LOCALREPO__', ($fppkgDir.TrimEnd('\') + '\')).Replace('__FPCPREFIX__', $info.FpcPrefix)
    Write-AefosSeedFile -Root $pcp -Path $fppkgCfg -Content $fppkgBody -Written $written

    $fppkgDefault = @'
[Defaults]
ConfigVersion=5
GlobalPrefix=__FPCPREFIX__
LocalPrefix={LocalRepository}
GlobalInstallDir={GlobalPrefix}
LocalInstallDir={LocalPrefix}
Compiler=__FPCPREFIX__bin\__FPCTRIPLE__\fpc.exe
OS=__FPCOS__
CPU=__FPCCPU__
Version=__FPCVER__
'@
    $fppkgDefault = $fppkgDefault.Replace('__FPCPREFIX__', $info.FpcPrefix).Replace('__FPCVER__', $info.FpcVersion).
        Replace('__FPCTRIPLE__', $info.FpcTriple).Replace('__FPCOS__', $info.FpcOs).Replace('__FPCCPU__', $info.FpcCpu)
    Write-AefosSeedFile -Root $pcp -Path (Join-Path $fppkgCfgDir 'default') -Content $fppkgDefault -Written $written

    return [pscustomobject]@{
        Pcp             = $pcp
        BinDir          = $binDir
        IdeExe          = (Join-Path $binDir $Script:AefosSeedIdeExeName)
        PkgOutDir       = $(if ($NoPkgOutDirRedirect) { '' } else { $pkgLibDir })
        LazarusDir      = $info.LazarusDir
        LazarusVersion  = $info.Version
        FpcVersion      = $info.FpcVersion
        SeededEnvFrom   = $seedFrom
        ProfileName     = $ProfileName
        FilesWritten    = $written.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Stand-alone entry point. Dot-sourcing ('. .\aefos-laz-seed-pcp.ps1') defines
# the functions and runs nothing.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($LazarusDir) -or [string]::IsNullOrWhiteSpace($TargetPcp)) {
        throw 'Both -LazarusDir and -TargetPcp are required when running this script directly.'
    }
    $result = New-AefosIsolatedPcpSeed -LazarusDir $LazarusDir -TargetPcp $TargetPcp -UserPcp $UserPcp `
        -ProfileName $ProfileName -NoPkgOutDirRedirect:$NoPkgOutDirRedirect `
        -StaticAutoInstallPackages $StaticAutoInstallPackages
    Write-Host '-- Aefos isolated pcp seeded --'
    Write-Host ("  pcp            : {0}" -f $result.Pcp)
    Write-Host ("  ide exe target : {0}" -f $result.IdeExe)
    Write-Host ("  lazarus tree   : {0}" -f $result.LazarusDir)
    Write-Host ("  version stamp  : {0}  (derived from ide\packages\ideconfig\version.inc)" -f $result.LazarusVersion)
    Write-Host ("  package outdir : {0}" -f $(if ($result.PkgOutDir) { $result.PkgOutDir } else { '(not redirected)' }))
    Write-Host ("  seeded env from: {0}" -f $(if ($result.SeededEnvFrom) { $result.SeededEnvFrom } else { '(fresh)' }))
    Write-Host '  files written  :'
    foreach ($f in $result.FilesWritten) { Write-Host ("    {0}" -f $f) }
}
