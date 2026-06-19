# 1. Overview

## What Aefos AI is

**Aefos AI** is a plugin suite for **RAD Studio Delphi 13** that brings the AI
command-line tools you already use — **Claude Code, Codex, GitHub Copilot CLI, and
Gemini** — *into* the IDE, with deep awareness of your project via the Open Tools API
(OTA).

> **The name.** *AEFOS* stands for **A**gent **E**xecution **F**low **O**rchestration
> **S**ystem — which is exactly what it does.

It has two main surfaces:

- **Chat** — an in-IDE AI chat/agent panel. You converse, ask for changes, and the
  agent **acts** on your project (edits code, builds, runs, drives the Form Designer).
- **Terminal** — a real terminal docked in the IDE, with a command palette, profiles,
  and history.

## Who it is for

For the **Delphi developer** who wants to use AI without leaving the IDE and without
the AI being "blind" to the project. Instead of copying and pasting code between the
browser and Delphi, the agent sees and changes the open project directly.

## How it works (in one sentence)

> Aefos **launches the AI CLI you chose** and, at the same time, **exposes your Delphi
> project to that CLI** through an internal MCP server — so the agent doesn't just
> talk, it **acts** on your project.

The differentiator is Delphi awareness: when the agent adds a component, the IDE flips
to **Design** (Form Designer); when it adds code, it flips to **Code** (the editor).
See [What the agent does in your project](06-what-the-agent-does.md).

## What Aefos is **not**

- **Not an AI model.** You bring your own CLI subscription/account (Claude, OpenAI,
  Copilot, Gemini).
- **It does not store your credentials.** The CLI uses the login already on your
  machine.
- **It does not send your code to Aefos.** Your prompts and code go straight to your
  chosen CLI's provider (see [Privacy](12-privacy-and-license.md)).

## Editions

| Edition | Price | For whom |
|---------|-------|----------|
| **Community** | Free | Personal, educational **and internal business** use (no penalty) |
| **Pro** | Subscription | Extra productivity features (Terminal, MCP auto-setup, wizards) |
| **Enterprise** | Contract | Broad corporate use, support and governance |

Details in [Licensing & editions](10-licensing.md).

➡️ Next: [Requirements](02-requirements.md)
