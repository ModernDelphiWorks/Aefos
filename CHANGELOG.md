# Changelog

All notable changes to **Aefos AI** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Dates are in `YYYY-MM-DD`.

## [Unreleased]

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

[Unreleased]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.19.1...HEAD
[0.19.1-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.19.0...v0.19.1
[0.19.0-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.18.0...v0.19.0
[0.18.0-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.17.0...v0.18.0
[0.17.0-beta]: https://github.com/ModernDelphiWorks/Aefos/releases/tag/v0.17.0
