# ADR-0001 — Local persistence moves to SQLite (FireDAC), phased

- **Status:** Accepted — Phase 1 implemented (2026-06-10)
- **Scope:** Monorepo-level (first unified ADR; see [README.md](README.md))
- **Supersedes:** the JSON/text-file persistence for chat sessions

## Context

Two local stores had grown past what flat files comfortably serve:

- **Chat sessions** — one JSON file per session under
  `%AppData%\Roaming\Aefos\sessions\<id>.json`. Listing the panel reads and
  parses *every* file on each refresh.
- **Audit log** — append-only JSONL, one file per day
  (`mcp-audit-YYYY-MM-DD.jsonl`), scanned **linearly on every `QueryAuditLog`**.
  This is the unbounded-growth store and the real performance pain.

The maintainer's call: "we've grown a lot to keep trusting JSON and text files."
Config, templates and skills stay as files (human-editable, git-friendly); only
**sessions + audit** move to a database.

## Decision

Adopt **SQLite via FireDAC**, statically linked, behind clean seams, migrated in
**two phases**.

### Driver & engine
- **FireDAC** (native to RAD Studio 13, zero external dependency). It does **not**
  violate the MCP.Core boundary test (`Tests.MCPCorePackage` forbids widening
  `requires`, and `Tests.MCPPackageBoundary` forbids `Vcl.*`/`FMX.*` — FireDAC is
  neither).
- **Static SQLite** (`FireDAC.Phys.SQLiteWrapper.Stat`) — the engine links into the
  BPL; **no `sqlite3.dll` is shipped or required**. One fewer native file for the
  installer (`installer/`) to bundle.
- **One database file**, `%AppData%\Roaming\Aefos\aefos.db`, **WAL**
  journaling, a single `TFDConnection` serialised by a critical section (FireDAC
  connections are not safe to share across threads), and a `meta(k,v)` table for
  migration flags.

### Decoupling (good-practice seam)
Persistence sits behind an **interface + provider**, mirroring the existing
`SetGlobalConsentPresenter` / `SetGlobalDiffApprover` pattern:

- `ISessionStore` + `TSessionEntry` + `SessionStore` / `SetSessionStoreProvider`
  live in `Aefos.OTA.Chat.Core.SessionStore` — **no storage dependency**; it
  does not know SQLite exists. A thin back-compat facade keeps existing callers
  unchanged; a null-object stands in until a provider registers.
- The SQLite provider (`...SessionStore.SQLite`) implements `ISessionStore`, uses
  the FireDAC foundation (`Aefos.Data.SQLite`, exposing `ISQLiteDatabase`),
  and self-registers as the default in `initialization`. Tests swap it via the seam.

### Phasing
- **Phase 1 (done): sessions.** Lower risk, single consumer, no MCP-tool contract.
  The foundation lives in the shared **`Aefos.Data`** runtime package
  (`source/data`) because MCP.Core's `requires` is locked to `{rtl}` (ESP C-2) and
  cannot take FireDAC. (The foundation first shipped inside the Chat BPL, then was
  extracted into `Aefos.Data` when that package was created.)
- **Phase 2 (in progress): audit.** The `Aefos.Data` package exists and the
  foundation is extracted into it. Still to do: a SQLite `IMCPAuditLog` writer + an
  indexed-SQL rewrite of `QueryAuditLog`, both in `Aefos.Data`, **injected
  into Core via the composition roots** so Core stays rtl-only.

### Migration
One-time, **non-destructive** import on first use: legacy `sessions\*.json` are
read and `INSERT OR IGNORE`-d into the table (guarded by a `meta` flag); the JSON
files are **left in place** so the change is reversible and no history is lost.

## Consequences

**Positive**
- Indexed, queryable storage; audit (phase 2) goes from O(n) file scan to O(log n).
- Persistence is decoupled and testable (inject a fake `ISessionStore`).
- No DLL to distribute (static link).
- Callers unchanged (facade preserved).

**Negative / trade-offs**
- A new runtime package (`Aefos.Data`) must be built/installed alongside the
  others. The Chat BPL still carries a direct FireDAC dependency (`dbrtl`, `FireDAC`,
  `FireDACCommon`, `FireDACCommonDriver`, `FireDACSqliteDriver`) because its
  `SessionStore.SQLite` uses `TFDQuery` directly; the connection foundation comes via
  `Aefos.Data`.
- Phase 2 changes the `QueryAuditLog` contract: `malformed_skipped` loses meaning
  in a DB (no malformed rows) and becomes a constant `0`. To be documented when
  phase 2 lands.

## Alternatives considered

- **Keep JSON/text.** Rejected — the audit-scan cost and per-file session listing
  are the very pain being addressed.
- **Bind `sqlite3` directly (thin wrapper).** Viable and lean, but more boilerplate
  (prepare/step/finalize) for no gain over FireDAC, which ships with the IDE.
  Rejected for phase 1.
- **Foundation in MCP.Core.** Rejected — would widen Core's locked `{rtl}`
  `requires` (`Tests.MCPCorePackage`). The injection approach in phase 2 keeps Core
  pure.
