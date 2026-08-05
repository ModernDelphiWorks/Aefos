<#
  Compiles the Aefos AI - Lazarus edition installer (Aefos-Lazarus.iss) via ISCC.

  Unlike the Delphi installer, there are NO BPLs to stage: the Lazarus edition
  ships SOURCES and rebuilds the user's lazarus.exe on their machine. This script
  only:
    1. Stages the x86 WebView2Loader.dll beside the .iss (the chat needs it, and
       the install engine drops it next to lazarus.exe).
    2. Sanity-checks that the package .lpk and its source tree are present.
    3. Runs ISCC to produce Output\Aefos-Lazarus-Setup-<ver>.exe.

  Usage:
    pwsh -File installer\lazarus\build-lazarus-installer.ps1
    pwsh -File installer\lazarus\build-lazarus-installer.ps1 -Iscc "C:\...\ISCC.exe"
#>
[CmdletBinding()]
param(
  [string]$Iscc = '',
  [string]$WebView2Loader = '',
  # The x64 WebView2 loader. It cannot be built, only redistributed, and RAD
  # Studio ships only the x86 one - so unlike the other two DLLs there is nothing
  # to compile here. Comes from the Microsoft.Web.WebView2 NuGet package
  # (build\native\x64\WebView2Loader.dll). Also read from
  # AEFOS_WEBVIEW2_LOADER_X64. Absent = no x86_64 payload, and the installer
  # keeps refusing 64-bit Lazarus.
  [string]$WebView2Loader64 = ''
)

$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$iss      = Join-Path $here 'Aefos-Lazarus.iss'
$lpk      = Join-Path $repoRoot 'packages\Lazarus\Aefos.Lazarus.IDE.lpk'

# --- sanity: package + a source spot-check --------------------------------
if (-not (Test-Path $lpk)) {
  throw "Package not found at $lpk. Nothing to ship."
}
$spot = Join-Path $repoRoot 'source\lazarus\ide\Aefos.Lazarus.Register.pas'
if (-not (Test-Path $spot)) {
  throw "Source tree incomplete (missing $spot)."
}

# --- WebView2Loader.dll: x86, version-independent. Source it from the staged
#     Delphi installer folder if present, else any RAD Studio bin. -----------
function Get-WebView2Loader {
  $staged = Join-Path $repoRoot 'installer\bpl\23.0\WebView2Loader.dll'
  if (Test-Path $staged) { return $staged }
  foreach ($v in @('37.0', '23.0', '22.0')) {
    $p = "C:\Program Files (x86)\Embarcadero\Studio\$v\bin\WebView2Loader.dll"
    if (Test-Path $p) { return $p }
  }
  if ($env:BDS) {
    $p = Join-Path $env:BDS 'bin\WebView2Loader.dll'
    if (Test-Path $p) { return $p }
  }
  throw "WebView2Loader.dll not found (installer\bpl\23.0 or a RAD Studio bin). Pass -WebView2Loader <path>."
}

if (-not $WebView2Loader) { $WebView2Loader = Get-WebView2Loader }
Copy-Item $WebView2Loader (Join-Path $here 'WebView2Loader.dll') -Force
Write-Host "WebView2Loader.dll staged from: $WebView2Loader" -ForegroundColor DarkGray

# --- SQLite runtime DLL: stage the standard i386 sqlite3.dll --------------------
# The Lazarus edition loads SQLite at RUNTIME from sqlite3.dll (the shared aefos.db
# one-brain backend), shipped beside lazarus.exe exactly like WebView2Loader.dll.
# This is a deliberate change from the old static object: the static {LINK} made
# the user's IDE non-rebuildable by normal means (a plain `lazbuild --build-ide`,
# which Package > Install/Uninstall Packages runs to add e.g. AnchorDocking, has no
# -Fo/-Fl and failed to find the object + mingw libs). With a runtime DLL the IDE
# link has ZERO C dependencies and rebuilds normally. The DLL is built from the
# same vendored amalgamation (byte-standard "SQLite format 3", shared with FireDAC).
# Staged into redist\ (gitignored), never committed.
Write-Host "Staging SQLite runtime DLL..." -ForegroundColor Cyan
& (Join-Path $repoRoot 'scripts\build-sqlite-fpc.ps1')
if ($LASTEXITCODE -ne 0) { throw "build-sqlite-fpc.ps1 failed (exit $LASTEXITCODE)." }
$sqliteDll = Join-Path $repoRoot 'source\data\ThirdParty\sqlite\bin\sqlite3.dll'
if (-not (Test-Path $sqliteDll)) { throw "sqlite3.dll not produced at $sqliteDll." }
$dllStage = Join-Path $here 'redist'
New-Item -ItemType Directory -Force -Path $dllStage | Out-Null
Copy-Item $sqliteDll (Join-Path $dllStage 'sqlite3.dll') -Force
Write-Host "Staged sqlite3.dll from: $sqliteDll" -ForegroundColor DarkGray

