# Changelog

All notable changes to **Aefos AI** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Dates are in `YYYY-MM-DD`.

## [Unreleased]

## [0.30.0-beta] - 2026-07-12
The biggest release since the plugin launched: the agent can now **drive the Delphi
debugger**, and it can run entirely on **local models** — no cloud, no key.

### Added
- **The agent debugs your code — 17 debug tools, live in the IDE.** It sets and clears
  breakpoints (conditional ones too), runs and stops the project, walks the code with
  step-over / step-into / step-out, reads the call stack and local variables, and
  evaluates expressions in the current frame — the same loop you would do by hand,
  driven from chat or the terminal. Ask it to *"find why this returns nil"* and it
  actually breaks, inspects state and tells you, instead of guessing from the source.
- **Local models (Ollama).** Pick **"Local models (Ollama)"** in the AI Flow options and
  the chat runs against your own machine. **Test CLI** pings your Ollama and fills the
  model list with the models you actually have installed. Free tier — no API key, and
  nothing leaves your computer.

### Fixed
- **The Form Designer is no longer bypassable.** `SetDFMContent` could be used to author
  UI as raw DFM text — controls that never sprout in the Designer, fields Delphi never
  declares. The tool now refuses it and steers the agent to the proper Design-mode tools,
  so a form the agent builds is a form the Designer really owns.
- **The terminal no longer freezes on Ctrl+D.** The bundled `claude` profile ran the CLI
  as the root of the terminal session; exiting it with Ctrl+D left the session alive but
  dead inside, and the terminal hung. The profile is gone — open your AI CLI inside a
  normal shell instead, where exiting it just returns you to the prompt. An existing
  profile is removed for you.
- **The chat no longer gets stuck on "working…" after switching provider**, and Stop is
  guarded so it cannot strand the composer.
- **Local models never spawn the wrong CLI** — a stale shared executor path could launch
  a foreign CLI for an Ollama run.

### Changed
- The bundled agent CLI got a leaner tool catalog, better orientation and conversation
  compaction, so long sessions stay coherent and cheaper.

> ⬇️ Free edition: <https://www.pubpascal.dev> · 💎 Subscription plans (Pro): <https://isaquepinheiro.com.br/>

## [0.29.0-beta] - 2026-07-07
### Fixed (refresh 2026-07-08 — installer assets updated in place)
- **MCP now connects on default-policy Windows.** The stdio↔pipe bridge is launched
  with `-ExecutionPolicy Bypass`; a `Restricted` policy (the Windows client default)
  used to kill it at startup, so every CLI reported "handshaking with MCP server
  failed: connection closed".
- **"Test MCP" is now truthful for Codex.** It performs a live MCP handshake through
  the same per-run wiring the chat uses, instead of probing `codex mcp list` (which
  can never see it) and always reporting "aefos not found in this project".
- **The chat header honors your saved executor on the Welcome page.** The model list
  showed the default executor's models and a picked model never took until the first
  message; the header now resolves the executor exactly like sending does.
- **Fixed an IDE crash from the Terminal "Test MCP" button** (`External exception
  C0150014`, then "Unknown Hard Error" on IDE close). The MCP host is no longer
  restarted on a no-op apply, and its shutdown can no longer deadlock against an
  in-flight tool call.
- **The Login button now shows "Logged in"** when the Codex CLI reports an
  authenticated session.
- **Codex model list refreshed to the current generation** (`gpt-5.5`, `gpt-5.4`,
  `gpt-5.4-mini`) — the backend retired the old `gpt-5-codex`/`gpt-5` slugs. An
  untouched old list migrates automatically; a customized list is never modified.
- **"Test CLI" now discovers the models your account actually supports** — for
  Codex it reads the CLI's own per-account catalog and fills the model list
  ("Connected … - N model(s) on your account"), the same way the Ollama Test
  fills the list from your local models. CLIs that publish no list keep the
  curated suggestions plus the "+" button.

> ⬇️ Free edition: <https://www.pubpascal.dev> · 💎 Subscription plans (Pro): <https://isaquepinheiro.com.br/>

### Fixed
- **Sending from the Welcome page now works.** With no project open, the chat used
  to echo your message and silently do nothing (the report behind most 0.28.0
  complaints). The agent now answers from the Welcome page and can even open or
  create the project for you.
