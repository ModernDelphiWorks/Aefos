# Aefos Addons — Install Contract (v0)

Shared contract between the **portal/repo team** (registry + addon bundles) and
the **Aefos CLI** (`aefos.exe`, this repo). The CLI downloads an addon bundle,
verifies it, lays it out under the user's `~/.aefos/` tree, registers any MCP
servers, and records it in a ledger so it can be updated/removed. Aefos then
recognises the artifacts automatically.

> **Direction update (2026-07-13, ADR-0001):** distribution is moving to an
> **evergreen** model — one current build per slug, `install`/`update` always bring
> the current (no user-facing version pinning), sha as the change identity, and an
> automatic single-sourced build stamp. The **"pinned version only"** wording in §6/§7
> below predates that and is being reconciled as the code lands. Taxonomy is **3 types
> — command / tool / mcp**; `template` is a carry-along folder (§3.1), never a type,
> and there is **no `aefos install <template>`**. See `adr/adr-0001-addon-distribution-and-templates.md`.

Locked decisions (2026-07-11):
- **Host:** a dedicated `aefos.exe` (sibling of `AefosAgent.exe` in
  `%APPDATA%\Aefos\bin`, on PATH). Subcommands: `install` / `uninstall` /
  `update` / `list`.
- **Transport:** one **versioned `.zip` per addon version**, referenced by the
  registry with a **`sha256`**. The CLI downloads the single archive, verifies
  the hash, then extracts. Atomic, checksummable, easy to pin.
