<#
  build-sqlite-fpc.ps1 - compile the vendored SQLite amalgamation into a standard
  i386 sqlite3.dll for the Lazarus/FPC edition.

  WHY A DLL (changed 2026-07-18): SQLite used to be compiled into a static COFF
  object (sqlite3_fpc.o) and {LINK}ed into the IDE, with the mingw import libs on
  the linker's -Fo/-Fl path. That made the IDE non-rebuildable by NORMAL means:
  a plain `lazbuild --build-ide` (what Package > Install/Uninstall Packages runs to
  add e.g. AnchorDocking) has no -Fo/-Fl and failed to find the object/libs. So we
  now ship SQLite as a runtime DLL loaded via LoadLibrary (see
  source\lazarus\data\Aefos.Lazarus.SQLite.pas), exactly like WebView2Loader.dll.
  The IDE then links with ZERO C dependencies and rebuilds normally.

  The DLL is built from the SAME vendored amalgamation, so the on-disk file stays
  byte-standard "SQLite format 3" - the SAME aefos.db FireDAC reads on the Delphi
  side, enabling a shared %APPDATA%\Aefos\aefos.db (one brain).

  Build flags mirror the previous object (THREADSAFE=0 - we serialise ourselves;
  OMIT_LOAD_EXTENSION). -static-libgcc keeps the DLL from needing libgcc_s at
  runtime; the only remaining deps are KERNEL32 + the Windows UCRT (present on
  every Win10/11 target). SQLITE_API=__declspec(dllexport) exports the public API
  under plain cdecl names (sqlite3_open_v2, ...) so GetProcAddress resolves them.

  PREREQUISITE: an i686 (32-bit) mingw-w64 gcc - the same one libvterm uses. The
  IDE and FPC objects are i386-win32, so the DLL must be i386 too. Install:
    winget install BrechtSanders.WinLibs.POSIX.UCRT   (point -Gcc at its i686 gcc)
  or use the portable one this repo already provisions under
    %TEMP%\aefos-tools\mingw32\bin\gcc.exe
  and pass its gcc.exe via -Gcc, or set AEFOS_MINGW32_GCC to its full path.

  The DLL is a BUILD ARTIFACT (like the Delphi .obj / libvterm .o) - gitignored,
  not committed; run this before the tests or staging the installer.
#>
[CmdletBinding()]
param(
  [string]$Gcc = '',
  # Mirrors build-libvterm-fpc.ps1: i386 by default, so every existing caller
  # keeps producing the same file in the same place.
  [ValidateSet('i386', 'x86_64')]
  [string]$Arch = 'i386'
)

$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$sqlDir   = Join-Path $repoRoot 'source\data\ThirdParty\sqlite'
$srcAmalg = Join-Path $sqlDir 'sqlite3.c'
$binDir   = Join-Path $sqlDir 'bin'
# See the twin note in build-libvterm-fpc.ps1: i386 keeps the flat path the
# installer payload already points at; another architecture gets its own folder,
# because two builds sharing one file name is how the wrong one ships.
if ($Arch -ne 'i386') { $binDir = Join-Path $binDir $Arch }
$dllOut   = Join-Path $binDir 'sqlite3.dll'

if (-not (Test-Path $srcAmalg)) {
  throw "SQLite amalgamation not found at $srcAmalg (see UPSTREAM.txt to re-vendor)."
}

# --- locate a mingw gcc for THIS architecture (mirror of build-libvterm-fpc.ps1) --
function Resolve-Gcc {
  param([string]$Override, [string]$WantArch)
  $wantPattern = if ($WantArch -eq 'x86_64') { 'x86_64' } else { 'i686|i386' }
  $dirName     = if ($WantArch -eq 'x86_64') { 'mingw64' } else { 'mingw32' }
  $envVar      = if ($WantArch -eq 'x86_64') { $env:AEFOS_MINGW64_GCC } else { $env:AEFOS_MINGW32_GCC }
  $cands = @()
  if ($Override) { $cands += $Override }
  if ($envVar)   { $cands += $envVar }
  $cands += @(
    (Join-Path $env:TEMP ('aefos-tools\' + $dirName + '\bin\gcc.exe')),
    "C:\$dirName\bin\gcc.exe",
    "C:\WinLibs\$dirName\bin\gcc.exe",
    "$env:LOCALAPPDATA\$dirName\bin\gcc.exe"
  )
  foreach ($c in $cands) {
    if ($c -and (Test-Path $c)) {
      $machine = (& $c -dumpmachine) 2>$null
      if ($machine -match $wantPattern) { return $c }
      Write-Warning "gcc at $c targets '$machine' (need $WantArch) - skipping."
    }
  }
  return $null
}

$gccPath = Resolve-Gcc -Override $Gcc -WantArch $Arch
if (-not $gccPath) {
  throw @"
No $Arch mingw-w64 gcc found. SQLite cannot be built for FPC without one.
Install one (see this script's header) and re-run with:
    build-sqlite-fpc.ps1 -Arch $Arch -Gcc C:\path\to\bin\gcc.exe
or set AEFOS_MINGW32_GCC / AEFOS_MINGW64_GCC to that path.
"@
}
$machine = (& $gccPath -dumpmachine)
Write-Host "gcc     : $gccPath ($machine)"

New-Item -ItemType Directory -Force -Path $binDir | Out-Null

# Idempotent: skip when the DLL is newer than the amalgamation source.
if ((Test-Path $dllOut) -and
    ((Get-Item $dllOut).LastWriteTime -ge (Get-Item $srcAmalg).LastWriteTime)) {
  Write-Host "up to date: $dllOut"
  return
}

# Flags proven with mingw i686 gcc 16.1.0 (winlibs UCRT):
#   -shared          produce a DLL
#   -Os              size-optimized (the amalgamation is ~9 MB of C)
#   -DSQLITE_THREADSAFE=0   we serialize access ourselves (like the Delphi side's
#                           critical section) -> no win32 mutex/thread deps
#   -DSQLITE_OMIT_LOAD_EXTENSION   no dynamic extension loading (no dlopen path)
#   -DSQLITE_API=__declspec(dllexport)   export the public API (plain cdecl names)
#   -static -static-libgcc   fold libgcc in so the DLL needs no mingw runtime DLL;
#                            leaves only KERNEL32 + the Windows UCRT as deps.
# NONE of these change the on-disk file format: it stays byte-standard SQLite,
# so FireDAC on the Delphi side reads the very same aefos.db.
$gccArgs = @(
  '-shared', '-Os', '-DNDEBUG', '-DSQLITE_THREADSAFE=0', '-DSQLITE_OMIT_LOAD_EXTENSION',
  '-DSQLITE_API=__declspec(dllexport)', '-static', '-static-libgcc',
  '-w', '-o', $dllOut, $srcAmalg
)
Write-Host "compiling sqlite3.c -> $dllOut"
& $gccPath @gccArgs
if ($LASTEXITCODE -ne 0) {
  throw "gcc failed (exit $LASTEXITCODE)."
}
if (-not (Test-Path $dllOut)) {
  throw "gcc reported success but $dllOut is missing."
}
Write-Host ("OK: {0:N0} bytes -> $dllOut" -f (Get-Item $dllOut).Length) -ForegroundColor Green
