<#
.SYNOPSIS
    MILESTONE 2 / SLICES F3+F4 -- the LAYOUT of the isolated Aefos Lazarus IDE,
    declared ONCE and read by everybody: the install engine, the uninstall engine
    and the gate. Plus the containment guards that make "we never write on the
    user's side" a property of the code instead of a promise in a comment.

.DESCRIPTION
    WHY A THIRD FILE AND NOT MORE PARAMETERS
    ----------------------------------------
    Three programs need the SAME answer to "where does each thing live, and why is
    it allowed to be there": the installer (it puts things there), the uninstaller
    (it removes exactly those things and nothing else) and the gate (it proves the
    other two). Duplicating the answer three times is how an installer and an
    uninstaller drift apart -- which is the whole class of bug milestone 2 exists
    to end. So the layout is DATA, in one file, and the gate asserts that what is
    on disk after a real install matches that data ENTRY BY ENTRY. "Justify every
    file that leaves the build" stops being a paragraph in a report and becomes an
    executable check: an undeclared entry fails the gate.

    NO param() BLOCK ON PURPOSE
    ---------------------------
    This file is dot-sourced by scripts that have parameters of their own. A
    param() block here would run in the CALLER'S scope and blank same-named
    variables -- the trap already documented in aefos-laz-import-components.ps1 and
    in the F0 probe. With no parameters and no side effects, dot-sourcing this is
    safe from anywhere, at any point.

    THE TWO INVARIANTS THIS FILE ENFORCES
    -------------------------------------
    1. WRITE CONTAINMENT. Every byte an install writes goes through
       Copy-AefosIsolatedPayload or through Write-AefosSeedFile (the F1 twin), and
       both REFUSE a destination outside the isolated pcp. The only deliberate
       exceptions are the SHORTCUTS: one .lnk in the user's OWN Start menu, and -
       when he ticks the box on the wizard - one on his OWN desktop. Each is named
       in the result of the install and removed by the uninstall, and each lands in
       a directory Get-AefosIsolatedWriteRoots has already proved is inside his
       profile.

    2. THE <pcp>\bin SORT ORDER. ide\main.pp TMainIDE.LoadGlobalOptions runs
       DeleteDirectory(PCP+'bin') when the config's version stamp disagrees with
       the exe, and DeleteDirectory (components\lazutils\fileutil.inc:104-134) is
       ONE FindFirst pass -- files and subdirectories interleaved in name order --
       that EXITS on the first failure. The running lazarus.exe is locked by
       Windows, so everything that sorts AFTER it survives and everything that
       sorts BEFORE it is already gone. Measured live in F0 with a canary.
       Therefore NOTHING we put in <pcp>\bin may sort before 'lazarus.exe', and
       that is checked BEFORE the copy, not after:

         lazarus.exe        vs  libvterm.dll         'la' < 'li'  -> exe first, SAFE
         lazarus.exe        vs  sqlite3.dll          'l'  < 's'   -> exe first, SAFE
         lazarus.exe        vs  WebView2Loader.dll   'l'  < 'w'   -> exe first, SAFE
         lazarus.exe        vs  units\ (dir)         'l'  < 'u'   -> exe first, SAFE
         lazarus.exe        vs  lazarus.old.exe      '.e' < '.o'  -> exe first, SAFE

       The margin on libvterm.dll is ONE CHARACTER, and the landmine is obvious
       once stated: our own brand prefix, 'aefos-*', sorts BEFORE lazarus.exe. Any
       future "aefos-helper.dll" dropped beside the exe would be destroyed by the
       IDE itself on the first version mismatch. Test-AefosIsolatedBinNameSafe is
       the gate on that, and it runs before every copy.

.EXAMPLE
    . .\scripts\aefos-laz-isolated-layout.ps1
    $pcp = Get-AefosIsolatedInstallPcp
#>

# NOTE: no file-scope $ErrorActionPreference / Set-StrictMode -- this file is
# dot-sourced into other scripts and those settings would leak into the caller.

$Script:AefosIsolatedIdeExeName   = 'lazarus.exe'
$Script:AefosIsolatedStampFile    = 'aefos-ide.json'

# THE NAME OF OUR IDE, IN ONE PLACE.
#
# It is a NOUN, not a preposition: what the installer produces is a Lazarus IDE
# OF ITS OWN, built from the user's tree and living in his profile - not an
# add-on installed INTO the Lazarus he already has. "Aefos AI for Lazarus" said
# the second thing, and that is exactly what made a user think his own IDE had
# been taken over. This entry has to stand on its own, because Windows Search,
# the taskbar tooltip and a desktop shortcut show the .lnk name WITHOUT the
# 'Aefos AI' program group around it.
#
# The install engine, the uninstall engine and the gate all read THIS variable;
# none of them may carry a literal of its own.
$Script:AefosIsolatedShortcutName = 'Aefos AI Lazarus IDE'
$Script:AefosIsolatedGroupName    = 'Aefos AI'

# Names this shortcut has had before. An install must delete these, or a machine
# that already carries an older build ends up with TWO entries pointing at the
# same exe - and the uninstall (which removes one name) would leave the other
# behind, dangling. Append here, never edit in place.
$Script:AefosIsolatedLegacyShortcutNames = @('Aefos AI for Lazarus')

