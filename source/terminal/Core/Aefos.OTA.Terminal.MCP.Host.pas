unit Aefos.OTA.Terminal.MCP.Host;

{
  MCP host lifecycle. Receives IMCPWorkspaceFacade by injection (ESP-070
  ADR-070-02 / BR10) — no longer constructs any specific facade
  implementation. TTerminalMCPHost never uses ToolsAPI.
}

interface

uses
  Aefos.MCP.Types,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.Server,
  Aefos.OTA.Terminal.MCP.Config;

type
  TTerminalMCPHost = class
  private
    FServer:  IMCPServer;
    FConfig:  TMCPTerminalConfig;
    FFacade:  IMCPWorkspaceFacade;
    function _BuildServer: IMCPServer;
    function _RepoRoot: string;
  public
    constructor Create(const AConfig: TMCPTerminalConfig;
      const AFacade: IMCPWorkspaceFacade);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    function Started: Boolean;
    // True when this host was built from exactly AConfig — lets the owner skip
    // a stop+start bounce on a no-op Options apply (the 'Test MCP' button
    // applies on every click). A needless restart is where the stop-join can
    // leak a mid-dispatch worker (field crash 2026-07-08: C0150014 right after
    // the click, 'Unknown Hard Error' on IDE close).
    function Matches(const AConfig: TMCPTerminalConfig): Boolean;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.AddonGateway,
  Aefos.MCP.Transport.NamedPipe,
  Aefos.OTA.Terminal.MCP.RepoRootPolicy,
  Aefos.OTA.Terminal.MCP.Composition,
  Aefos.OTA.IDE.GutterReview, // RegisterReviewFeedbackTool (OTA-side tool)
  Aefos.OTA.MCP.IssueReport; // RegisterProposeAefosIssueTool (OTA-side tool)

{ TTerminalMCPHost }

constructor TTerminalMCPHost.Create(const AConfig: TMCPTerminalConfig;
  const AFacade: IMCPWorkspaceFacade);
begin
  inherited Create;
  FConfig := AConfig;
  FFacade := AFacade;
end;

destructor TTerminalMCPHost.Destroy;
begin
  Stop;
  inherited;
end;

function TTerminalMCPHost._RepoRoot: string;
begin
  // Anchor Core's read-only Git facade (Aefos.MCP.GitFacade) at the
  // enclosing .git work tree, NOT the IDE executable's directory and NOT the
  // active project's directory verbatim. ParamStr(0) resolves to the bds.exe
  // install folder, never a Git repo (ESP-084 S2 fixed that). But GetProjectPath
  // alone is still too narrow: when the project dir is a sub-tree of a larger
  // .git work tree (the RADShell monorepo — a package dir inside a source tree),
  // Core scopes its repo to the project dir and GetFileDiff returns 'outside-repo'
  // for any repo file outside it (#7, ESP-085). Ascend from the project dir to
  // the nearest ancestor carrying a .git marker so the whole work tree is in
  // scope. The marker probe (the impure boundary) checks both forms: a normal
  // clone stores .git as a directory, a worktree/submodule gitlink as a file
  // (R1). No enclosing repo → AscendToRepoRoot returns the project dir unchanged
  // and Core's honest 'not-a-repo' degrade is preserved (R2). Core is untouched
  // (BR1) — the defect was the consumer-side repo-root resolver this host injects.
  Result := AscendToRepoRoot(FFacade.GetProjectPath,
    function(ADir: string): Boolean
    var
      LMarker: string;
    begin
      LMarker := IncludeTrailingPathDelimiter(ADir) + '.git';
      Result := DirectoryExists(LMarker) or FileExists(LMarker);
    end);
end;

function TTerminalMCPHost._BuildServer: IMCPServer;
var
  LConsent: IMCPConsentRegistry;
  LAudit:   IMCPAuditLog;
  LServer:  IMCPServer;
begin
  LConsent := TMCPConsentRegistry.Create;
  if FConfig.AuditPath <> '' then
    LAudit := TMCPAuditLog.Create(FConfig.AuditPath)
  else
    LAudit := TMCPAuditLog.Create;

  LServer := TMCPServer.Create(
    function: IMCPTransport
    begin
      Result := TNamedPipeTransport.Create;
    end,
    procedure(const AProc: TThreadProcedure)
    begin
      TThread.Synchronize(nil, AProc);
    end,
    '0.1.0');

  // RULE #1 (CLAUDE.md): arm the intent guard for the terminal's MCP session
  // too — same shared facade read as the chat/plugin host, so a Claude terminal
  // gets the design/code view enforcement identically. RTL-only: the OTA read
  // lives in the injected facade, not here.
  LServer.SetViewProvider(
    function: TMCPToolIntent
    begin
      Result := FFacade.CurrentIdeViewIntent;
    end);

  // Addon-MCP gateway (ESP: `aefos install <mcp>` -> every agent). A Claude/Codex
  // terminal connected to this session sees the installed addons' tools too, with
  // no per-CLI wiring. Children are killed by the server's Stop/Destroy.
  LServer.SetToolGateway(TMCPAddonGateway.Create);

  RegisterTerminalMcpTools(LServer, FFacade, LConsent, LAudit,
    function: string begin Result := _RepoRoot; end);
  // OTA-side tool: lets the agent fetch the user's gutter review annotations.
  TGutterReview.RegisterReviewFeedbackTool(LServer);
  // OTA-side tool: lets the agent see which edits are still pending in the review
  // gutter (applied to the buffer, not yet approved/rejected) — read-only, never blocks.
  TGutterReview.RegisterPendingReviewsTool(LServer);
  // OTA-side tool: the agent PROPOSES a bug/suggestion; a human-gated editable
  // dialog opens a pre-filled GitHub issue (it never files anything itself).
  RegisterProposeAefosIssueTool(LServer);

  Result := LServer;
end;

procedure TTerminalMCPHost.Start;
begin
  if Assigned(FServer) then
    Exit;
  FServer := _BuildServer;
  FServer.Start(MCP_PIPE_PREFIX + FConfig.SessionName);
end;

procedure TTerminalMCPHost.Stop;
begin
  if Assigned(FServer) then
  begin
    FServer.Stop;
    FServer := nil;
  end;
end;

function TTerminalMCPHost.Started: Boolean;
begin
  Result := Assigned(FServer) and FServer.Started;
end;

function TTerminalMCPHost.Matches(const AConfig: TMCPTerminalConfig): Boolean;
begin
  Result := (FConfig.Enabled = AConfig.Enabled) and
    (FConfig.SessionName = AConfig.SessionName) and
    (FConfig.AuditPath = AConfig.AuditPath) and
    (FConfig.ConsentTimeoutSecs = AConfig.ConsentTimeoutSecs);
end;

end.
