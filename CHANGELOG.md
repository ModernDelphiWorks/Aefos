# Changelog

All notable changes to **Aefos AI** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Dates are in `YYYY-MM-DD`.

## [Unreleased]

- Public repository: downloads, user manual (PT-BR/EN), and issue tracker.
- CRA-readiness artifacts: CycloneDX 1.5 SBOM and security disclosure policy.

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

[Unreleased]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.17.0...HEAD
[0.17.0-beta]: https://github.com/ModernDelphiWorks/Aefos/releases/tag/v0.17.0
