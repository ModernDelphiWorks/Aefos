<#
  bump-version.ps1 -- single-command version bump across EVERY place the Aefos
  version is hardcoded, so a release never drifts again (the 0.18.0 release shipped
  Chat 0.17.0 because OTA_PLUGIN_VERSION was a separate manual const).

  The version lives in, and this script rewrites, all of:
    - installer/Aefos.iss                          (#define AppVer "x.y.z")
    - packages/Delphi/*.dproj                       (VerInfo FileVersion=x.y.z.0 +
                                                      ProductVersion=x.y.z, ONLY the
                                                      Aefos VerInfo lines)
    - source/terminal/UI/Aefos.OTA.Terminal.UI.Branding.pas  (FALLBACK_VERSION)
    - source/chat/Core/Aefos.OTA.Chat.Core.MainMenu.pas      (OTA_PLUGIN_VERSION)
    - source/mcp/OTA/Aefos.OTA.MCP.IssueReport.pas           (CPluginVersionFallback)

  Usage:
    pwsh -File scripts/bump-version.ps1 0.19.0
    pwsh -File scripts/bump-version.ps1 0.19.0 -WhatIf   # preview, no writes

  After running: rebuild the package group (Release/Win32) + dclAefosWebView, then
  build-installer.ps1. The Chat About reads OTA_PLUGIN_VERSION; the Terminal About
  reads its BPL FileVersion (fallback const); both now move together.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Version
)

$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "Version must be x.y.z (e.g. 0.19.0). Got: '$Version'"
}

$root = Split-Path -Parent $PSScriptRoot   # repo root (scripts/..)
$changed = 0

function Edit-File($path, [scriptblock]$transform, $label) {
  $full = Join-Path $root $path
  if (-not (Test-Path $full)) { Write-Host "  SKIP (missing) $path" -ForegroundColor DarkYellow; return }
  $orig = Get-Content -Raw -LiteralPath $full
  $new  = & $transform $orig
  if ($new -eq $orig) { Write-Host "  =    $path ($label -- already current / no match)"; return }
  if ($PSCmdlet.ShouldProcess($path, "bump -> $Version")) {
    # Preserve the file's existing encoding bytes by writing UTF-8 (no BOM change for
    # ASCII content; .pas with non-ASCII keep their bytes since we only swap digits).
    Set-Content -LiteralPath $full -Value $new -NoNewline -Encoding utf8
  }
  Write-Host "  ok   $path ($label)" -ForegroundColor Green
  $script:changed++
}

Write-Host "Bumping Aefos version -> $Version" -ForegroundColor Cyan

# 1) Inno Setup installer
Edit-File 'installer/Aefos.iss' {
  param($t) $t -replace '(#define\s+AppVer\s+")[0-9][0-9.]*(")', "`${1}$Version`${2}"
} 'AppVer'

# 2) Branding fallback (Terminal)
Edit-File 'source/terminal/UI/Aefos.OTA.Terminal.UI.Branding.pas' {
  param($t) $t -replace "(FALLBACK_VERSION\s*=\s*')[0-9][0-9.]*(')", "`${1}$Version`${2}"
} 'FALLBACK_VERSION'

# 3) Chat plugin version const
Edit-File 'source/chat/Core/Aefos.OTA.Chat.Core.MainMenu.pas' {
  param($t) $t -replace "(OTA_PLUGIN_VERSION\s*=\s*')[0-9][0-9.]*(')", "`${1}$Version`${2}"
} 'OTA_PLUGIN_VERSION'

# 3b) Issue-report version fallback (MCP.Tools.OTA BPL -- cannot read the Chat const
#     across BPL layers, so it carries its own fallback literal; bump it here too).
Edit-File 'source/mcp/OTA/Aefos.OTA.MCP.IssueReport.pas' {
  param($t) $t -replace "(CPluginVersionFallback\s*=\s*')[0-9][0-9.]*(')", "`${1}$Version`${2}"
} 'CPluginVersionFallback'

# 4) Every Aefos .dproj VerInfo (ONLY lines tagged com.moderndelphiworks.aefos, so
#    the generic 1.0.0.0 base-config VerInfo is left untouched).
Get-ChildItem (Join-Path $root 'packages/Delphi') -Filter *.dproj | ForEach-Object {
  $rel = "packages/Delphi/$($_.Name)"
  Edit-File $rel {
    param($t)
    ($t -split "`n") | ForEach-Object {
      if ($_ -match 'com\.moderndelphiworks\.aefos') {
        ($_ -replace 'FileVersion=[0-9][0-9.]*', "FileVersion=$Version.0") `
            -replace 'ProductVersion=[0-9][0-9.]*', "ProductVersion=$Version"
      } else { $_ }
    } | Join-String -Separator "`n"
  } 'VerInfo'
}

Write-Host ""
Write-Host "Done -- $changed file(s) updated to $Version." -ForegroundColor Cyan
Write-Host "Next: rebuild the group (Release/Win32) + dclAefosWebView, then build-installer.ps1." -ForegroundColor DarkCyan
