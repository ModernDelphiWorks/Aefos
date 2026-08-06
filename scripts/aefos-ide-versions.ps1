<#
  The one list of RAD Studio versions Aefos builds for.

  Dot-source this; do not copy the array. It was copied into six scripts, and a
  copied list drifts in the worst possible way: the build accepts a version the
  installer has never heard of, produces BPLs for it, and the payload silently
  never ships.

      . (Join-Path $PSScriptRoot 'aefos-ide-versions.ps1')

  Two numbers per release and they are NOT the same. $(BDS) - the product/registry
  version, which is what rsvars.bat and the install path use - and CompilerVersion,
  which is what {$IF} guards in the source test. Delphi 13 is the odd one: product
  37.0 AND compiler 37.0, after Embarcadero jumped the product numbering.

  Adding a version is one row here. Everything that enumerates versions reads it.
#>

$script:AefosIdeVersions = @(
  [pscustomobject]@{ Bds = '17.0'; Product = 'Delphi 10 Seattle';    Compiler = '30.0'; Year = 2015 }
  [pscustomobject]@{ Bds = '18.0'; Product = 'Delphi 10.1 Berlin';   Compiler = '31.0'; Year = 2016 }
  [pscustomobject]@{ Bds = '19.0'; Product = 'Delphi 10.2 Tokyo';    Compiler = '32.0'; Year = 2017 }
  [pscustomobject]@{ Bds = '20.0'; Product = 'Delphi 10.3 Rio';      Compiler = '33.0'; Year = 2018 }
  [pscustomobject]@{ Bds = '21.0'; Product = 'Delphi 10.4 Sydney';   Compiler = '34.0'; Year = 2020 }
  [pscustomobject]@{ Bds = '22.0'; Product = 'Delphi 11 Alexandria'; Compiler = '35.0'; Year = 2021 }
  [pscustomobject]@{ Bds = '23.0'; Product = 'Delphi 12 Athens';     Compiler = '36.0'; Year = 2023 }
  [pscustomobject]@{ Bds = '37.0'; Product = 'Delphi 13';            Compiler = '37.0'; Year = 2025 }
)

# Newest first: every "pick whichever is installed" loop wants the newest that is
# actually there, not the oldest.
$script:AefosIdeVersionsNewestFirst = @(
  $script:AefosIdeVersions | Sort-Object { [double] $_.Bds } -Descending | ForEach-Object { $_.Bds }
)

$script:AefosIdeSupported = @($script:AefosIdeVersions | ForEach-Object { $_.Bds })

function Get-AefosIdeProductName {
  param([Parameter(Mandatory = $true)][string] $Bds)
  $row = $script:AefosIdeVersions | Where-Object { $_.Bds -eq $Bds } | Select-Object -First 1
  if ($row) { $row.Product } else { "BDS $Bds" }
}

function Get-AefosInstalledIdeVersions {
  <#
    .SYNOPSIS
      The supported versions whose RAD Studio is actually installed, newest first.

    .DESCRIPTION
      Presence is decided by rsvars.bat, not by the registry: rsvars is what a
      command-line build actually needs, and an installed-but-unregistered
      product has it while a registry entry can outlive an uninstall.
  #>
  param()
  $found = @()
  foreach ($v in $script:AefosIdeVersionsNewestFirst) {
    if (Test-Path (Get-AefosRsVarsPath $v)) { $found += $v }
  }
  return $found
}

function Get-AefosRsVarsPath {
  param([Parameter(Mandatory = $true)][string] $Bds)
  Join-Path ${env:ProgramFiles(x86)} "Embarcadero\Studio\$Bds\bin\rsvars.bat"
}

function Get-AefosFrameworkVersion {
  <#
    .SYNOPSIS
      The .NET framework version a given rsvars.bat puts on PATH, as a number.

    .DESCRIPTION
      This decides which MSBuild a command-line build gets, and the versions
      disagree: 10 Seattle's rsvars sets v3.5, where the AfterTargets attribute
      our .dproj staging target uses does not exist yet. Returns 0 when the file
      cannot be read or declares nothing - callers should treat that as "old".
  #>
  param([Parameter(Mandatory = $true)][string] $RsVarsPath)
  if (-not (Test-Path $RsVarsPath)) { return 0.0 }
  $line = Select-String -Path $RsVarsPath -Pattern 'FrameworkVersion\s*=\s*v([\d.]+)' |
          Select-Object -First 1
  if (-not $line) { return 0.0 }
  return [double] ($line.Matches[0].Groups[1].Value -replace '^(\d+\.\d+).*$', '$1')
}