# The application icon the installer stages, and the one the RUNNING IDE loads
# into Application.Icon (source\lazarus\ide\Aefos.Lazarus.AppIdentity.pas). Both
# copies come from the same file in the payload: the .lnk points at the one in
# {app}, and the IDE reads the one the .iss stages into the shared per-user
# brand folder %APPDATA%\Aefos, beside aefos-about-logo.png.
$Script:AefosIsolatedIconFileName = 'aefos-lazarus.ico'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Where the isolated IDE lives: %LOCALAPPDATA%\Aefos\lazarus.
.DESCRIPTION
    LOCALAPPDATA and not APPDATA, and that divergence from the "one brain" rule is
    deliberate and narrow: APPDATA roams, and ~240 MB of build output crossing a
    roaming profile in a corporate domain is unacceptable. What lives here is a
    per-machine BUILD ARTEFACT, not the brain. The brain (memory.md, config.json,
    aefos.db, models.json, the addons) stays in %APPDATA%\Aefos, is shared with the
    Delphi edition, and is never touched by either engine.

    This MUST agree with Get-AefosIsolatedPcpPath in scripts\aefos-laz-seed-pcp.ps1
    (the F1 engine computes the same path for the seed). The gate dot-sources both
    and asserts they are equal, so a drift cannot ship.
#>
function Get-AefosIsolatedInstallPcp {
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'Aefos') 'lazarus')
}

<#
.SYNOPSIS
    The user's OWN Start-menu program group: %APPDATA%\Microsoft\Windows\Start Menu\
    Programs\Aefos AI. Per-user, so creating the shortcut needs no elevation.
#>
function Get-AefosIsolatedShortcutDir {
    return (Join-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') $Script:AefosIsolatedGroupName)
}

<#
.SYNOPSIS
    The user's OWN desktop folder, when he asked for a desktop shortcut. Per-user,
    so no elevation - exactly like the Start-menu entry.
.DESCRIPTION
    TWO SOURCES, AND THE ORDER IS A SAFETY PROPERTY, NOT A PREFERENCE.

    The shell knows where the desktop really is - OneDrive's Known Folder Move
    relocates it to %USERPROFILE%\OneDrive\<localised name>, and %USERPROFILE%\
    Desktop is then an empty leftover nobody sees. So SHGetFolderPath (via
    [Environment]::GetFolderPath) is asked FIRST, or a shortcut could land in a
    folder the user never looks at.

    But that answer comes from the REGISTRY, and the registry does not follow a
    redirected environment. The isolated round-trip gate
    runs the engines with USERPROFILE/APPDATA/LOCALAPPDATA pointed into a staged
    profile precisely so their production defaults are what gets tested - and a
    shell answer taken at face value there would put a test's shortcut on the
    MAINTAINER'S REAL DESKTOP, and let a test's uninstall delete from it.

    Hence the containment rule: the shell answer is used ONLY when it lies inside
    the CURRENT %USERPROFILE%. Under a redirected profile it never does, so the
    fallback (<profile>\Desktop) is what the engines use and the stage is what the
    gate measures. On a real machine both the plain and the OneDrive desktop are
    inside the profile, so the shell answer wins and the shortcut is visible.

    The same rule doubles as the elevation guard: whatever comes out of here is
    inside the profile by construction, so Get-AefosIsolatedWriteRoots can never be
    handed a machine-wide desktop (%PUBLIC%\Desktop) to write to.
#>
function Get-AefosIsolatedDesktopDir {
    $profileRoot = $env:USERPROFILE
    $fallback = ''
    if (-not [string]::IsNullOrWhiteSpace($profileRoot)) {
        $fallback = (Join-Path $profileRoot 'Desktop')
    }
    $shell = ''
    try { $shell = [Environment]::GetFolderPath('DesktopDirectory') } catch { $shell = '' }
    if ((-not [string]::IsNullOrWhiteSpace($shell)) -and (Test-AefosIsolatedPathUnder -Child $shell -Parent $profileRoot)) {
        return $shell
    }
    return $fallback
}

<#
.SYNOPSIS
    The .lnk files an EARLIER name of our shortcut left in this directory, and
    that still exist. Both engines call it: the install removes them right after
    writing the current one, the uninstall removes them alongside it.
.DESCRIPTION
    A renamed shortcut is not a cosmetic change: the uninstall deletes ONE path,
    computed from the current name, so a stale one would survive the removal of
    the IDE it points at. Deliberately narrow - it matches the recorded legacy
    names EXACTLY, never a wildcard, so an unrelated .lnk a user put in his own
    'Aefos AI' group is never touched.

    Called once per DIRECTORY that may hold one of our entries: the Start-menu
    group and - since the desktop shortcut - the user's desktop. The exact-name
    rule matters more there than anywhere else: a desktop is full of shortcuts the
    user owns, starting with the lazarus.lnk that opens HIS Lazarus, and a
    wildcard over 'Aefos*' or over '*lazarus*' would eventually eat one of them.
#>
function Get-AefosIsolatedLegacyShortcutPaths {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $found = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Directory)) { return $found.ToArray() }
    foreach ($legacy in $Script:AefosIsolatedLegacyShortcutNames) {
        if ($legacy -ieq $Script:AefosIsolatedShortcutName) { continue }
        $path = Join-Path $Directory ($legacy + '.lnk')
        if (Test-Path -LiteralPath $path) { [void]$found.Add($path) }
    }
    return $found.ToArray()
}

function Get-AefosIsolatedFullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-AefosIsolatedSamePath {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    try { return ((Get-AefosIsolatedFullPath $A) -ieq (Get-AefosIsolatedFullPath $B)) } catch { return $false }
}

