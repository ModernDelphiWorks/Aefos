unit Aefos.Provider.Copilot;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{ GitHub Copilot driver. Extension-less binary name (ADR-077). MCP is injected
  per-session via --additional-mcp-config in the dispatcher (headless `-p` does
  not auto-load the workspace .mcp.json), so BuildMcpConfigJson is unsupported
  here. Custom prompts are flat `<name>.md` files under $COPILOT_HOME\prompts. }

interface

uses
  Aefos.Provider.Types;

type
  TCopilotExecutorProfile = class(TInterfacedObject, IExecutorProfile)
  private
    FMcpSupport: TMcpSupport;
  public
    constructor Create(const AMcpSupport: TMcpSupport = msUnknown);
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
    function SessionSupport: TSessionSupport;
    function TryCaptureSessionId(const AOutput: UnicodeString;
      out ASessionId: UnicodeString): Boolean;
  end;

implementation

uses
  Aefos.Provider.Base;

constructor TCopilotExecutorProfile.Create(const AMcpSupport: TMcpSupport);
begin
  inherited Create;
  FMcpSupport := AMcpSupport;
end;

function TCopilotExecutorProfile.Kind: TExecutorKind;
begin
  Result := ekCopilot;
end;

function TCopilotExecutorProfile.BinaryName: string;
begin
  // Extension-less (ADR-077): the resolver ladder finds copilot.exe/.cmd/.bat.
  Result := 'copilot';
end;

function TCopilotExecutorProfile.ReplicationTargetRel: string;
begin
  Result := '.copilot\prompts';
end;

function TCopilotExecutorProfile.McpSupport: TMcpSupport;
begin
  // Injected at construction by the live probe (ADR-078); never mutated.
  Result := FMcpSupport;
end;

function TCopilotExecutorProfile.BuildMcpConfigJson(const ARelayExePath,
  APipeName: string): string;
begin
  // Copilot MCP is injected via --additional-mcp-config in the dispatcher.
  // BR-7: never reached on a supported path.
  raise EExecutorProfileError.Create(
    'Copilot executor does not support MCP configuration');
end;

function TCopilotExecutorProfile.BuildModelArgs(
  const AModel: string): TArray<string>;
begin
  // Copilot uses the same `--model <model>` shape as Claude/Codex.
  Result := Aefos.Provider.Base.BuildModelArgs(AModel);
end;

function TCopilotExecutorProfile.CliNotFoundHint: string;
begin
  // Vendor-neutral (no CLI name in user-facing text — Aefos references no vendor).
  Result := 'Open Tools > Options > Aefos > AI Chat to set the Executor path, or put your AI CLI on PATH.';
end;

function TCopilotExecutorProfile.CommandReplicaRelPath(
  const ACommandName: string): string;
begin
  // ADR-080: a Copilot custom prompt is a flat `<name>.md` file.
  Result := ACommandName + '.md';
end;

function TCopilotExecutorProfile.RequiresCommandConversion: Boolean;
begin
  // The canonical COMMAND.md carries YAML frontmatter Copilot cannot consume.
  Result := True;
end;

function TCopilotExecutorProfile.ConvertCommand(
  const ACanonicalContent: string): string;
begin
  Result := Aefos.Provider.Base.StripFrontmatter(ACanonicalContent);
end;

function TCopilotExecutorProfile.ReferenceReplicaRelPath(const ACommandName,
  AReferenceName: string): string;
begin
  Result := Aefos.Provider.Base.ReferenceReplicaRelPath(ACommandName,
    AReferenceName);
end;

function TCopilotExecutorProfile.ResolveReplicationRoot(
  const AProjectRoot: string): string;
begin
  // ADR-237/238: global root — Copilot discovers prompts from a single
  // system-wide directory; the project root is irrelevant for Copilot.
  Result := Aefos.Provider.Base.ResolveCopilotPromptsRoot;
end;

function TCopilotExecutorProfile.BuildDispatchArgs(
  const ACtx: TProviderDispatchContext): TArray<string>;
begin
  Result := BuildModelArgs(ACtx.Model);
  // Conversation continuity. Copilot is the simplest of the four: ONE flag does
  // both jobs -- `--session-id=<uuid>` starts a new session under that id when it
  // is unknown and RESUMES it when it exists -- so there is no new-vs-resume
  // branch here (contrast Claude's --session-id/--resume pair). Proven live
  // 2026-08-03: turn 1 planted a codeword, turn 2 with the same id recalled it.
  //   Two shapes matter and both were paid for: the `=` form (Copilot's own
  // documented spelling) and a REAL v4 UUID -- a merely well-shaped
  // 8-4-4-4-12 string is rejected with the usage hint, and the CLI's refusal
  // looks exactly like a normal answer in the chat. TAefosCliHarness.NewSessionId
  // is CreateGUID-backed, so what we hand over is always v4.
  if (ACtx.SessionId <> '') then
    Result := Result + ['--session-id=' + ACtx.SessionId];
  // --allow-all-tools is REQUIRED for non-interactive; -s = clean response; -p
  // takes the prompt as its VALUE so it MUST stay last. Agent injects the global
  // aefos MCP explicitly (headless -p does NOT auto-load the workspace .mcp.json,
  // verified), placed BEFORE -p. Chat mode omits it (conversation only).
  //   NOTE on the array-constructor spelling: FPC 3.2.2's generics parser chokes
  // on `TArray<string>.Create(` when it follows a `+` (it reads the `<` as a
  // comparison), so these are written as dynamic-array constructors `[...]`
  // instead -- the same values, and a form both compilers parse everywhere.
  if ACtx.AgentMode then
    Result := Result + ['--allow-all-tools', '--additional-mcp-config',
      '@' + ACtx.McpConfigPath, '-s', '-p']
  else
    Result := Result + ['--allow-all-tools', '-s', '-p'];
end;

function TCopilotExecutorProfile.SessionSupport: TSessionSupport;
begin
  Result := ssPinned;
end;

function TCopilotExecutorProfile.TryCaptureSessionId(const AOutput: UnicodeString;
  out ASessionId: UnicodeString): Boolean;
begin
  ASessionId := '';
  Result := False;
end;

end.
