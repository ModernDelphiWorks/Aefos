**Aefos AI — Lazarus edition, beta.** Free software under the GNU GPL v3 — see `LICENSE` and `ADDITIONAL-PERMISSIONS.md`.

> ### ⚠️ If you tried 0.21.7-beta, please install this one
> **0.21.7-beta could not be installed.** The IDE rebuild always stopped with
> `Can't find unit Aefos.OTA.Terminal.UI.ComposerHtml` because the installer was
> missing a source folder the package compiles. Nothing was damaged — the rebuild
> fails before replacing your `lazarus.exe`, and your backup stays in the Lazarus
> folder. This release fixes it, verified by compiling the package against the
> exact tree the installer lays down.

## Install

1. **Close Lazarus.** The installer rebuilds `lazarus.exe`, so it cannot be running.
2. Run `Aefos-Lazarus-Setup-0.24.7-beta.exe` (needs admin — it writes into the Lazarus folder).
3. The rebuild takes a couple of minutes. Your original `lazarus.exe` is backed up
   beside it first.
4. Reopen Lazarus. Aefos appears in the menu bar.

**Requirements:** Lazarus with FPC 3.2.2 (32-bit IDE) · Windows · the
[WebView2 Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
for the chat panel. The uninstaller restores the stock `lazarus.exe`.

## What's new since 0.21.7-beta

### Installer
- **Fixed the install failure above.** `source\terminal\UI` now ships — the package
  compiles a unit from it, and the folder never reached disk.
- The installer no longer packs compiler intermediates (`.dcu`/`.ppu`/`.o`/`.a`) or
  stale bundled-addon archives, so a clean checkout and a build machine produce the
  same setup. **6.52 MB → 4.85 MB.**

### Debugger — the agent can now drive a debug session
- Breakpoints: set, remove, list, and read the live debug state.
- Stepping: step over / into / out, continue, run-to-line, pause.
- Inspection: local variables, expression evaluation, and the call stack.
- Breakpoints resolve to the full source path, so they actually bind and halt on the
  line (a raw unit name never bound to DWARF).

> **Known issue, upstream:** an access violation can occur when closing the IDE after
> a debug session. Traced to a use-after-free in the FPC heap manager during the
> FpDebug teardown race — it reproduces without Aefos installed and is not caused by
> this plugin. It happens only on close and destroys nothing.

### Agent + tools
- **`aefos install <mcp>` now reaches every executor.** An installed MCP addon's
  tools are re-exposed on the Aefos MCP server itself, so Claude, Codex, Gemini,
  Ollama — and any CLI added later — get them with no per-executor configuration.
- The **Desktop MCP ships inside the installer** and is registered offline at setup,
  so desktop automation works out of the box with no download.
- `ExecuteIDEAction` lets the agent run any IDE command by name (destructive ones are
  refused), and `ListIDEActions` enumerates what is available.
- A tool to propose a GitHub issue from the conversation.
- Optional auto-save after agent edits (setting).

### Change review
- Inline diff in the editor gutter: the removed line struck through in red above the
  new line in green, with accept ✓ / reject ✗ per block.
- Approving or rejecting a block collapses it correctly — fixed a crash
  (`List index out of bounds`) when the mouse moved over a just-approved block.
- Fixed revealing a removed block that had been scrolled out of view.

### Terminal & chat
- Terminal toolbar and Action Center; scrollbar follows the IDE theme.
- Mouse wheel scrolls the chat panel.
- Fixed a stale MCP bridge that broke the agent's tool connection on some machines.

## Verify your download

```
sha256  d1e611ee5c608b7dcaa0255896d9146a921346323dcbd39dab35d87d622dad0d
```

```powershell
Get-FileHash .\Aefos-Lazarus-Setup-0.24.7-beta.exe -Algorithm SHA256
```

## Feedback

This is a beta — please report anything that breaks, especially install problems on a
Lazarus setup different from the usual `C:\lazarus`.
