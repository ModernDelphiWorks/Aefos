# Changelog

All notable changes to **Aefos AI** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Dates are in `YYYY-MM-DD`.

## [Unreleased]

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

[Unreleased]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.18.0...HEAD
[0.18.0-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.17.0...v0.18.0
[0.17.0-beta]: https://github.com/ModernDelphiWorks/Aefos/releases/tag/v0.17.0
