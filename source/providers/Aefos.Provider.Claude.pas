unit Aefos.Provider.Claude;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{ Claude Code driver. The MVP target — the only CLI whose `mcp list` does a live
  handshake and whose mcp-config builder is real (BuildMcpConfigJson). }

interface

uses
  Aefos.Provider.Types;

type
  TClaudeExecutorProfile = class(TInterfacedObject, IExecutorProfile)
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
{$IFDEF FPC}
  // FPC 3.2.2 has neither System.IOUtils nor System.JSON; the shims present the
  // same API shape. Behind an IFDEF (not used unconditionally) so the Delphi
  // package graph is untouched -- the shims live in Aefos.MCP.Core.bpl, which
  // Aefos.Providers.bpl does not require.
  Aefos.Compat.IO,
  Aefos.Compat.Json,
{$ELSE}
  System.IOUtils,
  System.JSON,
{$ENDIF}
  Aefos.Provider.Base;

function TClaudeExecutorProfile.Kind: TExecutorKind;
begin
  Result := ekClaude;
end;

function TClaudeExecutorProfile.BinaryName: string;
begin
  Result := 'claude.exe';
end;

function TClaudeExecutorProfile.ReplicationTargetRel: string;
begin
  Result := '.claude\commands';
end;

function TClaudeExecutorProfile.McpSupport: TMcpSupport;
begin
  Result := msSupported;
end;

function TClaudeExecutorProfile.BuildMcpConfigJson(const ARelayExePath,
  APipeName: string): string;
var
  LRoot: TJSONObject;
  LServers: TJSONObject;
  LServer: TJSONObject;
  LArgs: TJSONArray;
begin
  LRoot := TJSONObject.Create;
  try
    LArgs := TJSONArray.Create;
    LArgs.Add(APipeName);
    LServer := TJSONObject.Create;
    LServer.AddPair('command', ARelayExePath);
    LServer.AddPair('args', LArgs);
    LServers := TJSONObject.Create;
    LServers.AddPair('aefos', LServer);
    LRoot.AddPair('mcpServers', LServers);
    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

function TClaudeExecutorProfile.BuildModelArgs(
  const AModel: string): TArray<string>;
begin
  Result := Aefos.Provider.Base.BuildModelArgs(AModel);
end;

function TClaudeExecutorProfile.CliNotFoundHint: string;
begin
  // Vendor-neutral (no CLI name in user-facing text — Aefos references no vendor).
  Result := 'Open Tools > Options > Aefos > AI Chat to set the Executor path, or put your AI CLI on PATH.';
end;

function TClaudeExecutorProfile.CommandReplicaRelPath(
  const ACommandName: string): string;
begin
  // A Claude Code slash-command is a FLAT `.claude\commands\<name>.md` file
  // (the filename is the command name). Identity copy: the canonical
  // COMMAND.md frontmatter is Claude-compatible.
  Result := ACommandName + MD_EXTENSION;
end;

function TClaudeExecutorProfile.RequiresCommandConversion: Boolean;
begin
  // Identity copy — the canonical COMMAND.md is already a Claude command.
  Result := False;
end;

function TClaudeExecutorProfile.ConvertCommand(
  const ACanonicalContent: string): string;
begin
  // Defensive identity — never invoked while RequiresCommandConversion = False.
  Result := ACanonicalContent;
end;

function TClaudeExecutorProfile.ReferenceReplicaRelPath(const ACommandName,
  AReferenceName: string): string;
begin
  Result := Aefos.Provider.Base.ReferenceReplicaRelPath(ACommandName,
    AReferenceName);
end;

function TClaudeExecutorProfile.ResolveReplicationRoot(
  const AProjectRoot: string): string;
begin
  // ADR-238: project-relative root — Claude Code reads project-local commands.
  Result := TPath.Combine(AProjectRoot, ReplicationTargetRel);
end;

function TClaudeExecutorProfile.BuildDispatchArgs(
  const ACtx: TProviderDispatchContext): TArray<string>;
var
  LName: string;
  LServer: string;