function Test-AefosIsolatedPathUnder {
    param([string]$Child, [string]$Parent)
    if ([string]::IsNullOrWhiteSpace($Child) -or [string]::IsNullOrWhiteSpace($Parent)) { return $false }
    try {
        $p = (Get-AefosIsolatedFullPath $Parent) + '\'
        $c = (Get-AefosIsolatedFullPath $Child) + '\'
        return $c.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

# ---------------------------------------------------------------------------
# The <pcp>\bin sort-order rule (see the header for why it is not optional)
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    May a file or directory with this name sit in <pcp>\bin?
.DESCRIPTION
    True only when the name sorts AFTER lazarus.exe under BOTH orderings we can
    plausibly meet (ordinal and invariant-culture, both ignoring case). When the
    two disagree we take the dangerous answer -- FindFirst order is the OS's, not
    ours, and a difference of opinion is not something to bet an install on.
#>
function Test-AefosIsolatedBinNameSafe {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name -ieq $Script:AefosIsolatedIdeExeName) { return $true }
    $ordinal   = [string]::Compare($Name, $Script:AefosIsolatedIdeExeName, [System.StringComparison]::OrdinalIgnoreCase)
    $invariant = [string]::Compare($Name, $Script:AefosIsolatedIdeExeName, [System.StringComparison]::InvariantCultureIgnoreCase)
    return (($ordinal -gt 0) -and ($invariant -gt 0))
}

# ---------------------------------------------------------------------------
# TARGET ARCHITECTURE -- the question the installer never asked
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    The machine architecture a PE image (.exe/.dll) was built for: 'i386',
    'x86_64', 'arm64', or '' when the file cannot be read as a PE at all.
.DESCRIPTION
    WHY THIS EXISTS. This installer does not ship a lazarus.exe -- it BUILDS one,
    with the user's own FPC, so the architecture of what we produce is HIS, not
    ours. What we do ship as fixed binaries are the three runtime DLLs, and every
    one of them was built i386 (see build-libvterm-fpc.ps1 / build-sqlite-fpc.ps1,
    which to this day refuse a 64-bit gcc). On a 64-bit Lazarus those two facts
    collide: our 64-bit exe LOAD-TIME imports a 32-bit libvterm.dll -- every
    vterm_* is declared `external cLibVTerm` in
    source\terminal\Core\Aefos.OTA.Terminal.Core.LibVTerm.pas, which puts them in
    the import table -- so the Windows loader refuses the process before a single
    line of our code runs. The user sees 0xc000007b (STATUS_INVALID_IMAGE_FORMAT)
    and a built, installed, completely dead IDE.

    Read straight from the file, no subprocess: e_lfanew at 0x3C, then the COFF
    Machine word right after the 4-byte 'PE\0\0' signature.
#>
function Get-AefosPeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                                         [System.IO.FileAccess]::Read,
                                         [System.IO.FileShare]::ReadWrite)
        if ($stream.Length -lt 0x40) { return '' }
        $reader = New-Object System.IO.BinaryReader($stream)
        $stream.Position = 0
        if ($reader.ReadUInt16() -ne 0x5A4D) { return '' }   # 'MZ'
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if (($peOffset -le 0) -or (($peOffset + 6) -ge $stream.Length)) { return '' }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return '' } # 'PE\0\0'
        switch ($reader.ReadUInt16()) {
            0x014C  { return 'i386' }
            0x8664  { return 'x86_64' }
            0xAA64  { return 'arm64' }
            default { return '' }
        }
    } catch {
        return ''
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

<#
.SYNOPSIS
    The CPU the Aefos IDE will be built FOR when compiled from this Lazarus:
    'i386', 'x86_64', 'arm64', or '' when it cannot be determined.
.DESCRIPTION
    Answered from lazbuild.exe's own PE header, and that choice is deliberate.
    We could ask `fpc -iTP`, but fpc.exe is not reliably on PATH and its location
    inside the Lazarus tree is exactly the thing that varies by architecture --
    a chicken-and-egg. lazbuild.exe, on the other hand, is the ONE file this
    installer already requires to exist (the wizard refuses without it), and a
    Lazarus distribution's lazbuild is built by, and for, the same FPC that will
    build the IDE. Its bitness is therefore the honest proxy for what our rebuild
    produces.

    Returns '' rather than guessing. Callers decide whether an unknown answer
    fails open (the wizard, mirroring the version gate) or closed (the payload
    check, which compares real machine words and needs no guess at all).
#>
function Get-AefosLazarusTargetCpu {
    # AllowEmptyString: "no directory" is a legitimate question with a legitimate
    # answer ('', decide for yourself), and the body already says so. A binding
    # error instead would turn an unknown into a crash at the exact moment the
    # caller is trying to degrade gracefully.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$LazarusDir)
    if ([string]::IsNullOrWhiteSpace($LazarusDir)) { return '' }
    return (Get-AefosPeMachine -Path (Join-Path $LazarusDir 'lazbuild.exe'))
}

<#
.SYNOPSIS
    The payload subdirectory name for a target CPU ('i386' -> 'i386').
.DESCRIPTION
    A seam, not a formality: it is the single place that decides what an
    architecture-specific redist folder is CALLED, so the build script that
    stages the DLLs, the installer that packs them and the engine that copies
    them cannot drift into disagreeing about a folder name.
#>
function Get-AefosPayloadCpuFolder {
    param([Parameter(Mandatory = $true)][string]$TargetCpu)
    return $TargetCpu
}

# ---------------------------------------------------------------------------
# The runtime DLLs that move from the user's tree to OUR bin
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    The three runtime DLLs the Aefos IDE binds, with WHERE they come from and WHY
    they now live beside OUR exe instead of beside HIS.
.DESCRIPTION
    In the in-place model these three were copied into the user's Lazarus folder,
    overwriting whatever was there. That produced the worst single defect of the
    old installer: a user who kept his own sqlite3.dll beside lazarus.exe (which is
    what every Lazarus SQLdb tutorial tells him to do) had it replaced by ours and
    then DELETED by our uninstall. In the isolated model the DLLs sit next to OUR
    lazarus.exe, in OUR directory, so those three mutations of his tree disappear
    by construction -- there is nothing to overwrite and nothing to restore.

    Source resolution order: the {app} payload the installer ships (Inno drops all
    three at the root of {app}), then the repo build outputs, so the same engine
    runs from a packed install and from a developer checkout.

    ARCHITECTURE. Pass -TargetCpu and every per-CPU location is searched FIRST,
    with the flat locations kept as the tail of the list. That ordering is what
    makes the change additive: a payload that only has the historical i386 DLLs
    at the root still resolves exactly as it did before, and a payload that also
    carries redist\x86_64\ wins on a 64-bit target without any caller changing.
    Resolution alone is NOT the guard, though -- a folder name is a claim, not a
    fact. Test-AefosPayloadDllArchitecture reads the machine word of whatever was
    actually resolved, which is the only thing that cannot lie.
#>
function Get-AefosIsolatedPayloadDlls {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [string]$TargetCpu = ''
    )
    $root = Get-AefosIsolatedFullPath $SourceRoot

    # Per-CPU locations, in front of the flat ones. Both the {app} layout the
    # installer produces (<app>\<cpu>\) and the repo layout the build produces
    # (installer\lazarus\redist\<cpu>\) are covered, for the same reason the flat
    # list covers both: one engine, packed install and developer checkout alike.
    function _Cands {
        param([string]$Name, [string[]]$Flat)
        $out = @()
        if (-not [string]::IsNullOrWhiteSpace($TargetCpu)) {
            $cpu = Get-AefosPayloadCpuFolder -TargetCpu $TargetCpu
            $out += (Join-Path $root (Join-Path $cpu $Name))
            $out += (Join-Path $root (Join-Path ('installer\lazarus\redist\' + $cpu) $Name))
        }
        return ($out + $Flat)
    }

    return @(
        [pscustomobject]@{
            Name       = 'WebView2Loader.dll'
            Candidates = (_Cands 'WebView2Loader.dll' @((Join-Path $root 'WebView2Loader.dll'),
                                                        (Join-Path $root 'installer\lazarus\WebView2Loader.dll')))
            Why        = 'the chat panel renders through WebView2; the loader must sit beside the exe that binds it'
        }
        [pscustomobject]@{
            Name       = 'sqlite3.dll'
            Candidates = (_Cands 'sqlite3.dll' @((Join-Path $root 'sqlite3.dll'),
                                                 (Join-Path $root 'installer\lazarus\redist\sqlite3.dll'),
                                                 (Join-Path $root 'installer\lazarus\sqlite3.dll'),
                                                 (Join-Path $root 'source\data\ThirdParty\sqlite\bin\sqlite3.dll')))
            Why        = 'the chat session store opens the shared %APPDATA%\Aefos\aefos.db through a runtime sqlite3.dll'
        }
        [pscustomobject]@{
            Name       = 'libvterm.dll'
            Candidates = (_Cands 'libvterm.dll' @((Join-Path $root 'libvterm.dll'),
                                                  (Join-Path $root 'installer\lazarus\redist\libvterm.dll'),
                                                  (Join-Path $root 'installer\lazarus\libvterm.dll'),
                                                  (Join-Path $root 'source\terminal\ThirdParty\libvterm\obj\libvterm.dll')))
            Why        = 'the terminal panel binds libvterm as a runtime DLL (external ''libvterm.dll'')'
        }
    )
}

<#
.SYNOPSIS
    Does every runtime DLL we are about to install match the architecture of the
    IDE we are about to build? Returns one result object per DLL, each carrying
    Name / Path / Machine / Ok / Detail.
.DESCRIPTION
    THE GUARD THIS INSTALLER WAS MISSING, and the one defect a "did it compile"
    gate can never catch: the build succeeded on the partner's machine. FPC
    compiled every Aefos unit for x86_64 without a complaint, the installer
    reported success, and the IDE was bricked anyway -- because success was
    measured on the wrong artifact. What decides whether the IDE starts is not
    our Pascal, it is the machine word of three C DLLs.

    LOAD-TIME versus RUNTIME matters for the message, not for the verdict. Only
    libvterm.dll is imported by the loader (the process dies at 0xc000007b before
    main); sqlite3.dll and WebView2Loader.dll are LoadLibrary'd, so a mismatch
    there yields an IDE that starts and then has no chat sessions and no chat
    rendering. Neither is shippable, so both are Ok=$false -- but the caller can
    tell the user which one he is looking at.

    A DLL that cannot be resolved at all is NOT reported here: that is the
    pre-existing "missing payload" failure and it has its own message. This asks
    one question only, of the files that exist.
#>
function Test-AefosPayloadDllArchitecture {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TargetCpu
    )
    $results = @()
    foreach ($dll in (Get-AefosIsolatedPayloadDlls -SourceRoot $SourceRoot -TargetCpu $TargetCpu)) {
        $found = $null
        foreach ($cand in $dll.Candidates) {
            if (Test-Path -LiteralPath $cand -PathType Leaf) { $found = $cand; break }
        }
        if (-not $found) { continue }
        $machine = Get-AefosPeMachine -Path $found
        $ok      = ($machine -eq $TargetCpu)
        $detail  = ''
        if (-not $ok) {
            $detail = if ($dll.Name -ieq 'libvterm.dll') {
                'imported at LOAD TIME - the IDE will not start at all (0xc000007b)'
            } else {
                'loaded at RUNTIME - the IDE starts, but this feature is dead'
            }
        }
        $results += [pscustomobject]@{
            Name    = $dll.Name
            Path    = $found
            Machine = $machine
            Ok      = $ok
            Detail  = $detail
        }
    }
    return $results
}

# ---------------------------------------------------------------------------
# THE MANIFEST -- every entry that may exist after an install, and why
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    What a finished install is ALLOWED to leave under <pcp> and under <pcp>\bin,
    with the reason each entry earns its place. The gate walks the real directory
    and fails on anything not declared here.
.DESCRIPTION
    Scope 'Pcp' entries are top-level names directly under the isolated pcp; scope
    'Bin' entries are top-level names under <pcp>\bin. Required=$true means the
    install is broken without it. Kind is informational and is what the install
    prints as its layout report.
#>
function Get-AefosIsolatedLayoutManifest {
    @(
        # -- <pcp>\bin : the IDE itself ---------------------------------------
        [pscustomobject]@{ Scope='Bin'; Name='lazarus.exe'; Kind='binary'; Required=$true
            Why='OUR IDE. It MUST be exactly here: ide\lazarusmanager.pas:314 is the only place startlazarus looks for an alternative IDE (it does NOT read the build profile TargetDirectory), and TMainIDE.DoRestart launches the startlazarus of HIS tree, so "restart after installing a package" only finds us at <pcp>\bin. ide\main.pp:1289 also treats <pcp>\bin\<exe> as the canonical IDE of this pcp and skips the "this config belongs to another lazarus" warning.' }
        [pscustomobject]@{ Scope='Bin'; Name='units'; Kind='build-output'; Required=$false
            Why='IDE unit output (.ppu/.o). buildlazdialog.pas CalcTargets case 1 puts it at <targetdir>\units, i.e. on OUR side. Kept, not deleted: it is what makes a later in-IDE "Save and rebuild IDE" incremental instead of a full multi-minute rebuild.' }
        [pscustomobject]@{ Scope='Bin'; Name='WebView2Loader.dll'; Kind='runtime-dll'; Required=$true
            Why='the chat renders through WebView2. Beside OUR exe, never beside his -- that is one of the three mutations of his tree that milestone 2 removes.' }
        [pscustomobject]@{ Scope='Bin'; Name='sqlite3.dll'; Kind='runtime-dll'; Required=$true
            Why='the chat session store. Beside OUR exe: his own sqlite3.dll (the one every SQLdb tutorial tells him to keep next to lazarus.exe) is never touched again.' }
        [pscustomobject]@{ Scope='Bin'; Name='libvterm.dll'; Kind='runtime-dll'; Required=$true
            Why='the terminal panel. Beside OUR exe, same reason.' }

        # -- <pcp> : the configuration WE seed --------------------------------
        [pscustomobject]@{ Scope='Pcp'; Name='bin'; Kind='directory'; Required=$true
            Why='holds the isolated IDE and its runtime DLLs (see the Bin entries).' }
        [pscustomobject]@{ Scope='Pcp'; Name='environmentoptions.xml'; Kind='config'; Required=$true
            Why='a COPY of his environmentoptions.xml, patched: the version stamp derived from his tree (a wrong one makes the IDE delete <pcp>\bin and <pcp>\units), LazarusDirectory pointing at HIS tree, and our own scratch/fppkg paths. Copied rather than written fresh because --scp only seeds a file that does not exist yet, so a fresh one would lock his settings out forever.' }
        [pscustomobject]@{ Scope='Pcp'; Name='miscellaneousoptions.xml'; Kind='config'; Required=$true
            Why='the build profile (TargetDirectory=<pcp>\bin, UpdateRevisionInc=False) plus the filtered install list. The file name matters: seeding "miscoptions.xml" is ignored in silence and the build falls back to writing into his tree.' }
        [pscustomobject]@{ Scope='Pcp'; Name='packagefiles.xml'; Kind='config'; Required=$false
            Why='the package links lazbuild registers in OUR pcp for every package we install. His own packagefiles.xml is only READ.' }
        [pscustomobject]@{ Scope='Pcp'; Name='staticpackages.inc'; Kind='build-output'; Required=$false
            Why='generated by --build-ide: the uses clause of our lazarus.pp. In OUR pcp, so it names our package list and never his.' }
        [pscustomobject]@{ Scope='Pcp'; Name='idemake.cfg'; Kind='build-output'; Required=$false; Why='generated by the IDE build.' }
        [pscustomobject]@{ Scope='Pcp'; Name='fpcdefines.xml'; Kind='build-output'; Required=$false; Why='compiler-defines cache built by lazbuild.' }
        [pscustomobject]@{ Scope='Pcp'; Name='compilertest.pas'; Kind='build-output'; Required=$false; Why='probe unit lazbuild writes to test the compiler.' }
        [pscustomobject]@{ Scope='Pcp'; Name='pkglib'; Kind='build-output'; Required=$false
            Why='where EVERY package compiles to, because of the BuildMatrix OutDir entry the seed writes at the XML root. This directory is the mechanism behind "zero files written into your tree": without it a redirected build still rewrote ~1538 files / 123 MB of compiler cache inside his Lazarus folder.' }
        [pscustomobject]@{ Scope='Pcp'; Name='testbuild'; Kind='scratch'; Required=$false
            Why='TestBuildDirectory. Forced onto our side, otherwise the "zero files" claim would depend on where HIS TestBuildDirectory points.' }
        [pscustomobject]@{ Scope='Pcp'; Name='fppkg'; Kind='config'; Required=$false
            Why='isolated fppkg config. Without it the first launch opens the configure wizard, and that wizard REWRITES the machine-global fppkg compiler config -- which would break his own IDE.' }
        [pscustomobject]@{ Scope='Pcp'; Name='units'; Kind='build-output'; Required=$false
            Why='pcp-local unit cache. Declared because ide\main.pp names <pcp>\units explicitly in its delete path, so it is a directory this layout has to know about.' }
        [pscustomobject]@{ Scope='Pcp'; Name='logs'; Kind='log'; Required=$false
            Why='our own build transcripts (build-import.log, retries, fallback). Inside the install, so the uninstall takes them with it -- unlike the in-place engine, which left aefos-laz-buildide.log in HIS folder forever.' }
        [pscustomobject]@{ Scope='Pcp'; Name='import-report.txt'; Kind='report'; Required=$false
            Why='which of HIS component packages got into the Aefos IDE, which did not, why, and what he does about each one.' }
        [pscustomobject]@{ Scope='Pcp'; Name='aefos-ide.json'; Kind='stamp'; Required=$true
            Why='what this IDE was built against (his Lazarus version and revision, his tree path, when, which Aefos). Read later to detect that he upgraded his Lazarus and our binary went stale.' }

        # -- <pcp> : what the MIGRATION (slice F5) leaves here -----------------
        # scripts\aefos-laz-migrate.ps1 writes its journal, its report and its
        # transcripts into -AefosHome, which IS this directory, and the installer
        # runs it (PrepareToInstall) BEFORE the install engine. Undeclared, those
        # five entries fail the install with exit 3 -- and they only exist on the
        # machines that had the in-place edition, i.e. on every EXISTING user's
        # machine and on none of the gates. Found by wiring the .iss, which is the
        # first place the two slices meet. They live here on purpose: the uninstall
        # removes this whole directory, so the migration leaves no litter behind.
        [pscustomobject]@{ Scope='Pcp'; Name='migration-report.txt'; Kind='report'; Required=$false
            Why='what the migration from the in-place install reverted, what it could not, and what the user has to finish by hand. The one artefact a support case actually needs.' }
        [pscustomobject]@{ Scope='Pcp'; Name='migration-state.json'; Kind='journal'; Required=$false
            Why='the crash journal that makes an interrupted migration resumable BY EVIDENCE (sha-256 of what is on disk), never by trusting a phase name written before a power cut.' }
        [pscustomobject]@{ Scope='Pcp'; Name='migration-engine.log'; Kind='log'; Required=$false
            Why='the transcript of the shipped in-place uninstall engine the migration drives (-Method Restore). Kept beside the report so the two can be read together.' }
        [pscustomobject]@{ Scope='Pcp'; Name='migration-setup.log'; Kind='log'; Required=$false
            Why='the installer own capture of the migration stream (Aefos-Lazarus.iss _RunMigration). It is the only trace when the engine dies before it can write anything of its own.' }
        [pscustomobject]@{ Scope='Pcp'; Name='migration'; Kind='scratch'; Required=$false
            Why='the safeguarded copy of his STOCK lazarus.exe, held from before the first undo until the whole migration is verified. Deleted when it is; present only when a migration was interrupted or ended partial.' }
        # -- <pcp> : what the IDE ITSELF writes once he actually uses it ------
        # Found by slice F7: a REBUILD of an install that had been STARTED failed the
        # undeclared-entry check with codetoolsoptions.xml, editoroptions.xml,
        # laz_indentation.pas and projectsessions\. None of those come from us. The
        # first start seed-copies his settings out of his own pcp (lazconf.pp
        # CopySecondaryConfigFile, driven by the --scp on our shortcut) and the IDE
        # then keeps its own bookkeeping there, as any Lazarus does in its pcp. A
        # fresh install never has them, which is why every gate was green and every
        # real user's second rebuild would have failed.
        #
        # They are declared as PATTERNS, not as a list of names, because the list is
        # open-ended (helpoptions.xml, inputhistory.xml, codetemplates.dci,
        # anchordockingoptions.xml, dockedformeditoroptions.xml, historylst.xml, one
        # per package that has options...). The rule that keeps the check meaningful:
        # ANYTHING OF OURS IS NAMED aefos*, and an aefos* entry is never covered by a
        # pattern -- it must be declared by name, with a reason, exactly as before.
        [pscustomobject]@{ Scope='Pcp'; Name='*.xml'; IsPattern=$true; Kind='ide-config'; Required=$false
            Why='the IDE own configuration inside its own pcp: editor colours, key mappings, codetools, help, history, docking. Seeded from HIS config on first start by lazconf.pp CopySecondaryConfigFile (that is what --scp on the shortcut is for) and maintained by the IDE afterwards. It is inside OUR directory, so an uninstall takes it, and his own config is only ever read.' }
        [pscustomobject]@{ Scope='Pcp'; Name='*.dci'; IsPattern=$true; Kind='ide-config'; Required=$false
            Why='code templates (codetemplates.dci), seed-copied from his config the same way.' }
        [pscustomobject]@{ Scope='Pcp'; Name='*.cfg'; IsPattern=$true; Kind='ide-config'; Required=$false
            Why='per-tool settings the IDE writes in its pcp (jcfsettings.cfg and friends), plus idemake.cfg from the build.' }
        [pscustomobject]@{ Scope='Pcp'; Name='laz_indentation.pas'; Kind='ide-config'; Required=$false
            Why='the codetools indentation sample the IDE keeps beside codetoolsoptions.xml (ide\codetoolsoptions.pas:1184).' }
        [pscustomobject]@{ Scope='Pcp'; Name='projectsessions'; Kind='ide-config'; Required=$false
            Why='per-project session state (open files, bookmarks) the IDE stores in its pcp when the user chooses to keep sessions out of the .lpi. His projects are not touched -- only this index inside our directory.' }

        [pscustomobject]@{ Scope='Pcp'; Name='runcheck'; Kind='scratch'; Required=$false
            Why='throwaway pcp used to prove the produced exe actually STARTS (a link that succeeds is no proof: the 236 MB PE that linked fine and that Windows refused to load cost a release). Created inside our own directory so the runnable check writes nothing outside it, and removed when it passes.' }
    )
}

<#
.SYNOPSIS
    Does this entry name match a manifest entry -- by exact name, or by a pattern
    entry when the name is not one of OURS?
.DESCRIPTION
    The asymmetry is the point. A pattern says "the IDE keeps its own config here and
    the list of those files is open-ended"; it must never become a way for one of our
    own artefacts to slip in undeclared. Everything we produce is named aefos*, so an
    aefos* entry is excluded from pattern matching and still has to be declared by
    name, with a reason, before it may exist.
#>
function Test-AefosIsolatedDeclared {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)]$Manifest
    )
    foreach ($m in $Manifest) {
        if ($m.Scope -ne $Scope) { continue }
        $isPattern = ($null -ne $m.PSObject.Properties['IsPattern']) -and $m.IsPattern
        if (-not $isPattern) {
            if ($m.Name -ieq $Name) { return $true }
            continue
        }
        if ($Name -like 'aefos*') { continue }
        if ($Name -like $m.Name) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    Entries on disk that the manifest does not declare. Empty is the pass.
#>
function Get-AefosIsolatedUndeclared {
    param([Parameter(Mandatory = $true)][string]$Pcp)

    $manifest = Get-AefosIsolatedLayoutManifest
    $bad = New-Object System.Collections.Generic.List[object]
    $pairs = @(
        [pscustomobject]@{ Scope = 'Pcp'; Dir = (Get-AefosIsolatedFullPath $Pcp) },
        [pscustomobject]@{ Scope = 'Bin'; Dir = (Join-Path (Get-AefosIsolatedFullPath $Pcp) 'bin') }
    )
    foreach ($pair in $pairs) {
        if (-not (Test-Path -LiteralPath $pair.Dir)) { continue }
        foreach ($entry in @(Get-ChildItem -LiteralPath $pair.Dir -Force)) {
            if (-not (Test-AefosIsolatedDeclared -Name $entry.Name -Scope $pair.Scope -Manifest $manifest)) {
                $bad.Add([pscustomobject]@{
                    Scope = $pair.Scope
                    Name  = $entry.Name
                    Path  = $entry.FullName
                })
            }
        }
    }
    # Leading comma so an EMPTY result reaches the caller as an empty array and not
    # as "nothing" -- @($null) would count as one undeclared entry and the perfect
    # result would be reported as a defect.
    return , $bad.ToArray()
}

<#
.SYNOPSIS
    Manifest entries marked Required that are NOT on disk. Empty is the pass.
#>
function Get-AefosIsolatedMissingRequired {
    param([Parameter(Mandatory = $true)][string]$Pcp)

    $pcpFull = Get-AefosIsolatedFullPath $Pcp
    $binFull = Join-Path $pcpFull 'bin'
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($m in (Get-AefosIsolatedLayoutManifest)) {
        if (-not $m.Required) { continue }
        $dir = if ($m.Scope -eq 'Bin') { $binFull } else { $pcpFull }
        if (-not (Test-Path -LiteralPath (Join-Path $dir $m.Name))) {
            [void]$missing.Add(($m.Scope + ':' + $m.Name))
        }
    }
    return , $missing.ToArray()
}

# ---------------------------------------------------------------------------
# Write containment
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    THE guarded copy. Every binary byte an isolated install writes goes through
    here, so containment is a property of the code. Refuses a destination outside
    Root, and refuses a name that would sit in <pcp>\bin and sort before
    lazarus.exe (see the header: the IDE would delete it on the first version
    mismatch, silently, and the chat or the terminal would break with no clue why).
#>
function Copy-AefosIsolatedPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [System.Collections.Generic.List[string]]$Written
    )
    if (-not (Test-AefosIsolatedPathUnder -Child $Destination -Parent $Root)) {
        throw "REFUSING to write outside the isolated install: '$Destination' is not under '$Root'."
    }
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Payload not found: '$Source'."
    }
    $dir  = Split-Path -Parent $Destination
    $name = Split-Path -Leaf $Destination
    if (Test-AefosIsolatedSamePath $dir (Join-Path $Root 'bin')) {
        if (-not (Test-AefosIsolatedBinNameSafe -Name $name)) {
            throw ("REFUSING to place '{0}' in <pcp>\bin: it sorts BEFORE {1}, and ide\main.pp's DeleteDirectory would destroy it before the locked exe stops the loop." -f $name, $Script:AefosIsolatedIdeExeName)
        }
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    if ($null -ne $Written) { [void]$Written.Add((Get-AefosIsolatedFullPath $Destination)) }
}