- OKF is a hard requirement: the skill's knowledge bundle follows the
  [Google Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
  (markdown + YAML frontmatter, `type` field required).

---

## 1. The two roots (no collision)

| Root | What lives there | Nature |
|---|---|---|
| `~/.aefos/` (`%USERPROFILE%\.aefos`) | **user content**: `commands/`, `skills/`, `addons/` (fragments + ledger) | portable, syncable, OKF |
| `%APPDATA%\Aefos\` | **machine runtime**: `bin\` (exes), `mcp-bridge.ps1`, `aefos-mcp.json`, sessions, logs | per-machine, not synced |

The CLI writes **content** under `~/.aefos`; it never writes `aefos-mcp.json`
directly (the plugin is the single writer of that). MCP addon servers are
published to an **aggregate** the plugin merges (see §5).

## 2. Registry (`registry.json`) — the index the portal serves

One JSON file at a stable raw URL (default; overridable via the
`AEFOS_ADDONS_REGISTRY` env var). It is the **only** thing the CLI fetches to
resolve a slug.

```json
{
  "schema": 1,
  "addons": [
    {
      "slug": "delphi-janus",
      "name": "Janus ORM Specialist",
      "version": "1.2.0",
      "description": "Expert on the Janus ORM (mapping, CRUD, JSON, dialects).",
      "type": "command",                       // command | mcp | tool (primary kind)
      "trust": "official",                     // official | community
      "url": "https://.../addons/delphi-janus/delphi-janus-1.2.0.zip",
      "sha256": "ab12…",                       // of the .zip, lowercase hex
      "requirements": { "aefos_version": ">=0.30.0" }
    }
  ]
}
```

- `type` is the **primary** kind for portal filtering; a bundle may still carry
  more than one artifact (a `command` addon usually also ships a `skill`).
- `sha256` is **required** — install refuses a mismatch.
- The portal regenerates `registry.json` from every `addon.json` via CI (the CLI
  never parses per-addon files remotely; it only reads the registry + the zip).

## 3. Bundle layout (inside the `.zip`)

Canonical tree — every folder is **optional** except `addon.json`:

```
<slug>/
├── addon.json                 # REQUIRED — the bundle manifest (§4)
├── command/
│   └── COMMAND.md             # the /slug trigger (executor-neutral frontmatter)
├── skill/
│   ├── SKILL.md               # skill activation; references okf/ (and any templates/)
│   └── okf/                   # OKF knowledge bundle (index.md carries okf_version)
│       ├── index.md
│       ├── overview.md · api.md · rules.md · log.md
│       └── playbooks/…
├── templates/                # OPTIONAL — scaffolds the specialist generates (see §3.1)
│   └── <name>/               #   one folder per scaffold, e.g. templates/module/ (a Nidus module)
│       ├── template.json     #   metadata + vars (name/label/default) for the {{Placeholder}}s
│       └── {{Name}}*.pas …   #   the scaffold files; {{Placeholder}}s rendered on use
├── mcp/
│   └── server.json            # one mcpServers fragment (§5)
└── tools/                     # optional Python tools (v1)
    └── …
```

The zip MUST contain exactly one top-level `<slug>/` folder matching the
registry slug (the CLI validates this before extracting).

### 3.2 Several commands / several skills in one bundle

`command/` and `skill/` above are the **single** form: one of each. A bundle
that carries **more than one** uses the plural folder instead, a directory per
artifact:

```
<slug>/
├── addon.json
├── commands/                  # instead of command/
│   ├── build/
│   │   ├── COMMAND.md         # required — the trigger body
│   │   └── references/…       # optional, travels with its command
│   └── review/COMMAND.md
└── skills/                    # instead of skill/
    ├── test-runner/
    │   ├── SKILL.md
    │   └── okf/…
    └── lint/SKILL.md
```

| bundle | installs to | trigger |
|---|---|---|
| `command/COMMAND.md` | `~/.aefos/commands/<slug>/` | `/<slug>` |
| `commands/<name>/` | `~/.aefos/commands/<slug>.<name>/` | `/<slug>.<name>` |
| `skill/` | `~/.aefos/skills/<slug>/` | — |
| `skills/<name>/` | `~/.aefos/skills/<slug>.<name>/` | — |

Rules that are not arbitrary:

- **The plural is a folder per command, never a loose `.md`.** The chat's
  command registry keys a command by its *directory* name and loads
  `<dir>/COMMAND.md`; loose files would install commands the picker never shows.
- **`<slug>.` prefix on the plural form.** `commands/` and `skills/` are flat,
  shared roots. Two addons each shipping a `review` would otherwise overwrite
  one another, and which survived would depend on install order.
- **`artifacts` does not change.** `"command": true` covers both layouts — the
  plural is discovered on disk, so the manifest cannot disagree with the bundle
  about how many there are.
- **Declared and empty fails the install.** `"command": true` with neither
  `command/COMMAND.md` nor any `commands/<name>/` aborts instead of recording a
  no-op as installed.
- **Reinstall clean-replaces**, including artifacts the new version dropped:
  install sweeps `<root>/<slug>.*` before laying the new set down.

### 3.1 `templates/` — carry-along scaffolds (optional, NOT a separate addon type)

`templates/` is **not** an addon type — it is an **optional folder** an addon may
carry to generate structure. If OKF is a specialist's *semantic* knowledge ("how
this framework thinks"), templates are *structural* knowledge ("how a project /
module is laid out"). A Nidus specialist ships `templates/module/` and, on
`/nidus-module Users`, renders it into a module in the canonical Nidus pattern.

**No specialist is required — this composes down to the simplest case.** The
minimal template-carrying addon is a **plain command with only templates** (no
`skill/`, no `okf/`):

```
<slug>/
├── addon.json
├── command/COMMAND.md        # references the template(s) + explains when/how to use them
└── templates/<name>/…        # the scaffold
```

**The reference lives in whatever the addon has:** the `COMMAND.md` (simple case)
or the OKF (specialist case) **defines where each template is** (relative path) and
**explains when/how to use it** (the trigger, what the vars mean). The
`templates/` folder holds the raw scaffold; the command/skill makes the agent aware
of it. So an addon "knows the pattern" because it carries the pattern, and knows
*when* to apply it because its command/OKF says so.

Templates install **scoped to the slug**, at `~/.aefos/templates/<slug>/…`
(parallel to `commands/` and `skills/`), so the reference resolves by slug and there
is no global, un-scoped template namespace to collide.

## 4. Bundle manifest (`addon.json`) — inside the zip

```json
{
  "slug": "delphi-janus",
  "version": "1.2.0",
  "name": "Janus ORM Specialist",
  "description": "Expert on the Janus ORM.",
  "trust": "official",
  "requirements": { "aefos_version": ">=0.30.0" },
  "artifacts": {
    "command":   true,        // command/COMMAND.md OR commands/<name>/ (§3.2)
    "skill":     true,        // skill/ OR skills/<name>/             (§3.2)
    "mcp":       false,        // mcp/server.json present   -> aggregated (§5)
    "tools":     false,        // tools/ present            -> ~/.aefos/addons/<slug>/tools/
    "templates": false         // templates/ present (§3.1) -> ~/.aefos/templates/<slug>/
  }
}
```

`version` and `slug` MUST match the registry entry (guard against a stale zip).

## 5. MCP addon servers — how they reach the config

The CLI does **not** touch `%APPDATA%\Aefos\aefos-mcp.json`. Instead:

1. On install of an `mcp` artifact, the CLI copies `mcp/server.json` to
   `~/.aefos/addons/<slug>/mcp.json`.
2. The CLI regenerates the aggregate `~/.aefos/addons/mcp-servers.json` — the
   union of every installed addon's server(s), shaped as a standard
   `{ "mcpServers": { … } }` object.
3. The Aefos plugin, when it provisions the global config, passes that aggregate
   as the `AExtraServersJson` argument to `EnsureGlobalMcpConfig` (existing merge
   path). The plugin stays the single writer of `aefos-mcp.json`.

`server.json` is a single entry keyed by the addon slug, e.g.:

```json
{ "delphi-janus-db": { "command": "npx", "args": ["-y", "some-mcp"], "env": {} } }
```

## 6. Install pipeline (`aefos install <slug>`)

1. Fetch `registry.json`; find `<slug>`; resolve the pinned `version`/`url`/`sha256`.
2. Gate `requirements.aefos_version` against the installed Aefos version.
3. Download the `.zip` to a temp file; compute SHA-256; **abort on mismatch**.
4. Validate the single top-level `<slug>/` folder + `addon.json` (slug/version match).
5. For a **community** (non-official) bundle carrying `mcp`/`tools` (code that
   runs), require an explicit `--yes` (or an interactive confirm): "this addon
   runs third-party code."
6. Lay out the present artifacts into `~/.aefos/` (commands/ · skills/ · addons/).
7. If an `mcp` artifact: refresh `~/.aefos/addons/mcp-servers.json`.
8. Record in the ledger `~/.aefos/addons/installed.json`:
   `{ slug, version, trust, artifacts[], files[], sha256, installedAt }`.
9. `command` artifacts appear in the `/` picker automatically (global scope);
   the plugin replicates them to the active executor on the next project-open /
   executor-switch (auto-replicate hook).

`uninstall` reverses via the ledger's `files[]`; `update` = uninstall-then-install
of the newer pinned version; `list` prints the ledger.

## 7. Security posture

- SHA-256 verify against the registry — non-negotiable.
- Pinned version only (never "latest branch").
- Trust tiers surfaced on install; third-party code (mcp/tools) needs consent.
- The CLI writes only under `~/.aefos/` and never executes downloaded code at
  install time (it only lays files; execution is the user running the CLI/MCP).
