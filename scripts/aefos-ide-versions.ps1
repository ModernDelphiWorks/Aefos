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

function Get-AefosIdePackageSuffix {
  <#
    .SYNOPSIS
      The suffix a given RAD Studio puts on its package file names: 230, 290, 370.

    .DESCRIPTION
      Our BPLs carry this suffix too, so an Aefos package built for Seattle is
      Aefos.MCP.Core230.bpl and cannot be mistaken for the Athens one. Without it
      every version shipped the same file name, and on a machine with more than
      one IDE the first Bpl folder on PATH answered for all of them - which is how
      a Seattle IDE came to load a Sydney BPL.

      MEASURED, not tabulated. rtl<suffix>.bpl sits in every version's bin folder,
      so the number is read off the target IDE rather than remembered here.
      Aefos.LibSuffix.inc does keep the same numbers on the Pascal side, because
      {$LIBSUFFIX} needs a literal - but reading from disk here means a
      disagreement between the two surfaces as a missing file while staging,
      loudly, instead of as a wrongly-named BPL that ships.

      There is no formula to derive: 22.0 -> 280 and 23.0 -> 290 are ten apart,
      23.0 -> 37.0 is eighty.
  #>
  param([Parameter(Mandatory = $true)][string] $Bds)
  $bin = Join-Path ${env:ProgramFiles(x86)} "Embarcadero\Studio\$Bds\bin"
  $rtl = Get-ChildItem $bin -Filter 'rtl*.bpl' -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -match '^rtl(\d+)\.bpl$' } |
         Select-Object -First 1
  if (-not $rtl) {
    throw "Cannot read the package suffix for BDS $Bds : no rtl<suffix>.bpl in $bin."
  }
  return [regex]::Match($rtl.Name, '^rtl(\d+)\.bpl$').Groups[1].Value
}

function Get-AefosFrameworkVersion {
  <#
    .SYNOPSIS
      The .NET framework version a given rsvars.bat DECLARES, as a number.

    .DESCRIPTION
      Informational only - see Get-AefosMSBuildOverrideDir for the decision.
      Returns 0 when the file cannot be read or declares nothing.
  #>
  param([Parameter(Mandatory = $true)][string] $RsVarsPath)
  if (-not (Test-Path $RsVarsPath)) { return 0.0 }
  $line = Select-String -Path $RsVarsPath -Pattern 'FrameworkVersion\s*=\s*v([\d.]+)' |
          Select-Object -First 1
  if (-not $line) { return 0.0 }
  return [double] ($line.Matches[0].Groups[1].Value -replace '^(\d+\.\d+).*$', '$1')
}

function Get-AefosMSBuildOverrideDir {
  <#
    .SYNOPSIS
      Directory to prepend to PATH so msbuild is both PRESENT and new enough.
      Empty string when the IDE's own rsvars already gives a usable one.

    .DESCRIPTION
      Two separate ways a RAD Studio rsvars.bat leaves a build without a working
      msbuild, and BOTH were met in the wild:

      1. It points at a real MSBuild that is too OLD. 10 Seattle and 10.1 Berlin
         set FrameworkVersion=v3.5, and MSBuild 3.5 cannot parse the AfterTargets
         attribute our .dproj staging target uses (MSB4066).

      2. It points at a directory that DOES NOT EXIST. 10.3 Rio sets v4.5 - but
         .NET 4.5 is an in-place update of 4.0 and never had its own folder, so
         FrameworkDir resolves to nothing and the build dies with "'msbuild' is
         not recognized". A version check alone reads 4.5, concludes "new enough"
         and walks straight into it.

      Hence this looks at what is actually THERE rather than at what the file
      claims: does that directory hold MSBuild.exe, and is it 4.0 or newer? Only
      then is it left alone.
  #>
  param([Parameter(Mandatory = $true)][string] $RsVarsPath)

  $fallback = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'

  $declared = 0.0
  $dir = $null
  if (Test-Path $RsVarsPath) {
    $declared = Get-AefosFrameworkVersion $RsVarsPath
    $line = Select-String -Path $RsVarsPath -Pattern 'FrameworkDir\s*=\s*(.+)$' |
            Select-Object -First 1
    if ($line) { $dir = $line.Matches[0].Groups[1].Value.Trim() }
  }

  $usable = $dir -and (Test-Path (Join-Path $dir 'MSBuild.exe')) -and ($declared -ge 4.0)
  if ($usable) { return '' }
  return $fallback
}
