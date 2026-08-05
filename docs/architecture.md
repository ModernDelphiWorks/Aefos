# Architecture

> Scope: the **consolidated monorepo** (Chat + Terminal + in-process MCP server +
> provider drivers + Design/Code harness + composition WebView2 + licensing +
> shared core).

## Mental model

> The plugin is a **front-end** for an external AI CLI, specialized for Delphi.

Aefos has three responsibilities and nothing more:

1. **Capture intent** — the developer invokes `/agent` (or a menu/terminal action)
   inside the IDE.
2. **Build context** — walk the active Delphi project via the Open Tools API (OTA)
   and assemble a Delphi-aware prompt.
3. **Delegate execution** — spawn the configured external CLI as a subprocess and
   stream its output back into the IDE.

Everything else — model choice, prompt iteration, agentic tool use, sandboxing —
lives **inside the external CLI**, not the plugin.

### Hard invariants

- **No LLM call from the plugin.** Aefos never talks to a model API directly.
  It spawns a process and reads its output.
- **No credentials in the plugin.** The executor uses whatever auth it already has
  on disk. Aefos manages none.
- **No conversation state between turns in the plugin.** History is owned by the
  executor. (Persisting *sessions + audit* locally — SQLite — is a separate concern
  and does not change this invariant.)

## Shape A + MCP (locked decision)

"Shape A" = the plugin spawns the CLI **and** hosts an MCP server in-process. The
agent doesn't just talk — through MCP it **acts** on the live IDE project.

```
   ┌───────────────────────── RAD Studio (Delphi 13) ────────────────────────┐
   │                                                                         │
   │   Aefos.OTA.Chat  ──┐                                                    │
   │   Aefos.OTA.Terminal ┤  spawn          ┌──────────────────────────┐     │
   │                      ├─────────────────▶│  External AI CLI         │     │
   │                      │  (stdin/stdout)  │  Claude / Codex /        │     │
   │                      │                  │  Copilot / Gemini        │     │
   │   in-process MCP   ◀─┘   MCP            └────────────┬─────────────┘     │
   │     server         ◀──── (named pipe / HTTP) ────────┘                   │
   │        │                                                                 │
   │        ▼                                                                 │
   │   OTA tools (read / edit / build / run / git / project tree /            │
   │              refactor / live designer / …)                               │
   │        │                                                                 │
   │        ▼  acts directly on the open project                             │
   │   IOTAModuleServices · IOTAEditView · IOTAProject · IOTAFormEditor · …   │
   └─────────────────────────────────────────────────────────────────────────┘
```

1. The plugin **spawns** the user's CLI as a child process and streams its I/O into
   the IDE panel.
2. The plugin **hosts an MCP server in-process** — named pipe for the Terminal,
   HTTP for the Chat.
3. The CLI connects back and invokes **OTA tools** that operate on the live project.

## Packages and the decoupling seam

The product builds as **eleven packages** (`packages/Delphi/AefosGroup.groupproj`),
in dependency / `CallTarget` order:

| # | Package | Source | `uses ToolsAPI`? | Role |
|---|---------|--------|:---:|------|
| 1 | `Aefos.WebView` | `source/webview` | no | Composition-hosted WebView2 control (`TAefosWebView`), DirectComposition + D3D11. Runtime. |
| 2 | `dclAefosWebView` | `source/webview` (Reg) | no | Design-time companion — registers `TAefosWebView` on the **Aefos** palette. `{$DESIGNONLY}`. |
| 3 | `Aefos.License` | `source/license` | no | Node-locked single-seat licensing (Client / Gate / Token / UI), Supabase backend. |
| 4 | `Aefos.Harness` | `source/harness` | **yes** (designide) | The Design/Code-duality seam: `WithLiveForm`, `EnsureDesignView`, `EnsureCodeView` (intent → view). Passive — registers nothing. |
| 5 | `Aefos.Providers` | `source/providers` | **no** (rtl-only leaf) | One driver per AI CLI (Claude / Codex / Copilot / Gemini) behind `IExecutorProfile`. |
| 6 | `Aefos.Tools` | `source/mcp/Tools` | no | Pure Delphi file-editing tools (line/column, disk, templates). No IDE coupling. |
| 7 | `Aefos.MCP.Core` | `source/mcp/Core` | **no** | MCP engine: server, named-pipe + HTTP transport, audit log, consent registry, edit tracking, re-anchor. |
| 8 | `Aefos.MCP.Tools.OTA` | `source/mcp/OTA` | yes | The OTA workspace facade — exposes IDE capabilities as MCP tools. Requires `Aefos.Harness`. |
| 9 | `Aefos.Data` | `source/data` | no | Shared SQLite/FireDAC persistence foundation (static SQLite, WAL, meta table). |
| 10 | `Aefos.OTA.Chat` | `source/chat` | yes | Chat plugin BPL + in-process MCP host. Requires `Aefos.Providers`. |
| 11 | `Aefos.OTA.Terminal` | `source/terminal` | yes | Terminal plugin BPL. |

