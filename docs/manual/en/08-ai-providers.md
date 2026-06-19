# 8. AI providers

Aefos is **"bring your own CLI"**: it ships no model and manages no credentials. You
install and log in to the AI CLI of your choice, and Aefos connects it to your
project. Four providers are supported.

## Overview

| Provider | CLI | What you need |
|----------|-----|---------------|
| **Claude Code** | Anthropic | Install the CLI and log in to your Anthropic account |
| **Codex** | OpenAI | Install the CLI and run `codex login` to use the model |
| **GitHub Copilot CLI** | GitHub | Install the CLI and log in to GitHub Copilot |
| **Gemini** | Google | Install/have the Gemini CLI available and log in |

> **Claude Code** is the reference provider (the MVP target). The others are fully
> supported.

## How to choose the provider

In **Tools → Options → Aefos**, select the **provider/executor** and the **model**.
The model is remembered **per provider** (no leaking from one to another).

## Connecting MCP to each CLI

Aefos points **all** CLIs to a **single** global MCP configuration
(`%APPDATA%\Aefos\aefos-mcp.json`). Each CLI is wired in its own way:

- **Claude Code** — receives the global config strictly (ignores any project
  `.mcp.json`).
- **Codex** — the `aefos` server config is injected per invocation (no config files
  touched). Remember Codex needs `codex login` to **run the model** (the MCP connects
  regardless).
- **GitHub Copilot CLI** — the global config is injected and tools are allowed for
  non-interactive mode.
- **Gemini** — the `aefos` server is merged into Gemini's settings
  (`~/.gemini/settings.json`) and enabled by name.

> You don't need to do this wiring by hand — Aefos handles it. To **verify** that
> everything is fine, use **Test MCP** in **Options → Aefos** (see
> [Configuration](09-configuration.md)).

## What if the CLI is not installed?

- The **installer** detects `claude` on your machine and, if missing, points to the
  official source.
- At runtime, if you pick a provider whose CLI is not installed/logged in, the
  dispatch has nowhere to go — install/log in to the CLI and try again.

➡️ Next: [Configuration](09-configuration.md)
