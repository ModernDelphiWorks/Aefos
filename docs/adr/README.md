# Architecture Decision Records (ADRs)

Aefos records architectural decisions as **ADRs**, referenced throughout the
code and docs by number (e.g. *ADR-270*, *ADR-110*). They answer the "why?" behind a
choice so it isn't relitigated later.

## Where ADRs live

The per-component ADR logs are **development history and are not part of this
repository**. What lives here are the decisions that shape the code you can read:
`adr-0001-addon-distribution-and-templates.md` in this folder, plus the
load-bearing ones summarised below.

> **Numbering note.** ADR numbering comes from the per-component logs (they were independent before the merge, so numbers can overlap
> across components — an *ADR-2xx* in Chat is not the same decision as an *ADR-2xx* in
> Terminal). When citing one, qualify it with the component if ambiguous, e.g.
> "*ADR-270 (Chat)*".

## Decisions referenced from these docs

A few load-bearing ones surfaced in the top-level docs:

| ADR | Component | Decision |
|-----|-----------|----------|
| ADR-270 | Chat | Distribute **Release** builds only — Debug links test units into the BPL. |
| ADR-271 | Chat | Install order: runtime core reachable **before** the design-time plugin BPL. |
| ADR-272 | Chat | **Build-from-source** distribution. *(Superseded for end users: an Inno Setup installer now ships the built BPLs — see [`installer/`](../../installer/).)* |
| ADR-108/109/110 | Chat | MCP relocated to its own package; facade renamed `IMCPWorkspaceFacade`; **zero `uses ToolsAPI`** boundary enforced by test. |

(This is a pointer table, not the authoritative list — read the component `adr.md`
logs for the full record and exact wording.)

## When to write an ADR

Write one when a decision is architectural and someone could later ask "why is it
this way?": a locked shape (Shape A + MCP), a package boundary, a build/install
constraint, dropping a module family, a brand decision. Mechanical changes
(refactors, bug fixes, renames) don't need an ADR.

## Monorepo-level ADRs

Cross-cutting decisions taken after consolidation live here with a unified
`ADR-XXXX` numbering, separate from the per-component logs:

| ADR | Decision |
|-----|----------|
| [ADR-0001](ADR-0001-sqlite-persistence.md) | Local persistence (sessions + audit) moves to SQLite via FireDAC, phased; behind an `ISessionStore` provider seam. |

Per-component decisions stay in their `.project` logs; only ecosystem-wide ones are
promoted here.
