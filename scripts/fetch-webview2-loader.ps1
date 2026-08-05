<#
.SYNOPSIS
    Fetch Microsoft's WebView2Loader.dll (x64 / x86 / arm64) from the official
    NuGet package into installer\lazarus\redist\<cpu>\.

.DESCRIPTION
    WHY THIS EXISTS. The chat panel renders through WebView2, and the loader must
    sit beside the exe that binds it -- which for the Lazarus edition is the IDE
    this installer BUILDS with the user's own FPC. On a 64-bit Lazarus that exe is
    x86_64, so it needs an x86_64 loader.

    The other two runtime DLLs (libvterm, sqlite3) are COMPILED from vendored C by
    build-libvterm-fpc.ps1 / build-sqlite-fpc.ps1, so a new architecture is just a
    new -Arch. This one cannot be compiled at all: it is a Microsoft binary, and it
    is only ever redistributed. The i386 copy the installer has always shipped is
    lifted out of a RAD Studio bin (installer\lazarus\build-lazarus-installer.ps1
    Get-WebView2Loader) -- and that well is dry for 64-bit: RAD Studio ships NO
    WebView2Loader.dll under any bin64 (verified by a recursive search of the whole
    Studio tree). So the loader has to come from Microsoft directly.

    Microsoft.Web.WebView2 on nuget.org IS that direct source: the package carries
    build\native\<arch>\WebView2Loader.dll for x64, x86 and arm64. A .nupkg is a
    zip, needs no NuGet client, and the download URL is a plain flat-container GET
    -- so this stays a scripted step on a build box rather than "someone copies a
    DLL from somewhere", which is how a mislabelled binary gets shipped.

    THE DOWNLOADED FILE IS VERIFIED, NOT TRUSTED. Every extracted loader has its
    COFF machine word read (Get-AefosPeMachine) and must match the folder it is
    being written into. A directory called x86_64 is a claim; the machine word is
    the fact. Getting that wrong is the exact defect this whole slice exists to
    remove -- a 64-bit IDE beside a 32-bit DLL, dead at 0xc000007b.

    The DLLs are build artifacts (gitignored), like the other two. Run this once on
    a build box; re-run to refresh the version.

.EXAMPLE
    pwsh -File scripts\fetch-webview2-loader.ps1
    pwsh -File scripts\fetch-webview2-loader.ps1 -Version 1.0.4078.44
#>
[CmdletBinding()]
param(
  # Pinned by default so a build is reproducible: 'latest' would silently change
  # what ships between two runs of the same script on the same commit.
  [string]$Version = '1.0.4078.44',
  # Which architectures to materialise. x86 is included so a machine WITHOUT RAD
  # Studio can still stage the i386 payload the installer has always needed.
  [ValidateSet('x86_64', 'i386', 'arm64')]
  [string[]]$Arch = @('x86_64')
)

$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
. (Join-Path $here 'aefos-laz-isolated-layout.ps1')

# NuGet names the architectures its own way; ours are the FPC/PE names used
# everywhere else in this codebase. One map, so the translation lives in one place.
$nugetDir = @{ 'x86_64' = 'x64'; 'i386' = 'x86'; 'arm64' = 'arm64' }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('aefos-wv2-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
  $url  = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$Version/microsoft.web.webview2.$Version.nupkg"
  # .zip, not .nupkg: a .nupkg IS a zip, but Windows PowerShell 5.1's
  # Expand-Archive refuses any extension but .zip (pwsh 7 does not care), and this
  # script has to run under whichever one the build box has.
  $pkg  = Join-Path $work 'webview2.zip'
  Write-Host "Downloading Microsoft.Web.WebView2 $Version from nuget.org..." -ForegroundColor Cyan
  $old = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  try { Invoke-WebRequest -Uri $url -OutFile $pkg -UseBasicParsing } finally { $ProgressPreference = $old }
  Write-Host ("  package: {0:N1} MB" -f ((Get-Item $pkg).Length / 1MB)) -ForegroundColor DarkGray

  $ext = Join-Path $work 'x'
  Expand-Archive -Path $pkg -DestinationPath $ext -Force

  foreach ($a in $Arch) {
    $src = Join-Path $ext ('build\native\' + $nugetDir[$a] + '\WebView2Loader.dll')
    if (-not (Test-Path -LiteralPath $src)) {
      throw "The package has no loader for $a (looked for build\native\$($nugetDir[$a])\WebView2Loader.dll)."
    }
    # VERIFY BEFORE WRITING. A loader that does not match must never reach a
    # payload folder, not even to be corrected later: the staging step downstream
    # trusts what is on disk.
    $machine = Get-AefosPeMachine -Path $src
    if ($machine -ne $a) {
      throw "The $a loader in the package reads as '$machine'. Refusing to stage a mislabelled binary."
    }
    # i386 keeps the flat historical location the installer already points at;
    # every other architecture gets its own folder.
    $dstDir = Join-Path $repoRoot 'installer\lazarus\redist'
    if ($a -ne 'i386') { $dstDir = Join-Path $dstDir $a }
    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    $dst = Join-Path $dstDir 'WebView2Loader.dll'
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host ("  ok  {0}  ({1}, {2:N0} bytes)" -f $dst.Replace($repoRoot + '\', ''), $machine, (Get-Item $dst).Length) -ForegroundColor Green
  }
  Write-Host 'Done.' -ForegroundColor Cyan
} finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
