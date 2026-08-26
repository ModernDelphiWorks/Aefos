unit Aefos.Provider.Gemini;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{ Gemini driver. Extension-less binary name (ADR-077). Uses `-m <model>` (NOT the
  shared `--model`). MCP is configured via the `gemini mcp` subcommand /
  settings.json, not an mcp-config flag, so BuildMcpConfigJson is unsupported
  here. Custom commands are flat `<name>.md` files under $GEMINI_HOME\commands. }

interface

uses
  Aefos.Provider.Types;

type
  TGeminiExecutorProfile = class(TInterfacedObject, IExecutorProfile)
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
    function PromptViaStdin: Boolean;
    function SessionSupport: TSessionSupport;
    function TryCaptureSessionId(const AOutput: UnicodeString;
      out ASessionId: UnicodeString): Boolean;
  end;

implementation

uses
  Aefos.Provider.Base;

constructor TGeminiExecutorProfile.Create(const AMcpSupport: TMcpSupport);
begin
  inherited Create;
  FMcpSupport := AMcpSupport;
end;

function TGeminiExecutorProfile.Kind: TExecutorKind;
begin
  Result := ekGemini;
end;

function TGeminiExecutorProfile.BinaryName: string;
begin
  // Extension-less (ADR-077): the resolver ladder finds gemini.exe/.cmd/.bat.
  Result := 'gemini';
end;

function TGeminiExecutorProfile.ReplicationTargetRel: string;
begin
  Result := '.gemini\commands';
end;

function TGeminiExecutorProfile.McpSupport: TMcpSupport;
begin
  // Injected at construction by the live probe (ADR-078); never mutated.
  Result := FMcpSupport;
end;

function TGeminiExecutorProfile.BuildMcpConfigJson(const ARelayExePath,
  APipeName: string): string;
begin
  // Gemini MCP is configured via the `gemini mcp` subcommand / settings.json,
  // not an mcp-config JSON file. BR-7: never reached on a supported path.
  raise EExecutorProfileError.Create(
    'Gemini executor does not support MCP configuration');
end;

function TGeminiExecutorProfile.BuildModelArgs(
  const AModel: string): TArray<string>;
var
  LModel: string;
begin
  // Gemini uses `-m <model>`, NOT the shared `--model` shape. Sanitise first so
  // a hand-typed "gemini-3.5-flash (Low)" never reaches -m verbatim (400).
  LModel := SanitizeModelForCli(AModel);
  SetLength(Result, 0);
  if LModel <> '' then
    Result := ['-m', LModel];
end;

function TGeminiExecutorProfile.CliNotFoundHint: string;
begin
  // Vendor-neutral (no CLI name in user-facing text — Aefos references no vendor).
  Result := 'Open Tools > Options > Aefos > AI Chat to set the Executor path, or put your AI CLI on PATH.';
end;

function TGeminiExecutorProfile.CommandReplicaRelPath(
  const ACommandName: string): string;
begin
  // ADR-080: a Gemini custom command is a flat `<name>.md` file.
  Result := ACommandName + '.md';
end;

function TGeminiExecutorProfile.RequiresCommandConversion: Boolean;
begin
  // The canonical COMMAND.md carries YAML frontmatter Gemini cannot consume.
  Result := True;
end;

function TGeminiExecutorProfile.ConvertCommand(
  const ACanonicalContent: string): string;
begin
  Result := Aefos.Provider.Base.StripFrontmatter(ACanonicalContent);
end;

function TGeminiExecutorProfile.ReferenceReplicaRelPath(const ACommandName,
  AReferenceName: string): string;
begin
  Result := Aefos.Provider.Base.ReferenceReplicaRelPath(ACommandName,
    AReferenceName);
end;

function TGeminiExecutorProfile.ResolveReplicationRoot(
  const AProjectRoot: string): string;
begin
  // ADR-237/238: global root — Gemini discovers commands from a single
  // system-wide directory; the project root is irrelevant for Gemini.
  Result := Aefos.Provider.Base.ResolveGeminiCommandsRoot;
end;

function TGeminiExecutorProfile.BuildDispatchArgs(
  const ACtx: TProviderDispatchContext): TArray<string>;
begin
  // --yolo auto-approves tool actions, --skip-trust trusts the workspace, -p
  // takes the prompt as its VALUE so it MUST stay last. Gemini has no mcp-config
  // flag — the aefos server lives in ~/.gemini/settings.json (provisioned by the
  // executor). In Agent mode --allowed-mcp-server-names (variadic, terminated by
  // -p) scopes the session to aefos; Chat mode omits it (conversation only).
  //   NOTE on the array-constructor spelling: FPC 3.2.2's generics parser chokes
  // on `TArray<string>.Create(` when it follows a `+` (it reads the `<` as a
  // comparison), so these are written as dynamic-array constructors `[...]`
  // instead -- the same values, and a form both compilers parse everywhere.
  Result := BuildModelArgs(ACtx.Model);
  Result := Result + ['--yolo', '--skip-trust'];
  // Conversation continuity, in Claude's shape: `--session-id <uuid>` starts the
  // conversation under an id we mint, `-r/--resume <uuid>` continues it.
  //   ORDER IS LOAD-BEARING: this pair MUST come before --allowed-mcp-server-names
  // below, which is VARIADIC and only stops at -p -- appended after it, the flag
  // and the uuid would be eaten as two more server names and the session would
  // silently never resume (the same trap Claude's --allowedTools comment records).
  //   Proven live 2026-08-03, but only AFTER the bundled gemini.exe was fixed:
  // the shipped build refused every invocation with `Unknown arguments:
  // max-old-space-size` (a repackaging defect, see installer\fetch-clis.ps1), so
  // for a while this was the one dialect taken from --help rather than measured.
  // With the rebuilt binary, turn 1 planted a codeword and turn 2 recalled it.
  if ACtx.SessionId <> '' then
  begin
    if ACtx.SessionStarted then
      Result := Result + ['--resume', ACtx.SessionId]
    else
      Result := Result + ['--session-id', ACtx.SessionId];
  end;
  // The server name must match the key provisioned into ~/.gemini/settings.json
  // (EnsureGeminiConfig): 'aefos' by default (RAD Studio), 'aefos-lazarus' when
  // the Lazarus executor overrides it so both IDEs stay addressable.
  if ACtx.AgentMode then
    Result := Result + ['--allowed-mcp-server-names',
      Aefos.Provider.Base.ResolveMcpServerName(ACtx.McpServerName)];
  Result := Result + ['-p'];
end;

function TGeminiExecutorProfile.PromptViaStdin: Boolean;
begin
  // Left on the command line for the same reason as Copilot: these args END with
  // `-p`, whose VALUE is the prompt, so removing the last token would leave the
  // flag dangling. The Gemini CLI's own help does say `-p` is "appended to input
  // on stdin (if any)", which is the seam a stdin switch would use -- but that
  // needs the args changed with it and proven against a live run, and this is the
  // path every Gemini chat turn takes. Not flipped on documentation alone.
  //   An over-long command line is now reported for what it is instead of failing
  // as an opaque CreateProcess 206 (Dispatcher.ProcessRunner).
  Result := False;
end;

function TGeminiExecutorProfile.SessionSupport: TSessionSupport;
begin
  Result := ssPinned;
end;

function TGeminiExecutorProfile.TryCaptureSessionId(const AOutput: UnicodeString;
  out ASessionId: UnicodeString): Boolean;
begin
  ASessionId := '';
  Result := False;
end;

end.
