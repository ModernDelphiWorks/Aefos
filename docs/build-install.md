# Build & Install

> This is the **monorepo** build/install guide.

## Prerequisites

| Item | Requirement |
|------|-------------|
| IDE | RAD Studio **Delphi 13** (BDS 37.0) — minimum and only supported version. Backports are out of scope. |
| Platform | **Windows**. Design-time BPLs build for **Win32** (classic 32-bit IDE) and **Win64 Modern** (D13's separate 64-bit IDE); the BPL must match the IDE process bitness. The installer ships Win32. |
| Rich rendering | **WebView2 runtime** (Microsoft Edge Evergreen). Without it, the Chat panel falls back to plain-text `TRichEdit`. Ships with current Windows 10/11. |
| AI CLI | A **user-supplied external CLI** — Claude Code (MVP), Codex, Copilot CLI, or Gemini. No CLI is bundled; no credentials are managed. Without one, dispatch does nothing. |
| PyTools (optional) | A **Python** interpreter (`py`/`python`) to *run* the drop-a-folder Python MCP tools — detected, never bundled. |
| Shell (optional) | **PowerShell 7+** (`pwsh`) for the helper scripts. |

## Two paths

- **End users → the installer.** An Inno Setup installer in [`installer/`](../installer/)
  produces `Aefos-Setup-<ver>.exe` that copies the BPLs, registers the Chat +
  Terminal design packages in the IDE, ships `mcp-bridge.ps1`, generates the CLI
  `.mcp.json`, and installs the default PyTools — then detects (never bundles) the AI
  CLI / Python / WebView2. See `installer/README.md`. **Current build is `1.0.0`.**
- **Developers → build from source** (below), then optionally run
  `installer/build-installer.ps1` to produce the setup `.exe`.

## Build (RAD Studio IDE)

The product builds from `packages/Delphi/AefosGroup.groupproj` (eleven packages).

1. Open `packages/Delphi/AefosGroup.groupproj` in RAD Studio Delphi 13.
2. Select the **Release / Win32** configuration (see the Release caveat below).
3. Build the packages **in dependency order** (the group's `CallTarget` order):

   ```
   Aefos.WebView
   → dclAefosWebView
   → Aefos.Harness
   → Aefos.Providers
   → Aefos.Tools
   → Aefos.MCP.Core
   → Aefos.MCP.Tools.OTA
   → Aefos.Data
   → Aefos.OTA.Chat
   → Aefos.OTA.Terminal
   ```

   Building the whole group respects this order; if you build individually, build a
   package only after the ones it depends on.

The build files use repo-relative paths (`..\..\source\…`) — there are **no
hardcoded absolute paths**, so the group builds from wherever you cloned the repo.

### Release caveat (ADR-270)

Distribute **Release** builds only. The Chat package (`Aefos.OTA.Chat`) has an
`{$IFDEF DEBUG}` block that links units from the test tree and the in-IDE L5
self-test channel. A **Debug** build pulls those test units into the distributed BPL
and makes it depend on a test tree existing on the target machine. With `DEBUG`
undefined (Release), the shipped BPL links **zero** test units.

### Headless build (partial)

The headless build script is `scripts/build-packages.ps1` (`-Version 23.0|37.0|all`),
which builds the full package group. Treat the IDE groupproj build above as the
reference path until
a monorepo-wide build script lands. Each package's Release/Win32 build auto-stages its
`.bpl` into `installer/bpl` via a post-build target.

## Install into the IDE

> **Mandatory order (ADR-271):** the runtime packages must be reachable **before**
> the design-time plugin BPLs load. Each plugin BPL `requires` the core, and loads it
> at registration time.

1. **Make the runtime BPLs reachable.** Put the built BPLs in a fixed folder (e.g.
   `C:\Aefos\bpl`) and add it to the Windows **PATH**, or to the IDE library
   path under **Tools → Options → Language → Delphi → Library → Library path**
   (Win32). This ensures the runtime BPLs (`Aefos.WebView`, `Aefos.Harness`,
   `Aefos.Providers`, `Aefos.Tools`, `Aefos.MCP.Core`, `Aefos.MCP.Tools.OTA`,
   `Aefos.Data`) are found at load time.

   > **Every file name carries the IDE's package suffix** — the same one
   > Embarcadero puts on theirs: `Aefos.MCP.Core230.bpl` on 10 Seattle, `...270`
   > on Sydney, `...290` on Delphi 12, `...370` on Delphi 13. That is what lets
   > two RAD Studios share a machine. Without it every version ships the same
   > file name, the first `Bpl` folder on `PATH` answers for all of them, and a
   > Seattle IDE ends up loading a Sydney package.
2. **Register the design-time package(s).** Go to **Components → Install Packages… →
   Add…** and select the design-time BPL(s) you want (`<sfx>` is your IDE's
   suffix — `290` on Delphi 12):
   - `Aefos.OTA.Chat<sfx>.bpl` — the AI chat panel
   - `Aefos.OTA.Terminal<sfx>.bpl` — the docked terminal
   - `dclAefosWebView<sfx>.bpl` — (optional) the `TAefosWebView` palette component

   The IDE loads the design-time package and, through its `requires` chain, the
   runtime core. You do **not** install the runtime packages separately — they only
   need to be reachable on the search path (step 1).
3. **Restart RAD Studio** so the menu, Options pages, and panels register cleanly.

## Post-install verification

After restarting the IDE, check:

- [ ] All selected BPLs built and installed **with no error**.
- [ ] The top-level **Aefos AI** menu appears in the IDE menu bar (with Chat /
      Terminal submenus).
- [ ] **Tools → Options** shows the **Aefos** node with its pages (e.g.
      **AI Chat**, **MCP Server**, **Terminal**).
- [ ] The dockable **Aefos Chat** panel opens from the menu.
- [ ] (If installed) the **Terminal** dock opens from the menu.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Chat panel shows plain text, no Markdown | WebView2 runtime missing → install Edge Evergreen Runtime. |
| Plugin BPL fails to load (`requires` error) | Runtime core BPLs not on the search path → revisit install step 1. |
| Dispatch "does nothing" | No external CLI configured → set the CLI binary path in the Aefos Options page. |
| Test units linked in a distributed BPL | Built in Debug → rebuild in **Release** (ADR-270). |
| Two plugins fight over a pipe / load fails on second BPL | Hosts need **distinct pipe names**; restart the IDE. |
