# ADR-0001 — Addon distribution model + templates as a carry-along folder

Status: **Accepted** (2026-07-13). Supersedes the "pinned version only" parts of
`aefos-addons-contract.md` §6/§7 (to be reconciled when the code lands).

Context: worked out live with the maintainer. Two questions drove it — "should an
MCP (and everything else) carry a release series?" and "how do project scaffolds
fit the addon model?". The answers below are the locked decisions.

## Decision 1 — Distribution is EVERGREEN, not user-pinned

The catalog holds **one current version of everything** (command, tool, mcp). The
registry is a single pointer per slug; `aefos install <slug>` always brings the
current build. There is **no user-facing version selector** and **no Boss/npm-style
`aefos install <slug> <version>`** in v1.

Why: every artifact in the catalog is a **capability / knowledge** artifact, not a
compile-time dependency whose API a user's code is built against. That is exactly
the case where npm/Boss pinning does NOT apply and the VS Code / browser-extension
model (auto-latest) does. Pinning would be ceremony the user pays for nothing.

Consequences:
- **Install == update == "bring the current, whatever it is."** For an evergreen
  slug they are the same act.
- **No release proliferation.** A publish overwrites the one artifact and re-stamps
  the registry entry (a rolling release / stable URL per slug). GitHub Releases are
  dumb byte storage, never browsed; the registry is the index.
- **Rollback is fix-forward** (operator-level via git/asset history, not a
  user-selectable version). Accepted for an official first-party catalog.
- The optional Boss-style `install <slug> <version>` stays a **future, additive**
  escape hatch — only if a real need appears. Not built now.

## Decision 2 — Versioning is kept, but the stamp is AUTOMATIC (single-sourced)

Evergreen UX does **not** mean "no version." A professional product must always be
able to **name the build it shipped** (support, changelog, `requires_aefos` compat).
So each build carries a version — but an **auto-generated stamp** (e.g.
`date + git short-sha`), **single-sourced**: generated once at the addon's build and
injected into its exe/bundle/registry entry by that addon's pack script. Nobody
hand-bumps a semver in several files.

- The **`sha256` is the identity** for "did the current differ from what I have?":
  auto-update compares the installed sha (ledger) to the registry sha; equal → up to
  date, differ → refresh. Version numbers are informational, never a selector.
- `version` becomes **optional** in the registry parse (sha stays required).

## Decision 3 — `aefos.exe` is a generic engine (zero addon coupling)

The CLI knows the **addon model** — the type taxonomy and where each type's files
land — but **never a specific addon**. Its only wisdom is: *given a slug, fetch the
current from the registry, verify the sha, lay files by type; on update, compare and
refresh.* No `if desktop`, no baked-in versions, never recompiled when an addon
changes.

- **Taxonomy = 3 types: `command` / `tool` / `mcp`.** (`skill`/OKF is content that
  accompanies a `command`, not a catalog type.)
- The engine gains, generically: `version` optional, `update` sha-aware, `update`
  with no slug = all installed, `--check` = dry-run listing what changed.

## Decision 4 — `templates/` is a carry-along FOLDER, never a type

A template scaffold **alone is inert** — something must know *when* to render it and
with what vars. That something is always a `command` (or a `skill`/OKF). So a
template is inherently a **companion** to a command/skill, never a standalone unit.
Therefore:

- **`template` is NOT an addon type.** There is **no `aefos install <template>`** —
  you never install a template on its own. It rides inside a `command`/`skill` addon.
- The web catalog surfaces **only the 3 types**; templates are not browsable as a
  category (at most a *property* on a command's detail page: "includes templates: …").
- `templates/` is an **optional folder** an addon may carry (like `okf/`). If OKF is
  a specialist's *semantic* knowledge, templates are its *structural* knowledge.
- **The reference lives in whatever the addon has** — the `COMMAND.md` (simple case)
  or the OKF (specialist case) defines *where* each template is and *when/how* to use
  it. The minimal case is a **plain command with only `templates/`**, no skill.
- Templates install **scoped to the slug** (`~/.aefos/templates/<slug>/…` or
  co-located under the command's dir — settled at build time); the template engine
  (already data-driven: "add a template = drop a file") resolves the `<root>`
  per-slug.

See `aefos-addons-contract.md` §3.1 for the bundle-layout wording.

## Two protections that separate professional from amateur

- **Re-provision on install** — laying a new MCP exe does not swap the running
  process; install must trigger the plugin's re-provision (and handle a locked/running
  exe), else "installed but nothing changed."
- **Fork guard** — install/update clean-replaces; if the on-disk copy was edited
  (on-disk sha ≠ ledger sha), warn before overwriting the user's customization.

## Compatibility under auto-update (resolves the one real tension)

If the current build needs a newer Aefos than the user has, auto-update does **not**
update and does **not** downgrade — it **holds the installed version and notifies**
("update available, needs Aefos ≥ X"). No version history to serve "latest
compatible" is required; never break, never silently downgrade.

## Build sequence (dependency-ordered)

- **PR A — generic engine (`aefos.exe`), local + testable:** `version` optional in
  the registry parse; `update` sha-aware; `update` no-slug = all; `--check`. Zero
  addon coupling. Foundation of everything; touches nothing public.
- **PR B — `templates/` support:** lay a bundle's `templates/` per-slug on install;
  optional `templates` presence in `addon.json`; template engine resolves `<root>`
  per-slug; the `aefos-addon-author` contract gains the `templates/` folder.
- **Nidus pilot** — derive the canonical Nidus **module** pattern from the real
  framework (via `delphi-nidus-specialist`), build `templates/module/` + a
  `/nidus-module` command that renders it. Live proof of the whole model.
- **PR C — plugin auto-update + re-provision + fork guard.** The "auto" that makes
  versioning invisible to the user.
