# Component — Chat

**BPL:** `Aefos.OTA.Chat` · **Source:** `source/chat` · **Vendored web assets:** marked and
highlight.js ship already embedded in `Aefos.OTA.Chat.UI.OutputPanel.Assets.pas`; their
licences are reproduced verbatim in `THIRD-PARTY-NOTICES.txt`.

## What it is

An in-IDE AI chat/agent panel. **Agent mode is the default.** The developer invokes
skills via `/agent`, the plugin packages Delphi project context, spawns the
configured external CLI (Claude / Codex / Copilot / Gemini), and renders the
streaming output as Markdown inside the IDE. The Chat BPL also **hosts the in-process
MCP server** so the agent can act on the project (see
[../architecture.md](../architecture.md)). The active CLI is chosen via a provider
driver (see [../providers.md](../providers.md)); the first line of every Agent prompt
is the "use the aefos MCP first" directive so weaker CLIs still reach for the tools.

## Source layout (`source/chat`)

| Folder | Contents |
|--------|----------|
| `Adapter/` | OTA wrappers — IDE notifier, main menu, agent-suggest. |
| `Core/` | Domain services — CLI dispatch, skill registry/replicator, command palette, project context builder. |
| `IDE/` | IDE-level features, including the inline **DiffPreview** (red/green editor diff + approval). |
| `UI/` | The Chat panel, output panel, WebView2 edge controller, embedded render assets. |
| `Aefos.OTA.Chat.Register.pas` | Composition root — wires services, registers OTA adapters, starts the MCP host. |

## Key features

- **Skill dispatch.** `/agent` resolves a skill from `.aefos/skills/`, builds a
  Delphi-aware prompt, and dispatches to the external CLI. Free-form input (not a
  skill) goes straight to the CLI as a prompt.
- **Multi-provider.** Claude Code, Codex, GitHub Copilot CLI and Gemini are each
  driven by their own `IExecutorProfile`; the selected model is remembered per
  executor (no model leak across providers). See [../providers.md](../providers.md).
- **Composition WebView2 rendering.** Markdown + syntax highlighting via the custom
  `TAefosWebView` (DirectComposition-hosted), assets embedded as Pascal-string
  constants. This replaced the windowed `TEdgeBrowser` to kill the docked
  blank-on-focus-steal flicker. Falls back to `TRichEdit` without WebView2. See
  [webview.md](webview.md).
- **Inline diff approval.** Before an agent edit applies, the change is shown as an
  in-editor red/green diff with clickable ✓ Apply / ✗ Reject (Tab/Esc or a floating
  overlay). The overlay is positioned using the editor's own line rectangle, so it
  stays correct across resolutions/DPI. Encoding-aware (UTF-8 / ANSI). Routed for
  `EditUnit`, `ReplaceInEditor`, and `SetEditorFullContent`.
- **In-process MCP host.** Serves the HTTP/named-pipe endpoint the CLI connects back
  to (the persistent pipe host starts at BPL load).
- **Sync UX, async I/O.** The panel shows a "processing…" state while harness I/O
  runs on a worker thread; OTA results return via `TThread.Queue`.

## Known issues / notes

- **Docked WebView2 blank** (long blink on Enter; pane not restored across desktop
  layouts) — **resolved** by the composition-hosted `TAefosWebView` plus a
  `ShowChatPanel` re-show guard. See [webview.md](webview.md). Ctrl+V in the docked
  composer now works (anchor-aware focus check).
- **IDE-unload safety.** Every `AddKeyboardBinding` is paired with an explicit
  `RemoveKeyboardBinding` at teardown, and no IDE-held reference is left pointing
  into the BPL — this is a hard rule (see the root `CLAUDE.md`); violating it caused
  a chronic unload AV. Never hook `TEdgeBrowser.WindowProc`.