# --- libvterm runtime DLL: build + stage the i686 libvterm.dll ------------------
# The terminal panel binds libvterm as a RUNTIME DLL (external 'libvterm.dll'),
# shipped beside lazarus.exe exactly like sqlite3.dll and for the same reason -- a
# static {$LINK} would make the IDE non-rebuildable and drag the mingw CRT into the
# link. Built from the vendored unity C by an i686 mingw gcc. Staged into redist\
# (gitignored), never committed.
Write-Host "Staging libvterm runtime DLL..." -ForegroundColor Cyan
& (Join-Path $repoRoot 'scripts\build-libvterm-fpc.ps1')
if ($LASTEXITCODE -ne 0) { throw "build-libvterm-fpc.ps1 failed (exit $LASTEXITCODE)." }
$vtermDll = Join-Path $repoRoot 'source\terminal\ThirdParty\libvterm\obj\libvterm.dll'
if (-not (Test-Path $vtermDll)) { throw "libvterm.dll not produced at $vtermDll." }
Copy-Item $vtermDll (Join-Path $dllStage 'libvterm.dll') -Force
Write-Host "Staged libvterm.dll from: $vtermDll" -ForegroundColor DarkGray

# --- x86_64 runtime DLLs: the SAME three, for a 64-bit Lazarus -----------------
#
# WHY THIS BLOCK EXISTS. The three DLLs above are i386, and until now that was the
# only thing this installer could serve -- while the IDE it produces is compiled
# with the USER'S FPC, so on a 64-bit Lazarus it comes out x86_64. The two met on
# a partner's machine: the build succeeded, the installer reported success, and
# the IDE died at 0xc000007b because libvterm.dll is a LOAD-TIME import.
#
# BEST EFFORT, ON PURPOSE. A missing x86_64 toolchain must not break the 32-bit
# installer that has been shipping for months. When this block produces nothing,
# redist\x86_64\ simply does not exist -- and the .iss then computes PayloadCpus
# WITHOUT x86_64 (same FileExists), so the wizard goes on refusing 64-bit Lazarus
# with a clear message instead of shipping a payload that is not there. The
# capability and the promise are derived from the same fact, never declared twice.
Write-Host "Staging x86_64 runtime DLLs (needs an x86_64 mingw gcc)..." -ForegroundColor Cyan
$x64Stage   = Join-Path $dllStage 'x86_64'
$x64Sqlite  = Join-Path $repoRoot 'source\data\ThirdParty\sqlite\bin\x86_64\sqlite3.dll'
$x64Vterm   = Join-Path $repoRoot 'source\terminal\ThirdParty\libvterm\obj\x86_64\libvterm.dll'
$x64Loader  = $WebView2Loader64
$x64Ok      = $true
foreach ($step in @(
  @{ Script = 'scripts\build-sqlite-fpc.ps1';   Out = $x64Sqlite; Name = 'sqlite3.dll' },
  @{ Script = 'scripts\build-libvterm-fpc.ps1'; Out = $x64Vterm;  Name = 'libvterm.dll' })) {
  if (-not $x64Ok) { break }
  try {
    & (Join-Path $repoRoot $step.Script) -Arch x86_64 | Out-Host
    if (($LASTEXITCODE -ne 0) -or (-not (Test-Path $step.Out))) { $x64Ok = $false }
  } catch {
    Write-Host ("  x86_64 {0}: {1}" -f $step.Name, $_.Exception.Message) -ForegroundColor DarkYellow
    $x64Ok = $false
  }
}
# The 64-bit WebView2 loader cannot be built, only redistributed, and RAD Studio
# ships ONLY the x86 one (verified: no WebView2Loader.dll under any bin64). It has
# to be supplied -- from the Microsoft.Web.WebView2 NuGet package
# (build\native\x64\WebView2Loader.dll) -- via -WebView2Loader64 or
# AEFOS_WEBVIEW2_LOADER_X64.
if ($x64Ok -and (-not $x64Loader)) { $x64Loader = $env:AEFOS_WEBVIEW2_LOADER_X64 }
# Neither given nor already staged: fetch it, so a clean checkout on a build box
# with an x86_64 gcc produces a 64-bit payload without a manual step. Best effort -
# an offline box just ends up without the x86_64 folder, which the wizard already
# handles honestly.
if ($x64Ok -and (-not $x64Loader)) {
  $fetched = Join-Path $dllStage 'x86_64\WebView2Loader.dll'
  if (-not (Test-Path $fetched)) {
    try { & (Join-Path $repoRoot 'scripts\fetch-webview2-loader.ps1') -Arch x86_64 | Out-Host } catch {
      Write-Host ("  fetch-webview2-loader.ps1: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
  }
  if (Test-Path $fetched) { $x64Loader = $fetched }
}
if ($x64Ok -and ((-not $x64Loader) -or (-not (Test-Path $x64Loader)))) {
  Write-Host "  x86_64 WebView2Loader.dll not available -- the installer will refuse 64-bit Lazarus. See installer\lazarus\redist\x86_64\README.md." -ForegroundColor DarkYellow
  $x64Ok = $false
}
if ($x64Ok) {
  New-Item -ItemType Directory -Force -Path $x64Stage | Out-Null
  # ALREADY-IN-PLACE IS A HIT, NOT AN ERROR. fetch-webview2-loader.ps1 writes the
  # loader straight to its final home (redist\<cpu>\), so on the path a real build
  # box takes - no loader passed, none staged, so it gets fetched - source and
  # destination here are THE SAME FILE, and Copy-Item refuses to copy a file onto
  # itself. That killed the first honest end-to-end run of this block: every
  # earlier test had the loader pre-placed by hand and never reached this line.
  function Copy-IfDifferent {
    param([string]$From, [string]$To)
    $f = (Resolve-Path -LiteralPath $From).ProviderPath
    $t = if (Test-Path -LiteralPath $To) { (Resolve-Path -LiteralPath $To).ProviderPath } else { $To }
    if ($f -ieq $t) { return }
    Copy-Item -LiteralPath $f -Destination $t -Force
  }
  Copy-IfDifferent $x64Sqlite (Join-Path $x64Stage 'sqlite3.dll')
  Copy-IfDifferent $x64Vterm  (Join-Path $x64Stage 'libvterm.dll')
  Copy-IfDifferent $x64Loader (Join-Path $x64Stage 'WebView2Loader.dll')
  # NAME IT AND VERIFY IT. A folder called x86_64 is a claim; the COFF machine word
  # is the fact, and staging a 32-bit DLL under this name would ship exactly the
  # defect this block was written to remove.
  . (Join-Path $repoRoot 'scripts\aefos-laz-isolated-layout.ps1')
  foreach ($n in @('sqlite3.dll', 'libvterm.dll', 'WebView2Loader.dll')) {
    $m = Get-AefosPeMachine -Path (Join-Path $x64Stage $n)
    if ($m -ne 'x86_64') { throw "redist\x86_64\$n is '$m', not x86_64. Refusing to stage a mislabelled payload." }
    Write-Host ("  ok  x86_64\{0} ({1})" -f $n, $m) -ForegroundColor DarkGray
  }
  Write-Host "Staged the x86_64 runtime DLLs: this installer will accept a 64-bit Lazarus." -ForegroundColor Green
} else {
  Remove-Item -Recurse -Force $x64Stage -ErrorAction SilentlyContinue
  Write-Host "No x86_64 payload staged - the installer will keep refusing 64-bit Lazarus (by design, not by accident)." -ForegroundColor DarkYellow
}

# --- Aefos addon manager (aefos.exe) -------------------------------------------
# The offline Desktop MCP seed ([Run]) needs cli\bin\aefos.exe. It is ONE Win32
# console exe shared with the RAD Studio edition; build it if absent (dcc32 via
# build-aefos-cli.ps1). Best-effort: a machine without RAD Studio can pre-build it
# with FPC (build-fpc.ps1 -Clis produces cli\.build-fpc\aefos.exe; copy to cli\bin).
# The .iss stages it with skipifsourcedoesntexist, so a missing exe degrades to
# online-only rather than failing the build.
$aefosExe = Join-Path $repoRoot 'cli\bin\aefos.exe'
if (-not (Test-Path $aefosExe)) {
  Write-Host "aefos.exe not found - building it (dcc32)..." -ForegroundColor Cyan
  try { & (Join-Path $repoRoot 'scripts\build-aefos-cli.ps1') | Out-Host } catch {
    Write-Host "  build-aefos-cli.ps1 failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
  }
}
if (Test-Path $aefosExe) {
  Write-Host "aefos.exe: $aefosExe" -ForegroundColor Green
} else {
  Write-Host "aefos.exe: NOT available - offline addon seed will be skipped (online-only). Pre-build cli\bin\aefos.exe." -ForegroundColor DarkYellow
}

# --- Bundled Desktop MCP addon ------------------------------------------------
# The Desktop MCP is an ADDON: published in the addons repository and obtained
# with `aefos install desktop`, binary included. This repo carries only the
# source of its server executable, so nothing here packs a dist. The .iss
# staging lines are skipifsourcedoesntexist, so the installer ships online-only.

# --- locate ISCC ----------------------------------------------------------
if (-not $Iscc) {
  foreach ($c in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'))) {
    if (Test-Path $c) { $Iscc = $c; break }
  }
}
if (-not (Test-Path $Iscc)) {
  throw "ISCC not found at '$Iscc'. Pass -Iscc with the Inno Setup path."
}

Write-Host "Compiling Lazarus installer..." -ForegroundColor Cyan
& $Iscc $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed (exit $LASTEXITCODE)." }

Write-Host "Done -> $(Join-Path $here 'Output')" -ForegroundColor Green
