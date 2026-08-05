# Aefos — Documentation

Documentation for the **Aefos AI** ecosystem monorepo. These docs describe the
**consolidated state** of the repository (`source/` + `packages/`) at **`1.0.0`**.

> The root [`README.md`](../README.md) is the product-level entry point; these
> docs go a level deeper.

> Docs-as-code: plain Markdown, versioned with the source, rendered natively on
> GitHub. No build step. If we ever publish a public docs site, these same files
> feed a generator (Docusaurus/MkDocs) without rewriting.

## Index

| Doc | What it covers |
|-----|----------------|
| [architecture.md](architecture.md) | The "Shape A + MCP" model, the eleven packages, the decoupled core boundary, provider drivers, intent→view, skill flow, MCP dispatch. |
| [build-install.md](build-install.md) | Prerequisites, the two install paths (the `installer/` setup for end users; build-from-source for devs), and installing the BPLs into Delphi 13. |
| [providers.md](providers.md) | The multi-CLI provider abstraction (`IExecutorProfile`): Claude / Codex / Copilot / Gemini drivers and their dispatch flags. |
| [intent-view.md](intent-view.md) | The Design/Code harness — `WithLiveForm`, `EnsureDesignView`/`EnsureCodeView`, the atomic `AddEventHandler`, the module-first fallback. |
| [mcp-tools.md](mcp-tools.md) | The MCP tool surface: read-before-edit, consent, audit, inline diff; shipped tools vs. the catalog. |
| [ide-actions.md](ide-actions.md) | `ListIDEActions`/`ExecuteIDEAction`: the fire-and-forget recipe, the DFM round-trip, and when to prefer a dedicated tool. |
| [components/chat.md](components/chat.md) | The Chat plugin — panel, skills, CLI dispatch, composition WebView2 rendering. |
| [components/terminal.md](components/terminal.md) | The Terminal plugin — docked VTerm with OTA reach. |
| [components/webview.md](components/webview.md) | The composition-hosted WebView2 control (`TAefosWebView`) and why it replaced `TEdgeBrowser`. |
| [manual/README.md](manual/README.md) | **User Manual** — end-user guide: install, Chat, Terminal, providers, configuration, licensing, troubleshooting. |
| [adr/README.md](adr/README.md) | Where architecture decisions live and how they're indexed. |

## Conventions

- **Language.** Everything is written in English.
- **One source of truth.** A fact lives in exactly one doc. Other docs link to it
  rather than restating it.
- **Honesty over polish.** Known debt and stale areas are documented as such, not
  hidden. If a doc describes a target state rather than the current one, it says so.
- **Decisions are ADRs.** Anything architectural that someone might later ask "why?"
  about becomes an ADR (see [adr/README.md](adr/README.md)).