- **A stuck "working..." never bricks the chat again.** If the completion signal is
  ever lost, the composer detects the stale state and heals itself; your typed text
  is preserved.
- **Blank assistant bubbles auto-recover.** A corrupted chat page (the cause of
  empty responses) is detected and reloaded automatically, replaying the conversation.
- **Garbled characters fixed** (`â€"` instead of `—`) in the consent dialog title,
  the audit log and the tool descriptions the agent reads.

### Added
- **Send while the agent works.** Type and press Enter mid-run: the message shows as
  a bubble at once, a "⏳ N messages queued" line tracks what's waiting, and each
  queued message dispatches automatically as its own turn when the current one
  finishes — the agent keeps the full conversation context. **Stop cancels only the
  current turn**; queued messages survive and run next. Starting a new session (or
  switching Chat↔Agent) discards the leftover queue.
- **`.pas` ↔ `.dfm` desync guard.** Bulk writes that would orphan a component (form
  declares it, code doesn't) are refused with a machine-actionable reason, steering
  the agent to the proper Design-mode tools.

### Changed
- **Faster first reaction on screenshot prompts.** The agent is instructed to start
  building immediately (project first, then component by component) instead of
  planning in silence.

## [0.28.0-beta] - 2026-07-04

### Added
- **Screenshot the form (`CaptureForm`).** The agent can capture the live form
  designer to *see* what it built.
- **Design↔Code guidance.** The agent receives advisory next-prompts that conduct it
  smoothly through the Design/Code flow.
- **`SetComponentProperty` accepts named constants.** Set a `TColor`/`TCursor` by
  name (e.g. `clSkyBlue`, `crHandPoint`), not just a raw value.

### Changed
- **Change-review gutter (the Cursor-style ✓/✗ diff).** Real unified-diff `+`/`-`
  markers; per-unit review state (opening another file no longer disturbs a review
  in progress); "Wait for my approval" is honoured (a save never silently
  auto-accepts); `InsertCodeAtCursor` and `ReplaceEditorSelection` now route through
  the same review gate; a pending change re-anchors when you edit the lines above it.
- **Smarter Save-All guard.** Aefos refuses a Save-All while a `.dfm` event still has
  no handler (no more "handler does not exist — remove the reference?" popup); the
  guard also covers Save-Active-File.
- **`AddComponent` requires a Parent** — components land where you intend, first time.

### Fixed
- Audit-remediation robustness pass: UTF-8 no longer truncated mid-character on large
  frames; the whole edit buffer is read (256 KB cap removed);
  `_RefreshModuleFromDisk` no longer clobbers an unsaved sibling buffer; the pipe
  send timeout scales to the frame size; consent prompts are interpreter-aware and
  tool descriptions are honest about what each tool does.

## [0.27.0-beta] - 2026-06-29

### Fixed
- **IDE version reported correctly.** `GetIDEVersion` no longer hard-codes "13.0";
  it reports the actual running IDE (Delphi 12 / BDS 23.0 → 12.0; Delphi 13 /
  BDS 37.0 → 13.0).
- **Terminal find-bar teardown** — fixed a use-after-free (the `pnlFind` window-proc
  subclass was never restored before the panel was freed).

### Changed
- The MCP workspace facade (an 8,200-line god-object) was decomposed into **24
  focused SOLID services** — a pure delegation shell (−86%), every step validated
  and build-clean on D12 + D13.
- New **`WithLiveSource`** harness seam: all six code-write tools flip the IDE to
  Code and edit the live buffer through one battle-tested transaction.
- The terminal dock form (4,400 lines) was decomposed into **5 focused helpers** (−26%).
- Debug breadcrumbs no longer ship in release builds; dead code removed.

## [0.26.0-beta] - 2026-06-24

### Added
- **Manage your Python tools from the IDE (Pro).** A new **Aefos PyTools** item in
  the IDE **View** menu opens a manager to **create, edit and delete** the Python
  tools the agent can use (in both Chat and Terminal) — no more hand-editing files.
  Each tool stays a folder under `%APPDATA%\Aefos\pytools` (`tool.json` + `main.py`);
  the manager writes them for you. New tools load on the next MCP session.

## [0.25.1-beta] - 2026-06-24

### Changed
- **Issue reporting is now opt-in.** A new **Issue reporting** toggle in
  **Tools → Options → Aefos → AI Flow** controls whether the agent's bug/suggestion
  dialog (`ProposeAefosIssue`) can open. **Off by default** — turn it on to send
  feedback; otherwise the agent can never pop the dialog.

## [0.25.0-beta] - 2026-06-24

### Added
- **Built-in project templates.** The agent (and the chat **New Project** picker)
  scaffolds a ready-to-build project from a template: **Console, VCL, FMX, Library,
  Package, DUnitX**. Each renders the name you choose, ships a clean `.dproj`, and
  gets a fresh project GUID so two projects from the same template never collide.
  Installed to `%APPDATA%\Aefos\templates` — drop your own folder there to add one.
- **DUnitX projects come ready to run.** A new DUnitX test project includes the
  canonical runner (console + NUnit-XML loggers, RTTI discovery) **and** a sample
  `[TestFixture]`, so it builds and runs a test out of the box.
- **Report an Aefos issue from the agent.** When it hits a genuine defect the agent
  can *propose* a bug/suggestion: an editable window opens (your text pre-filled,
  IDE/Aefos/OS versions attached) and **Send** opens a pre-filled GitHub issue for
  you to review and submit. The agent never files anything itself.

## [0.24.1-beta] - 2026-06-24

### Added
- **Auto-approve tool permissions.** A new "Tool permissions" mode in
  **Tools → Options → Aefos → AI Flow**: *Ask every time* (default), *Auto-approve
  edits, ask before destructive*, or *Auto-approve everything*. Works for both Chat
  and Terminal; auto-approvals are still recorded in the audit log.

### Changed
- **Cleaner AI Flow options page** — reorganized into clear sections (Tool
  permissions, Agent edits, IDE behavior, Diagnostics).

## [0.23.0-beta] - 2026-06-22

### Fixed
- **Black Chat panel, attacked at the root.** The Microsoft WebView2 loader
  (`WebView2Loader.dll`) is now **shipped next to the plugin** and loaded by full path,
  so it's found even when it isn't beside the IDE executable (a cause of the black panel
  on some Windows 10 machines).

### Changed
- **The installer now checks the WebView2 Runtime up front.** If it's missing, setup
  **stops with a clear message and the download link** instead of installing into a panel
  that can't render — and it tells you explicitly when the machine is **offline** (so you
  know it couldn't download or verify it). Install the Runtime, then re-run setup.

## [0.22.0-beta] - 2026-06-22

### Added
- **WebView2 diagnostic trace toggle** in **Tools → Options → Aefos → AI Flow**. If the
  Chat panel ever shows a blank/black screen, turn this on to capture a diagnostic log
  (`%TEMP%\aefos_comp.log`) to send with a bug report — no need to touch environment
  variables. Leave it off for normal use.

## [0.21.0-beta] - 2026-06-21

### Added
- **The Chat welcome shortcuts now do real work.** Explain, Refactor, Test, Document,
  Find and Optimize each run a focused, built-in command — **Refactor / Test / Document /
  Optimize apply their changes through the editor** so they show up in the change-review
  for you to accept or reject; Explain and Find answer read-only. They're also available
  by typing `/` in the message box.
- **Polished slash-command picker.** Typing `/` shows a tidy panel — header, scrollable
  list and a footer with the keyboard hints (↑↓ navigate · Enter run · Esc close).

### Changed
- **"Thinking…" indicator** now shows an animated robot while the assistant works, with
  cleaner spacing.
- Clicking a welcome shortcut now fills the message box directly (it previously popped an
  empty bar).

## [0.20.0-beta] - 2026-06-21

### Added
- **See what an AI edit changes before you accept it.** When the assistant edits
  your code, the change now shows inline as a **before/after diff** — the original
  lines struck out in red, stacked above the new lines in green — so you can tell at
  a glance what was replaced (works for wide and multi-line edits).
- **Per-change Approve / Reject / Annotate, right in the gutter.** Each pending change
  gets ✓ (keep), ✗ (undo) and ✎ (leave a note) controls, plus an **Approve All / Reject
  All** pill. Multiple changes accumulate without blocking the assistant.
- **Your notes reach the assistant.** A note you attach to a change is delivered back
  to the AI, tagged as approved or rejected, so it learns your feedback on each edit.
- **Available in both Chat and Terminal.** The change-review works the same in the AI
  Chat and the AI Terminal.

### Changed
- **Saving accepts pending changes.** Saving the file (or running) keeps the new text
  and clears the review markers — it never writes a half-reviewed, duplicated file.

## [0.19.1-beta] - 2026-06-20

### Fixed
- **No more crash on a click in the Chat right after it opens.** A mouse event
  arriving while the WebView host was still initialising could raise an error inside
  the IDE; mouse input is now ignored until the host is ready (and never fatal).

## [0.19.0-beta] - 2026-06-20

### Fixed
- **Chat no longer shows a black panel on machines where it failed to render.** GPU
  compositing is now **off by default** (it was the cause of the black screen on some
  GPUs/drivers/VMs — the Chat is text, so there's no visible cost), and if the WebView2
  host still can't start, the Chat **falls back to plain text with a clear "install
  WebView2" notice** instead of a black panel.
- **Docked Chat/Terminal reliably comes back.** If the pane disappears after a
  desktop/layout switch, clicking its menu entry now brings it forward again (it used
  to stay hidden until you switched profiles or restarted the IDE).
- **About dialog no longer clips its last line** (Chat and Terminal) — it sizes to
  its content.
- **Version is consistent across Chat and Terminal** (the splash/About showed
  mismatched versions before).

### Changed
- **Chat/executor settings are now editable without an open project** (on the
  Welcome page) — they are machine-global, so you can pick your AI CLI, path, model
  and log in before opening any project.
- **Smoother Chat first-open**: a dark "Loading…" placeholder replaces the brief
  black flash while the WebView2 engine warms up; the panel background paints dark
  from the first frame.
- **More tools show the reviewable diff**: inserting a method now routes through the
  same inline red/green diff (accept/reject, with an optional reason) as editing.
- **Installer only asks you to close RAD Studio when it's actually running** (no more
  unconditional prompt).

### Notes
- Advanced: set `AEFOS_WEBVIEW_ENABLE_GPU=1` to opt back into GPU compositing if your
  machine has a good GPU.

## [0.18.0-beta] - 2026-06-20

### Added
- **Reject with a reason.** When you reject an agent's inline edit, a themed
  dialog (matching the IDE's dark/light theme) asks for an optional note — and
  that note is sent back to the agent, so it learns *why* the change was refused
  instead of just *that* it was.
- **Reveal on code insertion.** Tools that write code (`AddEventHandler`,
  `InsertMethod`, insert-at-cursor) now flip the IDE to Code view and scroll to
  the freshly written method, so what the agent wrote is on-screen — not buried
  below the form's component declarations.

### Changed
- **Inline diff scrolls to the change.** When a diff appears it now jumps to the
  first changed line, so the red/green block and its Accept/Reject buttons are
  always visible (no more hunting for them).
- **Cleaner generated code.** Event handlers added by the agent are now separated
  by a single blank line (the IDE convention), not two.

### Fixed
- **Editor crash on diff preview.** Fixed an access violation (use-after-free in
  the editor's diff painting) that could crash the IDE while previewing an inline
  edit.

## [0.17.0-beta] - 2026-06-19

### Added
- **Composition-hosted WebView2** (`TAefosWebView`) for the docked Chat — renders
  smoothly while docked, fixing the blank/flicker on focus changes.
- **Provider drivers** for four AI CLIs: Claude Code, Codex, GitHub Copilot CLI, and
  Gemini, each with its own MCP wiring and remembered model.
- **Design ↔ Code (intent → view)** harness: design-mutation tools end in the Form
  Designer; code-mutation tools end in the editor.
- **Atomic `AddEventHandler`** — creates the handler in the correct section and wires
  the `.dfm` event in one step.
- Node-locked single-seat **licensing** (Community / Pro / Enterprise) with offline
  grace and a built-in trial.

### Changed
- **Inline diff** routing broadened (edit unit, replace-in-editor, full-buffer
  rewrite) with accept/reject (Tab/Esc).
- License terms moved to a proprietary **EULA** with a free Community edition
  (including internal business use).

### Security / supply chain
- Published a machine-readable **SBOM** (CycloneDX 1.5) and a **security disclosure
  policy** (coordinated vulnerability disclosure).

[Unreleased]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.30.0...HEAD
[0.30.0-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.29.0...v0.30.0
[0.19.1-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.19.0...v0.19.1
[0.19.0-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.18.0...v0.19.0
[0.18.0-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.17.0...v0.18.0
[0.17.0-beta]: https://github.com/ModernDelphiWorks/Aefos/releases/tag/v0.17.0