begin
  // The MCP server KEY authorized/denied below. 'aefos' by default (RAD Studio,
  // byte-identical); the Lazarus edition passes 'aefos-lazarus' so it matches the
  // server key written into the config file the CLI reads (BuildMergedConfig) and
  // never collides with a Delphi host's 'aefos' when both IDEs are open.
  LServer := Aefos.Provider.Base.ResolveMcpServerName(ACtx.McpServerName);
  Result := BuildModelArgs(ACtx.Model);
  // MCP from the single global config; --strict-mcp-config => ignore any project
  // .mcp.json, so the served set is exactly aefos + the user's extras.
  //   An EMPTY McpConfigPath means the host wired no MCP at all (the Lazarus
  // edition's chat-only dispatch today). Emitting the flag pair anyway would send
  // `--mcp-config ""`, which the CLI rejects -- so the flag is simply omitted and
  // the CLI runs with no MCP servers, which is exactly what an empty path means.
  // On the RAD Studio side the executor always resolves a real global config
  // path, so this guard never fires there and that dispatch is byte-identical.
  // NOTE on the array-constructor spelling used throughout this method: FPC
  // 3.2.2's generics parser chokes on `TArray<string>.Create(` when it follows a
  // `+` (it reads the `<` as a comparison), so every one of these is written as
  // a dynamic-array constructor `[...]` instead -- the same values, and a form
  // both compilers parse everywhere.
  if ACtx.McpConfigPath <> '' then
    Result := Result + ['--mcp-config', ACtx.McpConfigPath,
      '--strict-mcp-config'];
  // Tool authorization. --allowedTools is VARIADIC — it must NOT be the last
  // flag, or it swallows the positional prompt; the session flag below
  // terminates it. Agent pre-authorizes our MCP + read-only native tools (so the
  // model can act + read attached files); mutating tools stay gated behind the
  // HTML consent modal. Chat mode gates our MCP OFF (conversation only).
  if ACtx.AgentMode then
  begin
    Result := Result + ['--allowedTools', 'mcp__' + LServer,
      'Read', 'Glob', 'Grep'];
    // The user's ONE tool-permission choice, in Claude's dialect. Claude is the
    // only one of the four CLIs with a real per-tool lever, so it is the only
    // one where this setting can change anything -- see TAIFlowOptions.
    // AgentNativeTools.
    //   Left OFF, this list is exactly what it always was, and it is the reason
    // a legitimate agent setup could not write a file: Write/Edit/Bash are
    // absent on purpose so mutation comes back through our MCP tools and their
    // consent modal. Turned ON, the model may also use Claude's own -- which is
    // what the other three CLIs do unconditionally.
    if ACtx.AllowNativeTools then
      Result := Result + ['Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'Bash'];
    for LName in ACtx.ExtraMcpNames do
      Result := Result + ['mcp__' + LName];
  end
  else
    Result := Result + ['--allowedTools', 'Read', 'Glob', 'Grep',
      '--disallowedTools', 'mcp__' + LServer];
  // Conversation continuity (terminates the variadic; the prompt follows).
  if ACtx.SessionStarted then
    Result := Result + ['--resume', ACtx.SessionId]
  else
    Result := Result + ['--session-id', ACtx.SessionId];
end;

function TClaudeExecutorProfile.PromptViaStdin: Boolean;
begin
  // Claude Code reads the prompt from stdin when no positional prompt is given,
  // and a piped (non-TTY) stdin is already what puts it in non-interactive print
  // mode -- which is how this driver has ALWAYS run, since the dispatcher opens a
  // stdin pipe for every child. So nothing else changes: the args built above end
  // with the session flag and are complete without a trailing prompt token.
  //   Verified live against claude.exe 2.1.246 on the reporter's shape:
  //     printf '<prompt>' | claude.exe --session-id <uuid>
  //   answers and exits 0, with no -p and no positional argument.
  //   This is the fix for the CreateProcess 206 (ERROR_FILENAME_EXCED_RANGE) that
  // made every chat turn fail WITH A PROJECT OPEN: the rendered project context
  // rides in the prompt, and its active-unit body alone is capped at 32 KB --
  // one byte over what a command line can hold. Off the command line, there is no
  // limit to exceed.
  Result := True;
end;

function TClaudeExecutorProfile.SessionSupport: TSessionSupport;
begin
  // We mint the UUID: `--session-id <uuid>` creates the conversation under it,
  // `--resume <uuid>` continues it (BuildDispatchArgs above).
  Result := ssPinned;
end;

function TClaudeExecutorProfile.TryCaptureSessionId(const AOutput: UnicodeString;
  out ASessionId: UnicodeString): Boolean;
begin
  // ssPinned: the id is ours, never scraped.
  ASessionId := '';
  Result := False;
end;

end.