**Why the split?** `MCP.Core` is a standalone module with **zero `uses ToolsAPI`**
(historically gated by a boundary test). That boundary is the seam that lets *other*
BPLs reuse the engine: the Terminal consumes the same `MCP.Core` as the Chat. The
OTA-coupled code lives only in `MCP.Tools.OTA`, `Aefos.Harness`, and the two plugin
BPLs.

Only **Chat** and **Terminal** register UI in the IDE; the rest are passive
runtime/leaf dependencies (`dclAefosWebView` registers only the design-time
component). Build order follows the dependency chain — the group's `CallTarget`
order above is authoritative.

## The workspace facade

The boundary between the RTL-only core and the IDE is the **workspace facade**
interface (`IMCPWorkspaceFacade`, in `MCP.Core`). `MCP.Core` knows the interface;
the concrete OTA implementation lives in `MCP.Tools.OTA` and is injected at runtime
by whichever plugin BPL is hosting the server.

This is why the same engine serves both plugins: the Chat and the Terminal each
provide their own facade wiring, but the protocol/transport/audit machinery is
shared and IDE-agnostic.

## Provider drivers (multi-CLI)

Every per-executor difference (binary name, model-arg style, MCP config JSON,
dispatch flags, command-replica layout, CLI-not-found hint) is owned by
`IExecutorProfile` (`Aefos.Provider.Types`). Consumers hold **no executor-named
literal** — they consume a profile resolved by `Aefos.Provider.Registry`.

| Executor (`TExecutorKind`) | Driver | MCP wiring |
|---------------------------|--------|-----------|
| `ekClaude` | `Aefos.Provider.Claude` | `--mcp-config <global> --strict-mcp-config`; uses session (`--session-id`/`--resume`) |
| `ekCodex` | `Aefos.Provider.Codex` | per-invocation `-c mcp_servers.aefos…` TOML overrides |
| `ekCopilot` | `Aefos.Provider.Copilot` | `--additional-mcp-config @<global> --allow-all-tools` |
| `ekGemini` | `Aefos.Provider.Gemini` | merges into `~/.gemini/settings.json` + `--allowed-mcp-server-names aefos` |

The dispatcher assembles a `TProviderDispatchContext` (global MCP config path,
bridge path, session, extra MCP server names) and delegates flag-building to the
driver via `BuildDispatchArgs`. See [providers.md](providers.md).

## Intent → View: the Design/Code harness

`Aefos.Harness.View` makes the IDE's Design/Code duality **executable**. The
terminal agent is a raw CLI with no harness, so the **MCP tool's own behaviour is
the contract** — correctness lives in the tool, not in agent reasoning:

- **Design-mutation tools** (Add/Remove/Move/SetProperty, `AddEventHandler`) run
  inside `WithLiveForm`, which marshals to the main thread, resolves the live
  `IOTAFormEditor`, `EnsureDesignView` (`Show`), runs the work, then `MarkModified`
  — and **ends in Design**.
- **Code-mutation tools** call `EnsureCodeView` (source editor `Show`) and **end in
  Code**.
- **Design reads** are strict and view-agnostic; **module-first fallback** targets
  the form the user has open (`CurrentModule`) when a mutation's unit name doesn't
  resolve — so components sprout on screen instead of failing into a phantom unit.

See [intent-view.md](intent-view.md).

## Skill flow

```
User                    Plugin                          External CLI
 |  /agent args            |                                |
 |------------------------>|                                |
 |                         | resolve skill from .aefos/skills/
 |                         | build Delphi project context (OTA walk)
 |                         | render prompt                  |
 |                         | spawn subprocess + stream ----->| runs (own model, own tools,
 |                         |                                 |  may call back over MCP)
 |                         |<-------- stdout/stderr -------- |
 |  panel renders output   |                                |
 |<------------------------|                                |
```

### Canonical skills folder + replicator

Skills are authored once in a canonical folder and replicated to the format the
active CLI expects:

```
.aefos/
  skills/
    <skill-name>/
      SKILL.md     ← canonical (always edit here)
```

