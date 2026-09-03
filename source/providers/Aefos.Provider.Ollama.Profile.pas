unit Aefos.Provider.Ollama.Profile;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Executor profile for the local Ollama runtime.

  Phase D (2026-07-09): ekOllama is now a REAL CLI profile. The shipped
  AefosAgent.exe (a native Ollama agent CLI) is the binary; it streams to the
  Ollama endpoint over HTTP and, in agent mode, drives the in-process aefos MCP
  directly over the named pipe (no PowerShell bridge). So BinaryName is the CLI,
  MCP is supported, and BuildDispatchArgs emits --model / --endpoint plus, in
  agent mode, --mcp-pipe / --permission-mode. This replaces the old in-process
  HTTP dispatcher path. Command replication is pointed at a global per-user
  folder (like Gemini's global root) so the replicator stays uniform without
  writing CLI-specific dirs into the user's project.

  C-3: pure — no ToolsAPI, no Vcl.*, no I/O beyond env/home resolution in
  Provider.Base (same as the other drivers' global roots).
}

interface

uses
  Aefos.Provider.Types;

type
  TOllamaExecutorProfile = class(TInterfacedObject, IExecutorProfile)
  public
    function Kind: TExecutorKind;
    function BinaryName: string;
    function ReplicationTargetRel: string;
    function McpSupport: TMcpSupport;
    function BuildMcpConfigJson(const ARelayExePath,
      APipeName: string): string;
    function BuildModelArgs(const AModel: string): TArray<string>;
    function CliNotFoundHint: string;
    function CommandReplicaRelPath(const ACommandName: string): string;
    function RequiresCommandConversion: Boolean;
    function ConvertCommand(const ACanonicalContent: string): string;
    function ReferenceReplicaRelPath(const ACommandName,
      AReferenceName: string): string;
    function ResolveReplicationRoot(const AProjectRoot: string): string;
    function BuildDispatchArgs(
      const ACtx: TProviderDispatchContext): TArray<string>;
    function PromptViaStdin: Boolean;
    function SessionSupport: TSessionSupport;
    function TryCaptureSessionId(const AOutput: UnicodeString;
      out ASessionId: UnicodeString): Boolean;
  end;

implementation

uses
  Aefos.Provider.Base;

function TOllamaExecutorProfile.Kind: TExecutorKind;
begin
  Result := ekOllama;
end;

function TOllamaExecutorProfile.BinaryName: string;
begin
  // The shipped native agent CLI. Resolved from the Aefos install/provision
  // location by the composition site (not PATH), since it's ours, not a
  // user-supplied third-party CLI.
  Result := 'AefosAgent.exe';
end;

function TOllamaExecutorProfile.ReplicationTargetRel: string;
begin
  // Informational only (the resolver below is the authority, ADR-239).
  Result := '.aefos\commands';
end;

function TOllamaExecutorProfile.McpSupport: TMcpSupport;
begin
  // The agent CLI speaks MCP natively over the named pipe (Phase D). Behavior-
  // neutral today (only tests read this; BuildMcpConfigJson has no caller) but
  // now truthful.
  Result := msSupported;
end;

function TOllamaExecutorProfile.BuildMcpConfigJson(const ARelayExePath,
  APipeName: string): string;
begin
  raise EExecutorProfileError.Create(
    'The local-model executor does not support MCP configuration');
end;

function TOllamaExecutorProfile.BuildModelArgs(
  const AModel: string): TArray<string>;
var
  LModel: string;
begin
  LModel := Aefos.Provider.Base.SanitizeModelForCli(AModel);
  if LModel = '' then
    SetLength(Result, 0)
  else
    Result := ['--model', LModel];
end;

function TOllamaExecutorProfile.CliNotFoundHint: string;
begin
  // The agent CLI ships with Aefos, so a miss means a broken/partial install
  // rather than a missing user-supplied tool.
  Result := 'The Aefos agent CLI (AefosAgent.exe) was not found. Reinstall ' +
    'Aefos, or check Tools > Options > Aefos > AI Chat.';
end;

function TOllamaExecutorProfile.CommandReplicaRelPath(
  const ACommandName: string): string;
begin
  Result := ACommandName + '.md';
end;

function TOllamaExecutorProfile.RequiresCommandConversion: Boolean;
begin
  // Byte-identical copy: nothing consumes these replicas today, so keep the
  // fast path.
  Result := False;
end;

function TOllamaExecutorProfile.ConvertCommand(
  const ACanonicalContent: string): string;
begin
  Result := ACanonicalContent;
end;

function TOllamaExecutorProfile.ReferenceReplicaRelPath(const ACommandName,
  AReferenceName: string): string;
begin
  Result := Aefos.Provider.Base.ReferenceReplicaRelPath(ACommandName,
    AReferenceName);
end;

function TOllamaExecutorProfile.ResolveReplicationRoot(
  const AProjectRoot: string): string;
begin
  // Global per-user root (Gemini precedent): the replicator stays uniform and
  // nothing lands inside the user's project.
  Result := Aefos.Provider.Base.ResolveAefosLocalCommandsRoot;
end;

function TOllamaExecutorProfile.BuildDispatchArgs(
  const ACtx: TProviderDispatchContext): TArray<string>;
const
  // Matches the chat host's server: Register starts \\.\pipe\aefos-mcp-<session>
  // (MCP_PIPE_PREFIX + 'plugin'). Hardcoded here to keep this leaf driver free
  // of an Aefos.MCP.Core dependency; it is a stable wire constant.
  CPipePrefix = 'aefos-mcp-';
begin
  Result := BuildModelArgs(ACtx.Model); // --model X (or nothing)
  if ACtx.Endpoint <> '' then
    Result := Result + ['--endpoint', ACtx.Endpoint];
  // Conversation continuity (ssCaptured). The agent CLI has carried a session
  // store all along (Aefos.Agent.Session, one JSON per conversation) -- the chat
  // simply never passed the flag, so the local model was re-introduced to the
  // user every turn.
  //   ssCaptured, not ssPinned, because `--resume <unknown-id>` is FATAL there:
  // AefosAgent.dpr Halts with exit 2 when the session file does not exist. So we
  // may only pass an id the CLI itself already minted -- it echoes it as
  // `session: <id>` on STDERR (kept off stdout precisely so a caller can pick it
  // up without polluting the model's text), and the executor's error callback
  // folds stderr into the same accumulated buffer TryCaptureSessionId reads.
  if ACtx.SessionStarted and (ACtx.SessionId <> '') then
    Result := Result + ['--resume', ACtx.SessionId];
  // Agent mode wires the in-process MCP over the pipe the chat host serves;
  // chat mode omits it, so the CLI runs conversation-only. Permission is auto
  // for now (server-side RULE #1 guards still apply); an interactive Ask gate
  // is a tracked follow-up, ideally enforced server-side for every executor.
  if ACtx.AgentMode and (ACtx.McpSession <> '') then
    Result := Result + ['--mcp-pipe', CPipePrefix + ACtx.McpSession,
      '--permission-mode', 'auto-edits'];
end;

function TOllamaExecutorProfile.PromptViaStdin: Boolean;
begin
  // The local agent CLI takes the prompt positionally, like today. Its args are
  // ours (AefosAgent.dpr), so this is the one driver where the stdin dialect
  // could be DEFINED rather than discovered -- but that means changing the CLI
  // and the driver together, which is a different change from fixing the 206.
  Result := False;
end;

function TOllamaExecutorProfile.SessionSupport: TSessionSupport;
begin
  Result := ssCaptured;
end;

function TOllamaExecutorProfile.TryCaptureSessionId(const AOutput: UnicodeString;
  out ASessionId: UnicodeString): Boolean;
begin
  // `session: <id>` on stderr (AefosAgent.dpr). The marker carries its trailing
  // space so it cannot also match Codex's `session id: ` shape if the two ever
  // share a buffer.
  Result := TCliSessionScraper.TryIdAfterMarker(AOutput, 'session: ',
    ASessionId);
end;

end.
