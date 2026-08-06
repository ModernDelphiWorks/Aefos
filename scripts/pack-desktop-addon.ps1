<#
.SYNOPSIS
  Packs the Desktop MCP into the OFFLINE dist the installer seeds from.

.DESCRIPTION
  The Desktop MCP is an addon: it is published in the addons repository and
  normally obtained with `aefos install desktop`. This script produces the
  offline copy that rides inside the installer, so a fresh machine gets the
  desktop tools with no download at all:

      mcps\desktop\dist\registry.json                        -> {app}\addons\
      mcps\desktop\dist\addons\desktop\desktop-<ver>.zip      -> {app}\addons\addons\

  The registry it writes uses a RELATIVE url ("addons/desktop/desktop-<ver>.zip").
  aefos.exe anchors a non-http url on the registry's own directory
  (Aefos.Addons.Net.pas:128), so the whole thing resolves locally.

  Two things are deliberate:

  It packs the exe THIS tree built (mcps\desktop\bin), not one downloaded from
  the gallery. Anyone building from source ships their own binary - a build that
  quietly embedded someone else's would make the source meaningless.

  It derives the version from the source of truth - DESKTOP_SERVER_VERSION in
  Aefos.Desktop.Tools.pas - so the dist can never claim a version the binary
  does not report over the wire.

  The manifest is GENERATED here rather than kept as a second copy of the
  bundle: the published bundle lives in the addons repository, and a duplicate
  in this tree would drift the moment either side changed. -CheckGallery
  compares this build against what the gallery currently serves and warns on a
  mismatch (it never fails the build - an offline build must still work).

.PARAMETER CheckGallery
  Fetch the published registry and warn if the local version differs from it.

.EXAMPLE
  pwsh -NoProfile -File scripts/pack-desktop-addon.ps1

.EXAMPLE
  pwsh -NoProfile -File scripts/pack-desktop-addon.ps1 -CheckGallery
#>
[CmdletBinding()]
param(
  [switch] $CheckGallery
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Repo    = Split-Path -Parent $PSScriptRoot
$McpDir  = Join-Path $Repo 'mcps\desktop'
$Exe     = Join-Path $McpDir 'bin\AefosDesktopMcp.exe'
$DistDir = Join-Path $McpDir 'dist'
$Slug    = 'desktop'
$Registry = 'https://raw.githubusercontent.com/ModernDelphiWorks/Aefos-Addons/main/registry.json'

# --- version, from the binary's own source of truth --------------------------
$ToolsPas = Join-Path $McpDir 'Aefos.Desktop.Tools.pas'
if (-not (Test-Path $ToolsPas)) { throw "Not found: $ToolsPas" }

$VersionMatch = Select-String -Path $ToolsPas -Pattern "DESKTOP_SERVER_VERSION\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'" |
                Select-Object -First 1
if (-not $VersionMatch) {
  throw "Could not read DESKTOP_SERVER_VERSION from $ToolsPas - the dist would claim a version the server does not report."
}
$Version = $VersionMatch.Matches[0].Groups[1].Value

Write-Host "Desktop MCP addon $Version" -ForegroundColor Cyan

if (-not (Test-Path $Exe)) {
  throw @"
Desktop MCP binary not built: $Exe
Run scripts\build-desktop-mcp.ps1 first (build-packages.ps1 does this for you).
"@
}

# --- stage -------------------------------------------------------------------
if (Test-Path $DistDir) { Remove-Item -LiteralPath $DistDir -Recurse -Force }
$Payload = Join-Path $DistDir "staging\$Slug"
New-Item -ItemType Directory -Force -Path (Join-Path $Payload 'mcp')   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Payload 'tools') | Out-Null

$Description = 'Desktop automation MCP for the AI agent: enumerate and inspect windows and ' +
               'UI-Automation element trees, per-window screenshots, and guarded write actions ' +
               '- all behind an exe-path scope allow-list and off-LLM human consent. ' +
               'Ships its own AefosDesktopMcp.exe.'

$Manifest = [ordered]@{
  slug        = $Slug
  version     = $Version
  name        = 'Desktop MCP'
  description = $Description
  trust       = 'official'
  requirements = [ordered]@{ aefos_version = '>=0.30.0' }
  artifacts   = [ordered]@{ command = $false; skill = $false; mcp = $true; tools = $true }
}
$Manifest | ConvertTo-Json -Depth 10 |
  Set-Content -Path (Join-Path $Payload 'addon.json') -Encoding UTF8

# ${ADDON_ROOT} is expanded by the installer to the absolute addon folder, so a
# raw MCP spawn (no shell, no cwd) still finds the server.
$Server = [ordered]@{
  'aefos-desktop' = [ordered]@{
    command = '${ADDON_ROOT}\tools\AefosDesktopMcp.exe'
    args    = @()
    env     = [ordered]@{}
  }
}
$Server | ConvertTo-Json -Depth 10 |
  Set-Content -Path (Join-Path $Payload 'mcp\server.json') -Encoding UTF8

Copy-Item -LiteralPath $Exe -Destination (Join-Path $Payload 'tools') -Force

# --- zip ---------------------------------------------------------------------
$ZipName = "$Slug-$Version.zip"
$ZipDir  = Join-Path $DistDir "addons\$Slug"
New-Item -ItemType Directory -Force -Path $ZipDir | Out-Null
$ZipPath = Join-Path $ZipDir $ZipName

Compress-Archive -Path $Payload -DestinationPath $ZipPath -CompressionLevel Optimal
Remove-Item -LiteralPath (Join-Path $DistDir 'staging') -Recurse -Force

$Sha = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

# --- local registry (relative url) -------------------------------------------
$LocalRegistry = [ordered]@{
  schema = 1
  addons = @(
    [ordered]@{
      slug         = $Slug
      name         = $Manifest.name
      version      = $Version
      description  = $Description
      type         = 'mcp'
      trust        = 'official'
      url          = "addons/$Slug/$ZipName"
      sha256       = $Sha
      requirements = [ordered]@{ aefos_version = '>=0.30.0' }
    }
  )
}
$Json = $LocalRegistry | ConvertTo-Json -Depth 10
$Json = $Json.Replace('\/', '/')
Set-Content -Path (Join-Path $DistDir 'registry.json') -Value $Json -Encoding UTF8

Write-Host "  OK  $ZipPath" -ForegroundColor Green
Write-Host "      sha256 $Sha"
Write-Host "  OK  $(Join-Path $DistDir 'registry.json') (relative url)" -ForegroundColor Green

# --- optional drift check against the published gallery ----------------------
if ($CheckGallery) {
  try {
    $Published = (Invoke-WebRequest -Uri $Registry -UseBasicParsing -TimeoutSec 20).Content | ConvertFrom-Json
    $Entry = $Published.addons | Where-Object { $_.slug -eq $Slug }
    if (-not $Entry) {
      Write-Host "  ??  the gallery has no '$Slug' entry" -ForegroundColor Yellow
    } elseif ($Entry.version -eq $Version) {
      Write-Host "  OK  the gallery serves the same version ($Version)" -ForegroundColor Green
    } else {
      Write-Host "  !!  DRIFT: this tree builds $Version, the gallery serves $($Entry.version)." -ForegroundColor Yellow
      Write-Host "      The installer will seed $Version offline; `aefos update desktop` then moves" -ForegroundColor Yellow
      Write-Host "      the user to whatever the gallery serves. Publish first if $Version is the newer one." -ForegroundColor Yellow
    }
  } catch {
    Write-Host "  --  gallery check skipped (offline): $($_.Exception.Message)" -ForegroundColor DarkYellow
  }
}
