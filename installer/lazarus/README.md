# Aefos AI - Lazarus edition installer

An Inno Setup installer that gives a user Lazarus **with Aefos AI in it**, without
touching the Lazarus he already has: run `setup.exe`, and after a couple of minutes
there is an **Aefos AI for Lazarus** entry in his Start menu.

## Why this is not like the Delphi installer

The Delphi installer drops `.bpl` files and registers them in the registry; the
IDE loads them at runtime. **Lazarus cannot do that.** A Lazarus design package is
**statically linked into `lazarus.exe`** - there is no hot-load, no drop-and-
register. "Installing" a design package means **compiling a `lazarus.exe`** with
the package in its static package list.

So this installer ships the package **sources** (not a prebuilt binary) plus
PowerShell engines that compile them on the user's machine.

## The isolated model (milestone 2) - and what it replaced

Up to 0.24.7 the install was **in place**: it relinked the *user's* `lazarus.exe`,
backed the old one up, added an entry to two config lists Lazarus reads *by index*,
dropped three DLLs in his folder, and rewrote ~200 MB of his unit output. Every
field incident of this edition came out of that model, and the uninstall had to put
all of it back correctly.

Now the installer builds a **second IDE**, entirely inside the user's own profile:

```
%LOCALAPPDATA%\Aefos\lazarus\        <- ours: config, build output, logs, the stamp
%LOCALAPPDATA%\Aefos\lazarus\bin\    <- lazarus.exe + the 3 runtime DLLs
```

It reaches his installation only through `--lazarusdir` (same LCL, same FPC, same
sources - no duplicated tree, no version conflict) and **writes nothing on his
side**: not his binary, not his config, not even to *add*. The uninstall is then
"remove one directory and one shortcut", and *"my IDE is exactly as it was"* stops
being a restore procedure and becomes an **empty diff**.

`<pcp>\bin` is not a free choice: `ide\lazarusmanager.pas:314` is the only place
`startlazarus` looks for an alternative IDE, and `ide\main.pp:1289` treats
`<pcp>\bin\lazarus.exe` as the canonical IDE of that pcp. Nothing we put in that
directory may sort **before** `lazarus.exe` either - see
`scripts\aefos-laz-isolated-layout.ps1`, which owns that rule and enforces it
before every copy.

## What gets installed, and where

The payload lands under `{userpf}\Aefos AI\Lazarus`
(`%LOCALAPPDATA%\Programs\Aefos AI\Lazarus`):

```
Aefos AI\Lazarus\
  aefos-laz-install-isolated.ps1     builds and installs our IDE
  aefos-laz-uninstall-isolated.ps1   removes it (run by the uninstaller)
  aefos-laz-reconcile-ide.ps1        repairs/rebuilds it when his Lazarus moves on
  aefos-laz-isolated-layout.ps1      the layout + containment rules (shared)
  aefos-laz-seed-pcp.ps1             seeds our own pcp (shared)
  aefos-laz-import-components.ps1    brings his own components across (shared)
  aefos-laz-ide-drift.ps1            drift detection (shared)
  WebView2Loader.dll, sqlite3.dll, libvterm.dll
  packages\Lazarus\Aefos.Lazarus.IDE.lpk
  source\...                         only the subtrees the .lpk compiles
  cli\, addons\                      the shared CLI + the bundled Desktop MCP addon
```

The engines resolve each other **by `$ScriptDir`**, so they must stay in the same
directory. `aefos-laz-migrate.ps1` and the legacy `aefos-laz-uninstall.ps1` are
**not** installed: they are extracted to `{tmp}` for the one-time migration below.

**Why `{userpf}` and `PrivilegesRequired=lowest`:** nothing outside the user's own
profile is written any more, so nothing justifies elevation - and elevation was
actively harmful, because under an elevated setup `{userappdata}` /
`{localappdata}` resolve to the *elevating admin's* profile (ISCC warns about
exactly this). The payload still has to be **stable** (never `%TEMP%`): the
reconcile/rebuild engine reads it again later, as the plain user, from inside the
IDE. And it must **not** be `{localappdata}\Aefos\Lazarus` - Windows paths are
case-insensitive, so that directory *is* the isolated IDE, which the install engine
would reject as undeclared and the uninstall engine would delete.

## Migration from an in-place install

