# Aefos — Installer (Inno Setup)

`Aefos.iss` builds a single `Aefos-Setup-<ver>.exe` that deploys the
plugin into a target machine's **RAD Studio Delphi 13** IDE: it copies the BPLs,
puts them on the user PATH, and registers the two design-time packages so they
show up **already installed** in the IDE.

> **No `sqlite3.dll`.** SQLite is statically linked into `Aefos.Data.bpl`
> (FireDAC static wrapper). There is no native DLL to ship.

## What ships

| File | Where it goes | Kind |
|------|---------------|------|
Every BPL below carries the IDE's own package suffix — `Aefos.MCP.Core230.bpl`
on 10 Seattle, `...290` on Delphi 12, `...370` on Delphi 13 — exactly as
Embarcadero suffixes `rtl230`/`rtl290`/`rtl370`. That is what keeps two RAD
Studios on one machine from answering for each other's packages, since the IDE
finds a required BPL through `PATH` and every version's `Bpl` folder is on it.

| File | Where it goes | Kind |
|------|---------------|------|
| `Aefos.Tools<sfx>.bpl` | `{app}\Bpl` | runtime |
| `Aefos.MCP.Core<sfx>.bpl` | `{app}\Bpl` | runtime |
| `Aefos.MCP.Tools.OTA<sfx>.bpl` | `{app}\Bpl` | runtime |
| `Aefos.Data<sfx>.bpl` | `{app}\Bpl` | runtime (static SQLite) |
| `Aefos.OTA.Chat<sfx>.bpl` | `{app}\Bpl` | **design-time** (registered) |
| `Aefos.OTA.Terminal<sfx>.bpl` | `{app}\Bpl` | **design-time** (registered) |
| `mcp-bridge.ps1` | `{app}` | Terminal MCP relay (one fixed copy) |
| `pytools\*` (5 default tools) | `{userappdata}\Aefos\pytools` | drop-a-folder Python MCP tools |

The FireDAC / VCL / RTL runtime packages are part of RAD Studio itself and are
**not** bundled — the target machine already has them (it has the IDE).

The **PyTools** are our own `.py` scripts (`<name>\tool.json` + `main.py`), copied to
the folder the plugin scans at runtime; each becomes a live MCP tool. They need a
Python interpreter to **run** — the installer **detects** `py`/`python` and guides
the user if it is missing (we never bundle Python). The user's own dropped tools in
that folder are left untouched.

**Not bundled, on purpose:**
- **The AI CLI (Claude Code / Codex).** Aefos is bring-your-own-CLI; bundling
  another vendor's binary is a redistribution/licensing problem. The installer
  **detects** `claude` on PATH and, if missing, points the user at the official
  installer (`npm i -g @anthropic-ai/claude-code` / <https://claude.com/code>).
- **Python** (for the PyTools) — detected, not bundled. Install from python.org /
  `winget install Python.Python.3.12`.
- **No `sqlite3.dll`** — SQLite is statically linked into `Aefos.Data.bpl`.

### Where the bridge lives (and why not `.aefos`)
`mcp-bridge.ps1` is **shipped tooling**, so it goes in the per-machine install dir
(`{app}`), once. It is **not** put in a project's `.aefos\` (that folder is
per-project *user data* — the commands you/the agent create — and would duplicate
the bridge across projects). The Chat path uses HTTP and needs no bridge at all.

## Folder layout (self-contained)

```
installer/
├── Aefos.iss        the Inno Setup script (sources from .\bpl, outputs to .\Output)
├── build-installer.ps1    stages the 6 BPLs into .\bpl, then runs ISCC
├── README.md              this file
├── bpl/                   staging — the 6 .bpl land here (gitignored)
└── Output/                Aefos-Setup-<ver>.exe lands here (gitignored)
```

The script is **machine-independent**: it reads the BPLs from `.\bpl`, never from a
hardcoded Embarcadero path. The PowerShell helper fills `.\bpl` for you.

> **Win32 only.** These are RAD Studio **design-time** plugins — they `require
> designide` / `vclie` / ToolsAPI, which exist only in the **32-bit IDE**. A
> Win64 build cannot link (no Win64 `designide`) and the 32-bit IDE could not
> load it. There is no Win64 BPL to ship.

## Build the installer (on the DEV machine)

1. Build the whole group in **Release / Win32** so all 6 `.bpl` exist:
   `packages\Delphi\AefosGroup.groupproj`
   (order: Tools → MCP.Core → MCP.Tools.OTA → **Data** → Chat → Terminal).
   Each package's **Release/Win32** build now **auto-stages** its `.bpl` into
   `installer\bpl` (a post-build target in every `.dproj`), so the staging is
   done for you — you can skip straight to `ISCC Aefos.iss`.
2. From `installer/`, run (re-stages defensively, then compiles):
   ```
   pwsh -File build-installer.ps1
   ```
   It copies the 6 BPLs (default source: the RAD Studio public Bpl output) into
   `.\bpl`, then compiles the script. Result: `Output\Aefos-Setup-<ver>.exe`.

   Override paths if needed:
   ```
   pwsh -File build-installer.ps1 -BplSource "D:\my\Bpl" -Iscc "C:\Path\ISCC.exe"
   ```

> If the script reports a missing `.bpl`, you haven't built that package yet
> (most likely `Aefos.Data.bpl` — it's the newest). Build the group first.
> (You can also run `ISCC Aefos.iss` directly once `.\bpl` is populated.)

## Install (on the TARGET machine)

Requirements: RAD Studio Delphi 13 (BDS 37.0) installed; **close the IDE first**.

1. Run `Aefos-Setup-<ver>.exe` (per-user, no admin needed). It detects the
   `claude` CLI and, if missing, tells you how to install it (official source).
2. **Restart RAD Studio.** The packages `Aefos AI - Chat` and
   `Aefos AI - Terminal` are already registered; the **Aefos AI** menu
   appears in the menu bar.
3. **Chat** works now (HTTP MCP, auto-configured). For the **Terminal** MCP, the
   setup generated `{app}\.mcp.json` already pointing at the installed bridge —
   copy it to your Delphi project root (or add its `aefos` block to your
   `~/.claude.json`), and make sure the session matches **Tools → Options →
   Aefos → Terminal** (default `plugin`).
4. No rich Markdown in Chat? Install the WebView2 runtime: <https://aka.ms/webview2>.

Uninstall removes the BPLs, the bridge, the generated `.mcp.json`, the Known-Packages
entries, and the PATH addition.

## Notes / caveats

- The installer registers under **HKCU** (per-user IDE config) and adds to the
  **user** PATH — that's why the IDE must be **restarted** to inherit the runtime
  BPL path. No reboot needed.
- `BdsVer` is `37.0` in the script. If your RAD Studio registers under a different
  BDS version key, change the `#define BdsVer`.
- This installs from already-built BPLs; it does not compile anything. Re-run after
  rebuilding to ship updated BPLs (`ignoreversion` overwrites in place).