# ---------------------------------------------------------------------------
# Removal containment (the uninstall side of the same coin)
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Is this path one the uninstall is allowed to delete? Returns '' when it is, or
    the reason it is refused.
.DESCRIPTION
    "Uninstall = remove one directory" is only safe if the directory can never be
    the WRONG one. The refusals below are ordered from the most catastrophic:
    a drive root, a profile root, the shared brain (%APPDATA%\Aefos -- deleting it
    blinds the Delphi edition, which is exactly the bug PR #349 fixed), the user's
    own Lazarus config, anything inside his Lazarus tree, and finally anything that
    does not carry our own shape (a directory named 'lazarus' under a directory
    named 'Aefos') or our own stamp file.
#>
function Test-AefosIsolatedRemovable {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$LazarusDir
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'no path given' }
    $full = Get-AefosIsolatedFullPath $Path
    if ($full.Length -le 3) { return "'$full' is a drive root" }

    $parent = Split-Path -Parent $full
    $leaf   = Split-Path -Leaf $full
    if ([string]::IsNullOrWhiteSpace($parent)) { return "'$full' has no parent" }

    foreach ($sacred in @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA,
                          (Join-Path $env:APPDATA 'Aefos'),
                          (Join-Path $env:LOCALAPPDATA 'Aefos'),
                          (Join-Path $env:LOCALAPPDATA 'lazarus'),
                          (Join-Path $env:USERPROFILE '.aefos'))) {
        if ([string]::IsNullOrWhiteSpace($sacred)) { continue }
        if (Test-AefosIsolatedSamePath $full $sacred) { return "'$full' is '$sacred', which is not ours to delete" }
    }
    # The shared brain is co-owned with the Delphi edition. Not "should not" -- CANNOT.
    $brain = Join-Path $env:APPDATA 'Aefos'
    if (Test-AefosIsolatedPathUnder -Child $full -Parent $brain) {
        return "'$full' is inside the shared brain '$brain' (co-owned with the RAD Studio edition)"
    }
    if (-not [string]::IsNullOrWhiteSpace($LazarusDir)) {
        if (Test-AefosIsolatedSamePath $full $LazarusDir) { return "'$full' IS the user's Lazarus tree" }
        if (Test-AefosIsolatedPathUnder -Child $full -Parent $LazarusDir) { return "'$full' is inside the user's Lazarus tree" }
    }
    # Shape + stamp: either it looks like our install (<something>\Aefos\lazarus) or
    # it carries the stamp file only our installer writes. A directory that is
    # neither is not something we created, so it is not something we remove.
    $shapeOk = (($leaf -ieq 'lazarus') -and ((Split-Path -Leaf $parent) -ieq 'Aefos'))
    $stampOk = (Test-Path -LiteralPath (Join-Path $full $Script:AefosIsolatedStampFile))
    if (-not ($shapeOk -or $stampOk)) {
        return ("'{0}' is neither shaped like an Aefos isolated install (<root>\Aefos\lazarus) nor carries {1}" -f $full, $Script:AefosIsolatedStampFile)
    }
    return ''
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