A machine that still carries the old model is handed its IDE back **before**
anything of ours is written, from `PrepareToInstall`:

| exit | meaning | installer |
|-----:|---------|-----------|
| 0 | nothing to migrate, or migrated and verified | continues silently |
| 3 | partial: everything reversible was reverted, the rest needs the user | continues, shows the report |
| 4 | refused: the machine is not a state it can reason about; nothing changed | **stops** |
| 1 / -1 | hard error / could not run | **stops** |

The report, the journal and the transcripts are left in
`%LOCALAPPDATA%\Aefos\lazarus\` (`migration-report.txt`, `migration-state.json`,
`migration-engine.log`, `migration-setup.log`).

The old edition installed **machine-wide** (admin, `{commonpf}`, an HKLM uninstall
key); this one is per-user, so the two are separate installations and the old entry
survives in *Apps & features*. The installer says so at the end - removing it there
is safe once the migration has run.

## Detection logic

- **Lazarus directory / `lazbuild`:** override with `-LazarusDir` (the wizard page
  passes what the user confirmed), else the `LazarusDirectory` his own config
  records, else the usual folders, else the registry.
- **His config (pcp):** `%LOCALAPPDATA%\lazarus`, **read only**. Our IDE gets its
  own pcp, seeded from a copy of his and pointed at his tree.
- The shortcut passes `--scp=<his pcp>`, so the first start seed-copies his editor
  colours, key mappings and code templates (`lazconf.pp CopySecondaryConfigFile`) -
  the isolated IDE opens looking like his, without us ever writing in his config.

## What the install proves before declaring success

1. `staticpackages.inc` in **our** pcp lists `Aefos.Lazarus.IDE`, and our
   `lazarus.exe` carries the package name;
2. every entry in `<pcp>\bin` sorts **after** `lazarus.exe`;
3. every file the install produced is **declared in the layout manifest** (an
   undeclared entry fails the install, so "justify every file" is executable);
4. the produced exe **actually starts** (a link that succeeds is no proof - a
   236 MB PE that linked fine and that Windows refused to load cost a release).

## Uninstall

`aefos-laz-uninstall-isolated.ps1` removes `%LOCALAPPDATA%\Aefos\lazarus`, the
Start-menu shortcut **and the desktop one** (unconditionally - nothing records
whether the box was ticked, and an icon left pointing at a deleted exe is the same
defect as an uninstall that leaves a service running). Both are matched by our
**exact** shortcut name, never by a pattern: his own `lazarus.lnk` is right beside
ours on that desktop. It prints what it deliberately **keeps**: his Lazarus, his
config, `%APPDATA%\Aefos` (the brain shared with the RAD Studio edition) and
`~\.aefos` (addons). It refuses any path that is not ours - drive roots, profile
roots, the shared brain, his config, anything inside his tree, anything that
neither looks like our install nor carries our stamp file.

## Gates

The installer engines are covered by a set of gates the maintainer runs before
a release: the payload tree the installer deposits, install + uninstall with an
EMPTY allowlist on the user's side, the in-place to isolated migration, drift
detection when the user's Lazarus moves, and the target-architecture refusal.

`run-payload-tree-gate.ps1` is the one that answers the 0.21.7 post-mortem: it
stages `{app}` from the `.iss` `[Files]` list *only* and runs the engines from that
tree, because a directory that is used but not shipped passes every repo-based gate
and breaks on every real machine.

`run-target-arch-gate.ps1` answers the 0.24.7 one. This setup does not ship an IDE,
it **builds** one with the user's own FPC, so the product's architecture is *his* -
while the three runtime DLLs we ship are fixed, and i386. On a 64-bit Lazarus the
build succeeds, the installer reports success, and the IDE then dies at
`0xc000007b`, because `libvterm.dll` is a **load-time** import. Every gate we had
measured the wrong artifact ("did it compile", "was an exe produced"); the one that
could have caught it only ever ran on the architecture where the bug does not
exist. The gate proves detection and refusal on a fabricated x86_64 tree - it does
**not** prove a 64-bit IDE works, which needs a real x86_64 Lazarus and an x86_64
payload.

## Build the installer (dev machine)

```powershell
pwsh -File installer\lazarus\build-lazarus-installer.ps1
```

Stages `WebView2Loader.dll`, builds+stages `sqlite3.dll` and `libvterm.dll` into
`redist\`, packs the bundled Desktop MCP addon, and runs ISCC
(`%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`), producing
`installer\lazarus\Output\Aefos-Lazarus-Setup-<ver>.exe`.

### The 64-bit payload

The installer serves whatever architectures it finds under `redist\<cpu>\`, and it
promises exactly those: the ISPP `PayloadCpus` and the `[Files]` entries are both
computed with the same `FileExists`, so a build box that cannot produce the 64-bit
DLLs yields a setup that **refuses** a 64-bit Lazarus with a clear message instead
of building an IDE that dies at `0xc000007b`. Capability and promise come from one
fact; neither is declared by hand.

To produce it, the box needs an **x86_64** mingw-w64 gcc (the same WinLibs UCRT
release as the i686 one, unpacked as `%TEMP%\aefos-tools\mingw64`, or pointed at by
`AEFOS_MINGW64_GCC`). `sqlite3.dll` and `libvterm.dll` are then compiled from the
same vendored C with `-Arch x86_64`. `WebView2Loader.dll` cannot be compiled - it is
a Microsoft binary, and RAD Studio ships **no** 64-bit copy (verified across the
whole Studio tree) - so it is fetched from the official NuGet package:

```powershell
pwsh -File scripts\fetch-webview2-loader.ps1 -Arch x86_64
```

`build-lazarus-installer.ps1` calls that itself when the loader is neither passed
(`-WebView2Loader64`) nor already staged. Every staged DLL has its COFF machine word
verified against the folder it lands in: a directory named `x86_64` is a claim, and
staging a 32-bit DLL under it would ship the very defect the folder exists to fix.

## Run it (target machine)

Run `Aefos-Lazarus-Setup-<ver>.exe` - **no elevation prompt**. Confirm the detected
Lazarus folder, leave (or clear) the **"Create a shortcut for the Aefos AI Lazarus
IDE on my desktop"** box - it ships **ticked**, because that icon is the primary way
this product is opened and his own Lazarus already has one - and wait for the build
(a couple of minutes). Then open it from the desktop icon, or from
**Start menu > Aefos AI > Aefos AI Lazarus IDE**. His own Lazarus keeps working,
unchanged, side by side.

The desktop entry is created by the install **engine**, not by an Inno `[Icons]`
line: its target (`<pcp>\bin\lazarus.exe`) does not exist until the build finishes.
The wizard only forwards the answer (`-DesktopShortcut`).

## Telling the two IDEs apart

Both binaries are called `lazarus.exe` and neither may be renamed
(`ide\lazarusmanager.pas:331` hardcodes the name `startlazarus` looks for), and
both link the MAINICON of *his* `ide\lazarus.res`, so out of the box the two were
indistinguishable in the taskbar and in Alt+Tab. Identity is therefore given at
two points, from **one** file (`installer\lazarus\aefos-lazarus.ico`, regenerated
by `scripts\build-aefos-icon.ps1`):

- **the shell entry** - the install engine sets the shortcut's `IconLocation` to
  the copy in `{app}`;
- **the running IDE** - `source\lazarus\ide\Aefos.Lazarus.AppIdentity.pas` assigns
  `Application.Icon` at startup from the copy in `%APPDATA%\Aefos`, and the LCL
  turns that into `WM_SETICON` on the application window (the taskbar button:
  `ide\lazarus.pp:123` sets `MainFormOnTaskBar := False`) and on every IDE window.

The shortcut name lives in exactly one place,
`scripts\aefos-laz-isolated-layout.ps1` `$Script:AefosIsolatedShortcutName`; the
names it has carried before are listed next to it and are deleted by an install,
so a rename can never leave two entries behind.

## Manual fallback (no installer)

Aefos is a normal Lazarus package, so the classic path always works - at the cost
of the isolation:

1. In Lazarus: **Package -> Open Package File (.lpk)** -> select
   `Aefos.Lazarus.IDE.lpk`.
2. Click **Use -> Install**, and let the IDE rebuild itself when it offers.
3. Copy `WebView2Loader.dll`, `sqlite3.dll` and `libvterm.dll` next to the
   `lazarus.exe` that rebuild produced.

That rebuilds **his** IDE in place, which is exactly what the installer no longer
does.