- Executor = Claude Code → replicated to `.claude/skills/<skill-name>/SKILL.md`
- Executor = Codex / Copilot / Gemini → replicated to that executor's equivalent
  path/format (owned by the driver's `CommandReplicaRelPath` / `ConvertCommand`).

Canonical is the source of truth; replicas are derived. The plugin never reads from
a replica.

## MCP configuration & self-provisioning

A **single global MCP config** — `%APPDATA%\Aefos\aefos-mcp.json` — carries the
built-in `aefos` server plus the user's extra servers. Every CLI is pointed at this
one file; the chat no longer depends on a per-project `.mcp.json`. A bridge
(`%APPDATA%\Aefos\mcp-bridge.ps1`, stdio ↔ named-pipe relay) connects pipe-based
CLIs. The persistent pipe host starts at BPL **load** (`aefos-mcp-plugin`), so it is
up for any CLI regardless of which executor is selected.

## Safety model for mutations

Tools that change the project go through two gates, both in `MCP.Core`:

- **Consent** — destructive/mutating tools (e.g. `DeleteUnit`, `OverwriteFile`) are
  gated by a consent registry before they run.
- **Audit** — mutations are appended to a JSONL audit log
  (`mcp-audit-YYYY-MM-DD.jsonl`) for traceability.
- **Read-before-edit** — `EditUnit` is an *anchored* replacement: it requires a
  `base_hash` obtained from a prior `ReadUnit`, so a stale edit is rejected rather
  than silently clobbering newer content.

On top of consent, the Chat plugin shows an **inline red/green diff** in the editor
with clickable ✓ / ✗ (Tab/Esc) before applying an edit. See [mcp-tools.md](mcp-tools.md).

## Async / UX threading

Chat is **synchronous in the UX** (the developer waits on a "processing…" state) but
I/O with the harness runs on a **worker thread**; results return to the IDE via
`TThread.Queue`. Blocking the main thread would freeze the IDE, so OTA work is always
marshalled back to the main thread.

## Rendering

The Chat output panel renders via a **composition-hosted WebView2**
(`TAefosWebView`, `Aefos.WebView`) — a custom control built on
`ICoreWebView2CompositionController` + DirectComposition + D3D11, with no
third-party dependency. Composition hosting (rather than the windowed
`TEdgeBrowser`) keeps the docked panel painted while the IDE is deactivated (e.g.
while the CLI terminal holds the foreground) and survives dock/undock via a stable
anchor window. Without the WebView2 runtime the panel falls back to a plain-text
`TRichEdit`. See [components/webview.md](components/webview.md).

## Persistence

Local persistence uses **SQLite** (FireDAC, statically linked — no `sqlite3.dll`)
for the two stores that outgrew files: **chat sessions** and the **audit log**.
Config, templates and skills stay as files (human-editable, git-friendly). One
database, `%AppData%\Roaming\Aefos\aefos.db`, WAL journaling, a single connection
serialised by a critical section. See [ADR-0001](adr/ADR-0001-sqlite-persistence.md).

The FireDAC/SQLite **foundation** (`ISQLiteDatabase` — connection, WAL, the `meta`
table) lives in the shared **`Aefos.Data`** package (`source/data`), reachable by
both hosts. It cannot live in `MCP.Core` (locked to `requires rtl`).

Persistence sits behind an **interface + provider** seam (mirroring
`SetGlobalConsentPresenter`): `ISessionStore` + the provider accessor live in the
storage-agnostic `…Chat.Core.SessionStore` unit; the SQLite implementation
(`…SessionStore.SQLite`) self-registers and is swappable for a test double.
Migration is **non-destructive** — legacy `sessions\*.json` are imported once and
left in place.

## Licensing

`Aefos.License` adds node-locked, single-seat licensing (one seat per copy of
Delphi) wired into both Chat and Terminal via a **License…** menu item. The BPL
splits into Client (HTTP to the Supabase backend), Gate (the local enforcement
point), Token (RS256 token handling — phase 2), and UI. The server side is a Supabase schema + Edge Function + registration flow (lead
capture, auto-activate, e-mail) and is **not part of this repository** — it is a
hosted service. See [licensing.md](licensing.md) for the client-side contract.

## Known debt / in-flux areas

- The **audit log** is still JSONL (`mcp-audit-YYYY-MM-DD.jsonl`); its SQLite
  migration is Phase 2 of [ADR-0001](adr/ADR-0001-sqlite-persistence.md).
- **License token (RS256)** is the open phase-2 item; activation/gating is in place.
