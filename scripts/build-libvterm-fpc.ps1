<#
  build-libvterm-fpc.ps1 - compile the vendored libvterm C sources into a runtime
  libvterm.dll for the Lazarus terminal (i686-win32).

  WHY a DLL (and why separate from the Delphi obj): the Delphi terminal links
  source\terminal\ThirdParty\libvterm\obj\libvterm_unity.obj, an OMF object produced
  by bcc32c for Delphi's single-pass {$L} inside a design BPL. FPC / the Lazarus IDE
  cannot use that model: a static {$LINK} of a COFF .o makes lazarus.exe
  non-rebuildable by the normal Package > Install/Uninstall path and drags the mingw
  CRT into the IDE link (the exact lesson SQLite taught -> sqlite3.dll at runtime).
  So the FPC edition imports libvterm as a RUNTIME DLL (Aefos.OTA.Terminal.Core.LibVTerm
  declares every vterm_* as external 'libvterm.dll'). This script builds that DLL
  from the SAME vendored C (the unity translation unit); it bundles its own UCRT so
  the IDE link has zero C dependencies.

  PREREQUISITE: an i686 (32-bit) mingw-w64 gcc. The IDE is i386-win32, so the DLL
  must be i386 too; a 64-bit gcc will not do. FPC's own bundled gcc is a broken 2.95
  stub and bcc32c only emits OMF - neither works. Install one of:
    winget install BrechtSanders.WinLibs.POSIX.UCRT   (then point -Gcc at its i686 gcc)
    or the WinLibs "winlibs-i686-...-ucrt-...zip" (portable, no system install)
  and pass its gcc.exe via -Gcc, or set AEFOS_MINGW32_GCC to its full path.

  The DLL is a BUILD ARTIFACT (like the Delphi .obj) - not committed; run this
  before building the terminal package / IDE, and ship it beside lazarus.exe.
#>
[CmdletBinding()]
param(
  [string]$Gcc = '',
  # The architecture of the IDE this DLL will sit beside. i386 is the default so
  # every existing caller keeps building exactly what it built before, in exactly
  # the same place.
  [ValidateSet('i386', 'x86_64')]
  [string]$Arch = 'i386'
)

$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$lvDir    = Join-Path $repoRoot 'source\terminal\ThirdParty\libvterm'
$srcUnity = Join-Path $lvDir 'src\libvterm_unity.c'
$objDir   = Join-Path $lvDir 'obj'
# i386 keeps the historical flat path -- it is what the installer payload and
# Get-AefosIsolatedPayloadDlls already point at. Anything else gets its own
# subdirectory, because two architectures with the same file name in the same
# folder is how a 32-bit DLL ends up shipping as the 64-bit one.
if ($Arch -ne 'i386') { $objDir = Join-Path $objDir $Arch }
$dllOut   = Join-Path $objDir 'libvterm.dll'

if (-not (Test-Path $srcUnity)) {
  throw "libvterm unity source not found at $srcUnity."
}

# --- locate a mingw gcc for THIS architecture ----------------------------------
# The check is -dumpmachine, not the folder name: a directory called mingw64 that
# holds a 32-bit gcc would otherwise produce a 32-bit DLL under an x86_64 name,
# which is precisely the failure this whole slice exists to prevent (a partner's
# 64-bit IDE died at 0xc000007b beside a 32-bit libvterm.dll).
function Resolve-Gcc {
  param([string]$Override, [string]$WantArch)
  $wantPattern = if ($WantArch -eq 'x86_64') { 'x86_64' } else { 'i686|i386' }
  $dirName     = if ($WantArch -eq 'x86_64') { 'mingw64' } else { 'mingw32' }
  $envVar      = if ($WantArch -eq 'x86_64') { $env:AEFOS_MINGW64_GCC } else { $env:AEFOS_MINGW32_GCC }
  $cands = @()
  if ($Override) { $cands += $Override }
  if ($envVar)   { $cands += $envVar }
  $cands += @(
    "C:\$dirName\bin\gcc.exe",
    "C:\WinLibs\$dirName\bin\gcc.exe",
    "$env:LOCALAPPDATA\$dirName\bin\gcc.exe",
    (Join-Path $env:TEMP ('aefos-tools\' + $dirName + '\bin\gcc.exe'))
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
  $hint = if ($Arch -eq 'x86_64') { 'winlibs-x86_64-...-ucrt-...zip, unpacked as mingw64' }
          else { 'winlibs-i686-...-ucrt-...zip, unpacked as mingw32' }
  throw @"
No $Arch mingw-w64 gcc found. libvterm.dll cannot be built for FPC without one.
Install one ($hint - see this script's header) and re-run with:
    build-libvterm-fpc.ps1 -Arch $Arch -Gcc C:\path\to\bin\gcc.exe
or set AEFOS_MINGW32_GCC / AEFOS_MINGW64_GCC to that path.
"@
}
$machine = (& $gccPath -dumpmachine)
Write-Host "gcc     : $gccPath ($machine)"

# --- compile -------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $objDir | Out-Null

# Idempotent: skip when the DLL is newer than the unity source.
if ((Test-Path $dllOut) -and
    ((Get-Item $dllOut).LastWriteTime -ge (Get-Item $srcUnity).LastWriteTime)) {
  Write-Host "up to date: $dllOut"
  return
}

# Flags proven with mingw i686 gcc (winlibs UCRT): unity build, optimized, warnings
# silenced. -shared builds the DLL; mingw auto-exports all global symbols, so every
# cdecl vterm_* is exported by its plain (undecorated) name -- the name FPC imports.
# -static-libgcc folds libgcc in so the DLL has no extra mingw runtime dependency;
# the UCRT is imported from the system (ucrtbase.dll), present on Windows 10+.
$gccArgs = @(
  '-shared', '-O2', '-DNDEBUG', '-w', '-static-libgcc',
  '-I', (Join-Path $lvDir 'include'),
  '-I', (Join-Path $lvDir 'src'),
  '-o', $dllOut,
  $srcUnity,
  '-lmingwex'
)
Write-Host "compiling libvterm_unity.c -> $dllOut"
& $gccPath @gccArgs
if ($LASTEXITCODE -ne 0) {
  throw "gcc failed (exit $LASTEXITCODE)."
}
if (-not (Test-Path $dllOut)) {
  throw "gcc reported success but $dllOut is missing."
}
Write-Host ("OK: {0:N0} bytes" -f (Get-Item $dllOut).Length) -ForegroundColor Green
