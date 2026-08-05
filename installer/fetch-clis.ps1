<#
  Stages the bundled third-party AI CLIs into installer\redist\cli\ so the
  installer (Aefos.iss [Files]) can ship them beside AefosAgent.exe in
  %APPDATA%\Aefos\bin. Run this BEFORE build-installer.ps1 on every release so
  the shipped CLIs are the CURRENT upstream versions ("evergreen at release").

  What it stages (redist\cli\*.exe is gitignored — fetched fresh, never committed):
    - codex.exe   : official standalone Windows binary (Apache-2.0), openai/codex
                    GitHub release asset codex-x86_64-pc-windows-msvc.exe.
    - gemini.exe  : Apache-2.0 Node app with NO official Windows binary (verified:
                    releases carry only a JS bundle + macOS zips), so we COMPILE one
                    from the published npm package with Bun's --compile (ESM + code-
                    splitting aware, where Node SEA and pkg both fail on this bundle).
                    Needs Node/npm on the build machine; Bun is pulled via npx.
    - copilot.exe : NOT bundled — its license forbids wrapping/repackaging and there
                    is no official standalone binary, so a SEA build is disallowed.
                    Detect-only, like Claude Code.
    - THIRD-PARTY-LICENSES.txt : aggregated attribution for whatever WAS staged.

  Claude Code is intentionally NOT bundled (proprietary, non-redistributable).

  Usage:
    pwsh -File installer\fetch-clis.ps1
    pwsh -File installer\fetch-clis.ps1 -OutDir <dir> -CodexTag rust-v0.144.4
  A GitHub token in $env:GITHUB_TOKEN is used (if present) to dodge API rate limits.
#>
[CmdletBinding()]
param(
  [string]$OutDir = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'redist\cli'),
  # Empty = latest release. Pin a tag (e.g. 'rust-v0.144.4') for a reproducible build.
  [string]$CodexTag = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # keeps Invoke-WebRequest fast/quiet