function Test-AefosIsolatedElevated {
    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Every root this install writes to, and whether it is inside the CURRENT USER'S
    profile. All per-user means: no elevation is required, and with elevation gone
    so is the whole class of "setup elevated as another account, so %LOCALAPPDATA%
    resolved to the admin's profile and the IDE was built against the wrong config".
    That bug class disappears by construction, not by a guard.
#>
function Get-AefosIsolatedWriteRoots {
    param(
        [Parameter(Mandatory = $true)][string]$Pcp,
        [string]$ShortcutDir,
        [string]$DesktopDir
    )
    $roots = New-Object System.Collections.Generic.List[object]
    $roots.Add([pscustomobject]@{
        Path    = (Get-AefosIsolatedFullPath $Pcp)
        What    = 'the isolated IDE (config, build output, binary, runtime DLLs)'
        PerUser = (Test-AefosIsolatedPathUnder -Child $Pcp -Parent $env:USERPROFILE)
    })
    if (-not [string]::IsNullOrWhiteSpace($ShortcutDir)) {
        $roots.Add([pscustomobject]@{
            Path    = (Get-AefosIsolatedFullPath $ShortcutDir)
            What    = 'the Start-menu shortcut (one .lnk in the user own Start menu)'
            PerUser = (Test-AefosIsolatedPathUnder -Child $ShortcutDir -Parent $env:USERPROFILE)
        })
    }
    if (-not [string]::IsNullOrWhiteSpace($DesktopDir)) {
        $roots.Add([pscustomobject]@{
            Path    = (Get-AefosIsolatedFullPath $DesktopDir)
            What    = 'the desktop shortcut (one .lnk on the user own desktop, only when he asked for it)'
            PerUser = (Test-AefosIsolatedPathUnder -Child $DesktopDir -Parent $env:USERPROFILE)
        })
    }
    return , $roots.ToArray()
}
