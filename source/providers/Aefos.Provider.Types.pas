unit Aefos.Provider.Types;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Executor-profile contracts (provider abstraction).

  Pure abstraction: every per-executor difference (binary name, command
  replication target, MCP config JSON, model-arg style, CLI-not-found hint,
  MCP support level, command-replica layout + content transform) is owned by
  IExecutorProfile. Consumers (CommandExecutor, CLIBinaryResolver,
  CommandReplicator) hold no executor-named literal — they consume an injected
  profile resolved by Aefos.Provider.Registry.

  C-3: this unit is pure — no ToolsAPI, no Vcl.*, no I/O.
}

interface

uses
  SysUtils;

type
  // ekOllama is the local-runtime executor: no CLI binary — the chat composes
  // an HTTP dispatcher against the user's own Ollama endpoint instead of
  // spawning a process. Everything else in the profile contract still applies.
  TExecutorKind = (ekClaude, ekCodex, ekCopilot, ekGemini, ekOllama);

  TMcpSupport = (msUnknown, msSupported, msUnsupported);

  // How a CLI carries a conversation ACROSS turns. Every executor the chat
  // drives has some form of it -- what differs is only WHO mints the id:
  //   ssNone     no continuity at all; every turn is a brand-new conversation.
  //   ssPinned   WE mint the UUID and hand it to the CLI, which creates the
  //              conversation under that id and later resumes it (Claude,
  //              Copilot, Gemini).
  //   ssCaptured the CLI mints its OWN id and PRINTS it; the executor scrapes
  //              it off the finished run's output and resumes with it on the
  //              next turn (Codex prints `session id: <uuid>` on stdout, the
  //              Aefos agent CLI prints `session: <id>` on stderr).
  // Historical note: this used to be a plain UsesSession: Boolean, which only
  // Claude answered True. Every other executor therefore spawned a stateless
  // process per turn while the panel kept RENDERING the whole conversation --
  // so the chat looked continuous and the model had amnesia (field report
  // 2026-08-03, on the shipped default executor).
  TSessionSupport = (ssNone, ssPinned, ssCaptured);

  // Everything a driver needs to build its dispatch args. The executor resolves
  // these (the global MCP config path, the bridge path, the user's extra MCP
  // server names, the session state) and hands them over; the driver owns only
  // the per-CLI flag SHAPE.
  TProviderDispatchContext = record
    Model: string;
    AgentMode: Boolean;
    McpConfigPath: string;        // the global aefos-mcp.json (file)
    McpBridgePath: string;        // %APPDATA%\Aefos\mcp-bridge.ps1 (for Codex -c)
    McpSession: string;           // the named-pipe session (e.g. 'plugin')
    McpServerName: string;        // the MCP SERVER KEY the driver injects (the
                                  // tool namespace: mcp__<name> / mcp_servers.<name>).
                                  // '' => the driver's default ('aefos'). The RAD
                                  // Studio executor leaves it '' (byte-identical
                                  // 'aefos'); the Lazarus edition sets a DISTINCT
                                  // name ('aefos-lazarus') so a client with BOTH
                                  // IDEs open sees two addressable hosts and routes
                                  // an edit to the right IDE (owner rule 2026-07-18).
    ExtraMcpNames: TArray<string>; // the user's extra MCP servers (pre-auth)
    SessionId: string;            // conversation id (see TSessionSupport): ours
                                  // when ssPinned, the CLI's when ssCaptured
    SessionStarted: Boolean;      // False => new session, True => resume
    // May the CLI use its OWN file/shell tools? False (the default) means every
    // mutation has to come back through the Aefos MCP tools, where the consent
    // modal is. ONE policy, set once by the user; each driver translates it into
    // its own dialect -- or, where its CLI has no such lever, ignores it, and the
    // UI says so rather than pretending otherwise.
    AllowNativeTools: Boolean;
    Endpoint: string;             // provider HTTP endpoint (ekOllama base URL)
    ReasoningEffort: string;      // CLI token low|medium|high|xhigh ('' = the
                                  // executor default); only drivers that expose a
                                  // reasoning-effort control consume it (Codex)
  end;

  IExecutorProfile = interface
    ['{B1F4E2A7-9C3D-4E58-A6B1-7D2F8C4E0A93}']
    function Kind: TExecutorKind;
    function BinaryName: string;
    function ReplicationTargetRel: string;
    function McpSupport: TMcpSupport;
    function BuildMcpConfigJson(const ARelayExePath,
      APipeName: string): string;
    function BuildModelArgs(const AModel: string): TArray<string>;
    function CliNotFoundHint: string;
    // Command-replication layout + content transform (ADR-079, Demand 3/5).
    // Replica path of a command, relative to the replication target root.
    function CommandReplicaRelPath(const ACommandName: string): string;
    // False keeps the byte-identical TFile.Copy fast path; True selects
    // the read -> ConvertCommand -> write path in the replicator.
    function RequiresCommandConversion: Boolean;
    // Transforms a canonical COMMAND.md into the executor's replica content.
    function ConvertCommand(const ACanonicalContent: string): string;
    // Reference-replica layout (ADR-098, Demand 5/6). Replica path of one
    // reference slice, relative to the replication target root.
    function ReferenceReplicaRelPath(const ACommandName,
      AReferenceName: string): string;
    // ADR-238: resolves the absolute destination root for command replication.
    function ResolveReplicationRoot(const AProjectRoot: string): string;
    // Builds the COMPLETE per-CLI dispatch args (model + subcommand + MCP +
    // tool-auth + session). The dispatcher appends the prompt as the LAST token,
    // so each driver orders its flags so that still works (Copilot/Gemini end
    // with -p; Codex ends with the -c overrides + positional prompt; Claude ends
    // with the session flag). The driver owns ITS dialect; the executor stays
    // generic. Profile-driven dispatch (the per-CLI flags used to live in
    // CommandExecutor).
    function BuildDispatchArgs(
      const ACtx: TProviderDispatchContext): TArray<string>;
    // How this CLI carries a conversation across turns. The executor owns the
    // session STATE; the driver only formats the flag (ssPinned) or knows the
    // marker its CLI prints (ssCaptured). Drivers that return ssNone ignore
    // ACtx.SessionId.
    function SessionSupport: TSessionSupport;
    // ssCaptured drivers ONLY: pulls the CLI-minted conversation id out of the
    // finished run's COMBINED stdout+stderr. False when the marker is absent
    // (a run that died before the header, or a CLI version that stopped
    // printing it) -- the caller then leaves the conversation id-less instead
    // of resuming a guess, which would be worse than starting fresh.
    function TryCaptureSessionId(const AOutput: UnicodeString;
      out ASessionId: UnicodeString): Boolean;
  end;

  EExecutorProfileError = class(Exception);

implementation

end.