function New-GhHeaders {
  $h = @{ 'User-Agent' = 'Aefos-Installer'; 'Accept' = 'application/vnd.github+json' }
  if ($env:GITHUB_TOKEN) { $h['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
  return $h
}

function Get-GhRelease {
  param([string]$Repo, [string]$Tag)
  $url = if ($Tag) { "https://api.github.com/repos/$Repo/releases/tags/$Tag" }
         else      { "https://api.github.com/repos/$Repo/releases/latest" }
  return Invoke-RestMethod -Uri $url -Headers (New-GhHeaders)
}

function Save-Asset {
  param([object]$Release, [string]$AssetName, [string]$Dest)
  $asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
  if (-not $asset) {
    throw "Asset '$AssetName' not found in release '$($Release.tag_name)'. " +
          "Available: $(( $Release.assets | ForEach-Object name ) -join ', ')"
  }
  Write-Host "  downloading $AssetName ($([math]::Round($asset.size/1MB,1)) MB)..." -ForegroundColor DarkGray
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $Dest -Headers (New-GhHeaders)
}

function Get-RawText {
  param([string]$Url)
  try { return (Invoke-WebRequest -Uri $Url -Headers @{ 'User-Agent' = 'Aefos-Installer' }).Content }
  catch { return "  (could not fetch $Url : $($_.Exception.Message))" }
}

function Build-GeminiExe {
  # Gemini ships no Windows binary — only a JS bundle. Compile a standalone
  # gemini.exe from the published npm package with Bun's --compile. Bun is ESM +
  # code-splitting aware; Node SEA (single-file only) and pkg (ESM chunk resolution
  # fails at runtime, ERR_MODULE_NOT_FOUND) both proved unable to package this
  # bundle. Apache-2.0 permits the repackage (unlike Copilot's license). Needs
  # Node/npm on the build machine; Bun is pulled via npx. Returns the gemini-cli
  # version on success, $null if the toolchain is missing.
  param([string]$OutExe)
  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host "  skip  npm not found. Install Node.js 20+ and re-run to build gemini.exe." -ForegroundColor Yellow
    return $null
  }
  $work = Join-Path ([System.IO.Path]::GetTempPath()) 'aefos-gemini-build'
  if (Test-Path $work) { Remove-Item -Recurse -Force $work }
  New-Item -ItemType Directory -Force $work | Out-Null
  '{ "name": "aefos-gemini-build", "private": true }' |
    Set-Content (Join-Path $work 'package.json') -Encoding UTF8

  Push-Location $work
  try {
    # 1. Install the CLI from npm (its bundle + deps). cmd /c: npm.cmd mangles
    #    args under PowerShell's call operator ("Unknown command: pm").
    cmd /c "npm install @google/gemini-cli --no-audit --no-fund --loglevel=error"
    if ($LASTEXITCODE -ne 0) { throw "gemini: npm install failed" }
    $pkgDir = Join-Path $work 'node_modules\@google\gemini-cli'
    $pj = Get-Content (Join-Path $pkgDir 'package.json') -Raw | ConvertFrom-Json
    # 2. Resolve the bin entry (bundle/gemini.js today) from package.json "bin".
    $binRel = if ($pj.bin -is [string]) { $pj.bin }
              elseif ($pj.bin.gemini) { $pj.bin.gemini }
              else { ($pj.bin.PSObject.Properties | Select-Object -First 1).Value }
    $binPath = Join-Path $pkgDir $binRel
    # 2b. Generate the Aefos entry shim. Compiling the package's bin DIRECTLY
    #     produces an exe that cannot run AT ALL -- proven 2026-08-03 against
    #     v0.50 (shipped) and v0.53.1 (current), so this is the shape of the
    #     package, not a bad version:
    #
    #       (a) RELAUNCH. bundle/gemini.js re-execs itself with
    #           spawn(process.execPath, ['--max-old-space-size=N', script, ...])
    #           to raise the V8 heap. In a compiled binary process.execPath IS
    #           gemini.exe, so those node flags arrive as CLI arguments and yargs
    #           aborts with "Unknown arguments: max-old-space-size,
    #           maxOldSpaceSize" -- EVERY invocation, including a plain -p.
    #           GEMINI_CLI_NO_RELAUNCH is the CLI's own escape hatch for this.
    #
    #       (b) MISSING DATA FILES. SandboxPolicyManager reads
    #           path.join(dirname(import.meta.url), 'policies', '*.toml'), which
    #           inside the binary is Bun's VIRTUAL root. `bun build --compile`
    #           bundles the JS graph only, so startup dies on ENOENT
    #           policies\sandbox-default.toml. They are embedded as files here.
    #
    #     The policy list is ENUMERATED from the package, never hardcoded: a
    #     release that adds or renames one is picked up, and if upstream drops
    #     the folder entirely the shim degrades to fixing (a) alone.
    $entryPath = Join-Path $work 'aefos-gemini-entry.mjs'
    $polDir = Join-Path (Split-Path -Parent $binPath) 'policies'
    $imports = New-Object System.Collections.Generic.List[string]
    $mapRows = New-Object System.Collections.Generic.List[string]
    if (Test-Path $polDir) {
      $i = 0
      foreach ($toml in (Get-ChildItem $polDir -Filter *.toml -File | Sort-Object Name)) {
        $var = "pol$i"; $i++
        $rel = ($toml.FullName.Substring($work.Length + 1) -replace '\\', '/')
        $imports.Add("import $var from './$rel' with { type: 'file' };")
        $mapRows.Add("  '$($toml.Name)': $var,")
      }
      Write-Host "  ..  embedding $($i) policy file(s) Bun would otherwise drop" -ForegroundColor DarkGray
    }
    $entryRel = ($binPath.Substring($work.Length + 1) -replace '\\', '/')
    $shim = @"
// GENERATED by installer\fetch-clis.ps1 -- do not edit by hand.
// Fixes the two packaging defects of `bun build --compile` over
// @google/gemini-cli; see the comments in that script for the full story.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
$($imports -join "`n")

const EMBEDDED = {
$($mapRows -join "`n")
};

// (a) Never relaunch: the child would be gemini.exe with node flags as argv.
process.env.GEMINI_CLI_NO_RELAUNCH = '1';

// (b) Materialise the embedded policies once, then redirect ONLY the reads that
// would otherwise ENOENT -- an on-disk install keeps reading its own files.
const outDir = path.join(os.tmpdir(), 'aefos-gemini-policies-$($pj.version)');
try {
  fs.mkdirSync(outDir, { recursive: true });
  for (const [name, embedded] of Object.entries(EMBEDDED)) {
    const target = path.join(outDir, name);
    if (!fs.existsSync(target)) fs.writeFileSync(target, fs.readFileSync(embedded));
  }
} catch {
  // A read-only temp dir is not worth killing the CLI over: the redirect below
  // then finds nothing and the upstream error surfaces unchanged.
}
const realReadFileSync = fs.readFileSync;
fs.readFileSync = function (target, ...rest) {
  if (typeof target === 'string' && target.includes('policies')) {
    const base = path.basename(target);
    if (Object.prototype.hasOwnProperty.call(EMBEDDED, base) && !fs.existsSync(target)) {
      return realReadFileSync.call(this, path.join(outDir, base), ...rest);
    }
  }
  return realReadFileSync.call(this, target, ...rest);
};

await import('./$entryRel');
"@
    Set-Content -Path $entryPath -Value $shim -Encoding UTF8
    # 3. Bun compiles the whole ESM graph (chunks included) into one Windows exe.
    cmd /c "npx --yes bun build `"$entryPath`" --compile --target=bun-windows-x64 --outfile `"$OutExe`""
    if (-not (Test-Path $OutExe)) { throw "gemini: Bun did not produce the exe" }
    # 4. RUNNABLE GATE. "Bun produced an exe" was the check this script had, and
    #    it stayed green for the whole life of a gemini.exe that could not answer
    #    a single prompt -- the exact trap the house rule warns about (a gate that
    #    measures the wrong artifact). So RUN it, on the path that actually breaks.
    #    Both defects fire before any auth or network, so this gate needs neither:
    #    the relaunch is the first thing run() does, and the policy load happens in
    #    loadCliConfig. We assert their fingerprints are ABSENT; whatever the CLI
    #    says after that (auth, quota, offline) is not our business.
    $probe = (& $OutExe --yolo --skip-trust -p 'ping' 2>&1 | Out-String)
    if ($probe -match 'max-old-space-size') {
      throw "gemini: the compiled exe still self-relaunches (the shim did not take). Output: $probe"
    }
    if ($probe -match 'sandbox-default\.toml|ENOENT.*policies') {
      throw "gemini: the compiled exe is missing its policy data files (embedding did not take). Output: $probe"
    }
    if ((& $OutExe --version 2>&1 | Out-String).Trim() -notmatch [regex]::Escape($pj.version)) {
      throw "gemini: the compiled exe does not report v$($pj.version)."
    }
    Write-Host "  ok  gemini.exe  (v$($pj.version), Bun compile, runnable gate passed)" -ForegroundColor Green
    return $pj.version
  }
  finally { Pop-Location }
}

# --- prepare staging dir --------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-Host "Staging bundled CLIs into: $OutDir" -ForegroundColor Cyan

$staged = @()

# --- codex (official standalone binary) -----------------------------------------
Write-Host "codex:" -ForegroundColor White
$codexRel = Get-GhRelease -Repo 'openai/codex' -Tag $CodexTag
Save-Asset -Release $codexRel -AssetName 'codex-x86_64-pc-windows-msvc.exe' `
           -Dest (Join-Path $OutDir 'codex.exe')
Write-Host "  ok  codex.exe  ($($codexRel.tag_name))" -ForegroundColor Green
$staged += [pscustomobject]@{ Name = 'Codex CLI'; Repo = 'openai/codex'; Tag = $codexRel.tag_name; License = 'Apache-2.0' }

# --- gemini (compiled from the npm package with Bun) ----------------------------
Write-Host "gemini:" -ForegroundColor White
$geminiVer = Build-GeminiExe -OutExe (Join-Path $OutDir 'gemini.exe')
if ($geminiVer) {
  $staged += [pscustomobject]@{ Name = 'Gemini CLI'; Repo = 'google-gemini/gemini-cli'; Tag = "v$geminiVer"; License = 'Apache-2.0' }
}

# --- copilot (NOT bundled — license forbids repackaging) ------------------------
Write-Host "copilot:" -ForegroundColor White
Write-Host "  skip  not bundled by design: its license forbids wrapping/repackaging " -ForegroundColor DarkGray -NoNewline
Write-Host "and there is no official standalone binary (detect-only, like Claude)." -ForegroundColor DarkGray

# --- aggregated attribution -----------------------------------------------------
$licPath = Join-Path $OutDir 'THIRD-PARTY-LICENSES.txt'
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('Third-party AI CLI binaries bundled with Aefos AI')
[void]$sb.AppendLine('==================================================')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('These command-line tools are distributed with Aefos AI as a convenience.')
[void]$sb.AppendLine('They are independent programs, each under its own license below. Aefos AI')
[void]$sb.AppendLine('does not modify them and claims no ownership of them.')
[void]$sb.AppendLine('')
foreach ($s in $staged) {
  [void]$sb.AppendLine('--------------------------------------------------')
  [void]$sb.AppendLine("$($s.Name)  ($($s.License))")
  [void]$sb.AppendLine("Source: https://github.com/$($s.Repo)  (version $($s.Tag))")
  [void]$sb.AppendLine('--------------------------------------------------')
  [void]$sb.AppendLine('')
}
foreach ($s in $staged) {
  [void]$sb.AppendLine("=== $($s.License) — $($s.Name) ===")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine((Get-RawText "https://raw.githubusercontent.com/$($s.Repo)/main/LICENSE"))
  [void]$sb.AppendLine('')
}
Set-Content -Path $licPath -Value $sb.ToString() -Encoding UTF8
Write-Host "  ok  THIRD-PARTY-LICENSES.txt" -ForegroundColor Green

Write-Host ''
Write-Host "Done. Staged: $(( $staged | ForEach-Object Name ) -join ', ')." -ForegroundColor Green
Write-Host "The installer omits any binary not staged (skipifsourcedoesntexist)." -ForegroundColor DarkGray
