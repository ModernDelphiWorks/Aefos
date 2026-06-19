<!--
  MAINTAINER: set these before publishing
  - Replace https://moderndelphiworks.github.io/Aefos/ with the GitHub Pages / custom-domain URL (e.g. https://aefos.pubpascal.dev)
  - Replace <REPO_URL> with https://github.com/ModernDelphiWorks/Aefos
  - Releases link assumes this repo hosts the installer as a Release asset.
  This is the PUBLIC repo (downloads + manual + issues). The source code is private.
-->
<div align="center">

# Aefos AI

**Your favorite AI coding CLI — living *inside* RAD Studio.**

***AEFOS** — **A**gent **E**xecution **F**low **O**rchestration **S**ystem.*

In-IDE AI **Chat** + **Terminal** for RAD Studio Delphi 13, powered by the AI CLI you
already use (Claude Code, Codex, GitHub Copilot CLI, Gemini).

[![Version](https://img.shields.io/badge/version-0.17.0--beta-orange)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6)](#requirements)
[![License](https://img.shields.io/badge/license-EULA%20%E2%80%94%20Community%20free-blue)](LICENSE)
[![CRA-ready](https://img.shields.io/badge/CRA--ready-SBOM%20%2B%20Security%20policy-success)](https://www.pubpascal.dev/packages/aefos)

[⬇️ Download](../../releases) · [📖 User Manual](https://moderndelphiworks.github.io/Aefos/) · [🐛 Report a bug](../../issues/new/choose) · [🔒 Security](SECURITY.md)

**English** · [Português (PT-BR)](README.pt-BR.md)

</div>

> **This is the public home of Aefos AI** — downloads, the user manual, and the issue
> tracker. The product source code is private; this repository hosts the things users
> need.

## What it is

Aefos AI brings the AI command-line tools you already use **into** RAD Studio Delphi
13, with deep awareness of your project. The agent doesn't just talk — it **acts** on
the open project: edits code, builds and runs (with the debugger), drives the Form
Designer, and more.

> **Bring your own CLI.** Aefos ships **no AI model and manages no credentials** — it
> is a thin, Delphi-aware harness on top of the CLI you already run.

## Features

- 💬 **In-IDE Chat** with an **Agent mode** that acts on your project (read/edit code,
  build/run, git, live Form Designer).
- 🖥️ **Docked Terminal** (real VTerm) with a command palette, profiles, and history.
- 🔀 **Multi-provider** — Claude Code, Codex, GitHub Copilot CLI, Gemini.
- ✅ **Inline diff** of every AI change, with accept/reject (Tab/Esc) — nothing is
  applied without your approval.
- 🎨 **Design ↔ Code** flow — add a component and watch the IDE flip to Design; add
  code and watch it flip to Code.

## Screenshots

| 💬 Chat (Agent mode) | 🖥️ Terminal |
|:---:|:---:|
| ![Aefos Chat](assets/chat.png) | ![Aefos Terminal](assets/terminal.png) |

## Documentation

📖 **[User Manual](https://moderndelphiworks.github.io/Aefos/)** (PT-BR / EN) — install, first steps, Chat, Terminal,
providers, configuration, licensing, and troubleshooting.

## Download & install

1. Get the latest installer from **[Releases](../../releases)**
   (`Aefos-Setup-<version>.exe`).
2. Close RAD Studio, run the installer (per-user, no admin).
3. Restart RAD Studio — the **View → Aefos AI (Chat)** and **View → Aefos AI
   (Terminal)** menus appear.

Full steps in the [manual](https://moderndelphiworks.github.io/Aefos/).

## Requirements

| Item | Requirement |
|------|-------------|
| IDE | RAD Studio **Delphi 13** (BDS 37.0) |
| OS | **Windows** |
| AI CLI | At least one: Claude Code / Codex / GitHub Copilot CLI / Gemini (bring your own) |
| Rich Markdown (optional) | [WebView2 Runtime](https://aka.ms/webview2) |

## Editions

| Edition | Price | For whom |
|---------|-------|----------|
| **Community** | **Free** | Personal, educational **and internal business** use — no per-seat fee, no penalty |
| **Pro** | Subscription | Terminal, MCP auto-setup, wizards, history, advanced context |
| **Enterprise** | Contract | Broad corporate use, support, governance |

## Reporting bugs & requests

- 🐛 **[Open an issue](../../issues/new/choose)** — please read the
  [Submission Terms](TERMS-ISSUES.md) first (short, important).
- 🔒 **Security vulnerability?** Do **not** open a public issue — follow
  [SECURITY.md](SECURITY.md).
- ❓ Questions / help: see [SUPPORT.md](SUPPORT.md).

## Supply-chain transparency (CRA-ready)

- 📦 **SBOM** — a machine-readable Software Bill of Materials (CycloneDX 1.5) is
  published under [`sbom/`](sbom/).
- 🔒 **Security disclosure policy** — [SECURITY.md](SECURITY.md).
- 📝 **Actively maintained** — see the [CHANGELOG](CHANGELOG.md).
- 📜 **Third-party licenses** — [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt).

## Privacy & license

- 📄 [EULA](LICENSE) — proprietary; Community edition free (incl. internal business use).
- 🔐 [Privacy Policy](PRIVACY.md) ([PT-BR](PRIVACY.pt-BR.md)) — LGPD-aligned.

---

<div align="center">
Distributed via <a href="https://www.pubpascal.dev">PubPascal</a> · © 2026 Aefos AI (TecSis Info)
</div>
