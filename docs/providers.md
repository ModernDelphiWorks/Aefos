# Provider drivers (multi-CLI)

**BPL:** `Aefos.Providers` · **Source:** `source/providers` · **Requires:** `rtl`
only (a pure leaf).

Aefos is bring-your-own-CLI and supports four AI command-line tools. Every
per-executor difference is isolated behind one interface so the rest of the
codebase carries **no executor-named literal**.

## The abstraction — `IExecutorProfile`

`Aefos.Provider.Types` declares the contract. A profile owns everything that varies
between CLIs:

| Concern | Method |
|---------|--------|
| Which CLI | `Kind: TExecutorKind` (`ekClaude`/`ekCodex`/`ekCopilot`/`ekGemini`) |
| Binary to spawn | `BinaryName` |
| Model flag shape | `BuildModelArgs(model)` |
| MCP support level | `McpSupport: TMcpSupport` |
| MCP config JSON | `BuildMcpConfigJson(relayExe, pipeName)` |
| "CLI not found" hint | `CliNotFoundHint` |
| Skill/command replica layout | `CommandReplicaRelPath`, `RequiresCommandConversion`, `ConvertCommand`, `ReferenceReplicaRelPath`, `ResolveReplicationRoot` |
| **Complete dispatch args** | `BuildDispatchArgs(ctx: TProviderDispatchContext)` |
| Conversation continuity | `UsesSession` |

Consumers — `CommandExecutor`, `CLIBinaryResolver`, `CommandReplicator` — hold an
**injected** profile resolved by `Aefos.Provider.Registry` (factory
`ResolveExecutorProfile` + `Parse`/`ToString`/`DisplayName`). The executor assembles
a `TProviderDispatchContext` (global MCP config path, bridge path, session, the
user's extra MCP server names, model, agent-mode flag) and delegates flag-building to
the driver. The driver owns only the per-CLI flag **shape**.

## The four drivers

| Driver | Executor | Dispatch (agent mode) | Session |
|--------|----------|------------------------|:---:|
| `Aefos.Provider.Claude` | Claude Code (Anthropic) | `--mcp-config <global> --strict-mcp-config` + `--allowedTools mcp__aefos Read Glob Grep` + `--session-id`/`--resume` | ✅ |
| `Aefos.Provider.Codex` | Codex (OpenAI) | per-invocation `-c mcp_servers.aefos.command=…` `-c mcp_servers.aefos.args=[…]` TOML overrides | — |
| `Aefos.Provider.Copilot` | GitHub Copilot CLI (Embarcadero's built-in AI) | `--additional-mcp-config @<global> --allow-all-tools`, prompt via trailing `-p` | — |
| `Aefos.Provider.Gemini` | Gemini (Google) | `--allowed-mcp-server-names aefos`, prompt via trailing `-p` | — |

`Aefos.Provider.Base` holds the shared behaviour (model args, frontmatter strip,
global prompt-root resolvers, reference layout) that the concrete drivers inherit.

### Dispatch ordering rule

The dispatcher appends the **prompt as the last token**, so each driver orders its
flags accordingly: Copilot and Gemini end with `-p`; Codex ends with the `-c`
overrides plus the positional prompt; Claude ends with the session flag.

### Session is executor *state*

Only `UsesSession = True` (Claude today) consumes `ctx.SessionId` /
`ctx.SessionStarted`. The executor owns the session state; the driver only formats
the flag. Drivers that return `False` ignore the session fields.

## MCP wiring per CLI

All four are pointed at the **single global config** `%APPDATA%\Aefos\aefos-mcp.json`
(see [architecture.md](architecture.md#mcp-configuration--self-provisioning)). The
differences:

- **Claude** — `--strict-mcp-config` means *only* our file is used (ignores any
  project `.mcp.json`).
- **Copilot** — headless `copilot -p` does **not** auto-load the workspace
  `.mcp.json`; it must be injected with `--additional-mcp-config @<global>` and
  `--allow-all-tools` is required for non-interactive runs.
- **Codex** — no config file is touched; the `aefos` server is passed as per-run
  `-c` TOML overrides. (Codex still needs `codex login` to run the model; the MCP
  connects regardless.)
- **Gemini** — no flag exists to point at an arbitrary config, so the `aefos` server
  is merged into `~/.gemini/settings.json`; the driver then scopes it with
  `--allowed-mcp-server-names aefos`.

## Notes

- The drivers register **nothing** in the IDE — `Aefos.Providers` is a passive leaf;
  only `Aefos.OTA.Chat` requires it.
- The old single `Aefos.OTA.Chat.Core.ExecutorProfile(.Types)` unit was split into
  this package.
