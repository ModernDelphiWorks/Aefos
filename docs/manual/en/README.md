# User Manual — Aefos AI

Welcome to **Aefos AI** — your favorite AI CLI (Claude Code, Codex, GitHub Copilot
CLI, Gemini) running **inside** RAD Studio Delphi 13, with deep awareness of your
project.

This manual is for the **end user** (Delphi developer): how to install, configure,
and use the Chat and the Terminal day to day. For architecture/implementation
details, see the [project repository](https://github.com/ModernDelphiWorks/Aefos).

> **Covered version:** 0.17.0-beta · **Platform:** Windows · **IDE:** RAD Studio
> Delphi 13 (BDS 37.0).

---

## Table of contents

| # | Section | What you learn |
|---|---------|----------------|
| 1 | [Overview](01-overview.md) | What Aefos AI is, who it is for, and how it works |
| 2 | [Requirements](02-requirements.md) | What you need before installing |
| 3 | [Installation](03-installation.md) | Install the plugin and verify everything works |
| 4 | [Getting started](04-getting-started.md) | Open the Aefos menus (View → Aefos AI), the Chat, pick a provider, first chat |
| 5 | [Using the Chat](05-using-the-chat.md) | Agent vs Chat mode, `/agent` skills, context, inline diff (accept/reject) |
| 6 | [What the agent does in your project](06-what-the-agent-does.md) | MCP tools, live designer, build/run, git, and the Design↔Code flow |
| 7 | [Using the Terminal](07-using-the-terminal.md) | Docked terminal, command palette (Ctrl+P), profiles, history |
| 8 | [AI providers](08-ai-providers.md) | Install and log in to each CLI (Claude/Codex/Copilot/Gemini) |
| 9 | [Configuration](09-configuration.md) | Tools → Options, MCP, WebView2, PyTools |
| 10 | [Licensing & editions](10-licensing.md) | Community (free), Pro, Enterprise and how to activate |
| 11 | [Troubleshooting](11-troubleshooting.md) | FAQ and troubleshooting |
| 12 | [Privacy & license](12-privacy-and-license.md) | Quick links to the EULA, Privacy Policy, and third-party notices |

---

## Where to start

- **First time?** Follow in order: [Requirements](02-requirements.md) →
  [Installation](03-installation.md) → [Getting started](04-getting-started.md).
- **Already installed?** Jump to [Using the Chat](05-using-the-chat.md).
- **Something not working?** [Troubleshooting](11-troubleshooting.md).

> **Aefos is "bring your own CLI".** Aefos ships no AI model and manages no
> credentials — it is a *harness* that connects the CLI you already use to your
> Delphi project. You need at least one AI CLI installed (see
> [AI providers](08-ai-providers.md)).
