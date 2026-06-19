# 2. Requirements

Before installing, check the list below. **Required** items are the minimum for Aefos
to work; **optional** ones enable extra features.

## Required

| Item | Requirement | Note |
|------|-------------|------|
| **IDE** | RAD Studio **Delphi 13** (BDS 37.0) | Minimum and only supported version |
| **OS** | **Windows** | The plugin is Windows-only |
| **AI CLI** | At least one of: Claude Code, Codex, GitHub Copilot CLI, or Gemini | "Bring your own" — no CLI is bundled. See [AI providers](08-ai-providers.md) |

> Without an installed and logged-in AI CLI, the Chat opens normally, but sending
> messages "does nothing" — there is nowhere to dispatch the prompt.

## Recommended

| Item | For what | Where to get it |
|------|----------|-----------------|
| **WebView2 Runtime** | Rich rendering (Markdown + syntax highlighting) in the Chat | <https://aka.ms/webview2> |

Without WebView2 the Chat still works, but falls back to **plain text** (no formatted
Markdown).

## Optional

| Item | For what | Where to get it |
|------|----------|-----------------|
| **Python** (`py` / `python`) | Run **PyTools** (Python MCP tools you drop into a folder) | <https://python.org> or `winget install Python.Python.3.12` |
| **PowerShell 7+** (`pwsh`) | Helper scripts (build/installer) | Bundled with Windows (older version); 7+ optional |

## What you do **not** need to install

- **SQLite** — already statically embedded in the plugin; there is no `sqlite3.dll` to
  install.
- **Delphi runtimes** (RTL/VCL/FireDAC) — already part of your RAD Studio.

➡️ Next: [Installation](03-installation.md)
