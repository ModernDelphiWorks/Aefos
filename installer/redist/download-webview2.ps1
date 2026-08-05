<#
  Fetch the WebView2 Evergreen STANDALONE (offline) installers — x64 / x86 / ARM64 —
  into this folder, so build-installer.ps1 can embed the one matching the target arch
  (Aefos.iss bundles redist\MicrosoftEdgeWebView2RuntimeInstaller<arch>.exe with the
  `dontcopy` flag and runs it /silent /install when the runtime is missing).

  Source: winget's Microsoft.EdgeWebView2Runtime manifest, which points at Microsoft's
  OFFICIAL download host (msedge.sf.dl.delivery.mp.microsoft.com) and VERIFIES the
  installer hash — so this is the official binary, not a third-party mirror. There is
  NO stable fwlink for the standalone (it's an open MS request), hence winget.

  The .exe files are gitignored (*.exe, ~190 MB each) — run this once on a build box
  to (re)materialise them. Re-run to refresh to the latest runtime version.

  Usage:  pwsh -File installer\redist\download-webview2.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$dst = $PSScriptRoot

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw 'winget not found. Install "App Installer" from the Microsoft Store, or ' +
        'download the standalone installers manually from ' +
        'https://developer.microsoft.com/microsoft-edge/webview2/ (Evergreen ' +
        'Standalone Installer, all three architectures).'
}

$map = @{ 'x64' = 'X64'; 'x86' = 'X86'; 'arm64' = 'ARM64' }
foreach ($arch in $map.Keys) {
  Write-Host "=== WebView2 Runtime standalone: $arch ===" -ForegroundColor Cyan
  # winget download writes a verbose filename; we then rename to the canonical one
  # the .iss expects. Clear any prior verbose drop for this arch first.
  Get-ChildItem $dst -Filter "*$($map[$arch])*exe*.exe" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
  winget download --id Microsoft.EdgeWebView2Runtime --architecture $arch `
    --download-directory $dst --accept-package-agreements --accept-source-agreements `
    --disable-interactivity | Out-Null
  $src = Get-ChildItem $dst -Filter "*$($map[$arch])*exe*.exe" | Select-Object -First 1
  if (-not $src) { throw "winget did not produce the $arch installer." }
  $final = Join-Path $dst "MicrosoftEdgeWebView2RuntimeInstaller$($map[$arch]).exe"
  Move-Item $src.FullName $final -Force
  $mb = [math]::Round((Get-Item $final).Length / 1MB, 1)
  Write-Host "  -> $(Split-Path $final -Leaf)  ($mb MB)" -ForegroundColor Green
}
Write-Host "Done. Three standalone installers are in $dst." -ForegroundColor Cyan
