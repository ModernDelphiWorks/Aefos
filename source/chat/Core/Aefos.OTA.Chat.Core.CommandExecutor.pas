unit Aefos.OTA.Chat.Core.CommandExecutor;

{
  Command orchestrator (ESP-008, demand 4/5).

  Wires the four collaborators behind the keyboard shortcut into one flow:
    registry.LoadBody → builder.Build/Render → resolver → dispatcher.Dispatch
                                                              ↓
                                                  surface.Append/Complete/Error

  Final-prompt assembly (BR-2):
    <rendered context>
    \n\n---\n\n
    <command body>
    \n\n## User selection\n\n```\n<selection>\n```

  Behavioural rules:
    - BR-4 / AC-006 (retired): empty selection no longer shortcircuits; commands
      run with project context even when nothing is selected in the editor.
    - BR-5 / AC-007: ResolveCLIBinary empty → Surface.ReportError(ECLINotFound);
      the dispatcher is not invoked.
    - AC-008: EnsurePreinstalled is invoked lazily on the first call per
      project-root (memoised in a TStringList, case-insensitive).
    - BR-7 / AC-009: Execute is non-reentrant; a second call cancels the
      previous run via FRunHandle.Cancel before starting a new one.
    - BR-6: Surface.Clear() runs at the top of every Execute, so the panel
      shows only the latest run's stream.

  C-5: this is the ONLY unit that imports both the registry and the
  dispatcher; tests for builder / resolver do not couple to either.
}

interface

uses
  System.SysUtils,
  System.Classes,
  Aefos.OTA.Chat.Core.CommandRegistry.Types,
  Aefos.OTA.Chat.Core.ProjectContextBuilder.Types,
  Aefos.OTA.Chat.Core.Dispatcher.Types,
  Aefos.OTA.Chat.Core.CLIDispatcher,
  Aefos.OTA.Chat.Core.Config.Types,
  Aefos.Provider.Types,
  // THE shared, CLI-agnostic dispatch harness (the ONE owner of the final-prompt
  // + dispatch-request rule). This executor now DELEGATES both to it; it no
  // longer keeps a private copy of the orchestration (owner mandate 2026-07-20).
  Aefos.Chat.Core.CliHarness,
  Aefos.OTA.Chat.UI.OutputPanel.Edge;

type
  ENoSelection = class(Exception);
  ECLINotFound = class(Exception);

  TCLIBinaryResolverFunc = reference to function: string;
  TConfigResolverFunc = reference to function: TConfig;
  TRelayPathResolverFunc = reference to function: string;
  TTempRootResolverFunc = reference to function: string;
  TWorkingDirResolverFunc = reference to function: string;

  ICommandExecutor = interface
    ['{8E2F1D5C-3B7A-4910-A6D8-2F4C9B1E8753}']
    procedure Execute(const ACommandName, ASelection: string);
    // Cancels the in-flight run (terminates the CLI process + stops the relay).
    // No-op when nothing is running. Drives the normal stream-end -> completion
    // path, so the UI returns to idle. Wired to the composer's Stop button.
    procedure Cancel;
    // Teardown-only: drops the surface reference WITHOUT releasing it (raw pointer
    // nil) so the guarded shutdown never calls into a possibly-dead surface.
    procedure ClearSurface;
    // /new | /reset: drop the CLI session continuity so the next dispatch starts a
    // brand-new --session-id (instead of --resume-ing the accumulated context).
    procedure ResetSession;
    function GetSession: string;
    // Resume: adopt the given --session-id and (when non-empty) mark the session
    // already started so the NEXT dispatch emits --resume <id>.
    procedure SetSession(const AId: string);
    // Chat|Agent header toggle. Agent = the IDE/MCP tools are pre-authorized so the
    // model acts; Chat = the tools are gated off and the model asks to switch first.
    procedure SetAgentMode(const AAgent: Boolean);
    function GetModel: string;
    // Chat header model selector: overrides Config.Model for the conversation.
    // Empty = use the configured model.
    procedure SetModel(const AModel: string);
    // Current executor kind — drives the chat selector's per-executor model list.
    function GetKind: TExecutorKind;
    // Persisted Config.Model (fresh from the resolver) — the header's fallback when
    // no per-conversation override is picked.
    function GetConfigModel: string;
    // True while a dispatched CLI run is still in flight.
    function GetIsRunning: Boolean;
    property Session: string read GetSession write SetSession;
    property Model: string read GetModel write SetModel;
    property Kind: TExecutorKind read GetKind;
    property IsRunning: Boolean read GetIsRunning;
  end;

  TCommandExecutor = class(TInterfacedObject, ICommandExecutor)
  private
    FRegistry: ICommandRegistry;
    FBuilder: IProjectContextBuilder;
    FDispatcher: ICLIDispatcher;
    FSurface: IOutputPanelSurface;
    FResolver: TCLIBinaryResolverFunc;
    FProfile: IExecutorProfile;
    FConfigResolver: TConfigResolverFunc;
    FRelayPathResolver: TRelayPathResolverFunc;
    FTempRootResolver: TTempRootResolverFunc;
    FWorkingDirResolver: TWorkingDirResolverFunc;
    FSessionId: string;
    FSessionStarted: Boolean;
    // Chat|Agent header toggle. True = Agent (IDE/MCP tools enabled, the model
    // acts); False = Chat (tools gated off, conversation only). Default Agent.
    FAgentMode: Boolean;
    FModel: string;
    // Model-fallback self-heal state. FModelRetryDone: this turn already
    // re-dispatched once after a "model not supported" failure — never retry
    // twice in one turn (reset at the START of each user-initiated Execute, so
    // a fresh turn may retry again). FSuppressModel: the picked/configured
    // model was rejected by the CLI, so dispatches emit NO --model (the CLI's
    // own default) until the user explicitly picks a model again
    // (SetModel) or resets the session.
    FModelRetryDone: Boolean;
    FSuppressModel: Boolean;
    FRunHandle: IDispatcherRunHandle;
    FPreinstalledRoots: TStringList;
    FMCPConfigPath: string;
    FMCPRunId: string;
    // The injected inputs the shared harness reads for THIS executor: a thin
    // adapter over the OTA collaborators + session/model state. Held across the
    // turn (the model-fallback retry re-enters _DispatchPrompt), replaced by the
    // next Execute. The three FDisp* fields carry the per-turn rendered context /
    // command body / selection the adapter hands to AssembleFinalPrompt.
    FHarnessInputs: IAefosCliHarnessInputs;
    FDispRendered: string;
    FDispBody: string;
    FDispSelection: string;
    procedure _EnsurePreinstalledOnce;
    procedure _CancelPrevious;
    procedure _ReportSurfaceError(const AException: Exception);
    procedure _DispatchPrompt(const AExecutorPath, APrompt: string);
    function _ResolveConfig: TConfig;
    // Resolves + provisions THIS edition's MCP wiring (merge user extras + addon
    // aggregate, provision the global config, Gemini side effect). Called by the
    // harness inputs adapter; the RAD Studio bridge/global-config path lives here
    // because it is Delphi-only (TMCPProvision's resource-backed provisioning).
    procedure _ResolveMcpWiring(const AProfileKind: TExecutorKind;
      var AWiring: TAefosCliMcpWiring);
    function _LoadStoredBody(const AText: string): string;
    function _PrepareContext(const ACommandName, ASelection: string;
      out ARendered: string; out ACommandBody: string): Boolean;
    procedure _StopMcpServer;
  public
    constructor Create(const ARegistry: ICommandRegistry;
      const ABuilder: IProjectContextBuilder;
      const ADispatcher: ICLIDispatcher;
      const ASurface: IOutputPanelSurface;
      const AResolver: TCLIBinaryResolverFunc;
      const AProfile: IExecutorProfile;
      const AConfigResolver: TConfigResolverFunc = nil;
      const AWorkingDirResolver: TWorkingDirResolverFunc = nil;
      const ARelayPathResolver: TRelayPathResolverFunc = nil;
      const ATempRootResolver: TTempRootResolverFunc = nil);
    destructor Destroy; override;
    procedure Execute(const ACommandName, ASelection: string);
    procedure Cancel;
    procedure ClearSurface;
    procedure ResetSession;
    function GetSession: string;
    procedure SetSession(const AId: string);
    procedure SetAgentMode(const AAgent: Boolean);
    function GetModel: string;
    procedure SetModel(const AModel: string);
    function GetKind: TExecutorKind;
    function GetConfigModel: string;
    function GetIsRunning: Boolean;
  end;

  // CLI-agnostic global chat settings, persisted next to the other Aefos user
  // data (%APPDATA%\Aefos\). Stateless file/JSON utilities with no coupling to a
  // TCommandExecutor instance — the "memory" standing instructions and the
  // user-managed extra MCP servers modal both load/save through here.
  TChatGlobalSettings = class sealed
  public
    // "memory": the user's global standing instructions, prepended to EVERY
    // prompt by _AssembleFinalPrompt (works regardless of which CLI runs).
    class function MemoryPath: string; static;
    class function LoadMemory: string; static;
    class procedure SaveMemory(const AText: string); static;
    // User-managed extra MCP servers (Claude Code mcp-config file,
    // {"mcpServers":{...}}) merged into the CLI session via --mcp-config
    // (ADDITIVE — never overwrites the built-in aefos MCP). McpServerNames
    // returns the configured server keys.
    class function McpConfigPath: string; static;
    class function LoadMcpConfig: string; static;
    class procedure SaveMcpConfig(const AJson: string); static;
    class function McpServerNames: TArray<string>; static;
  end;

// Teardown-only forwarding shim onto ICommandExecutor.ClearSurface. The sole
// caller is Register.pas's guarded shutdown sequence (the IDE-unload contract in
// CLAUDE.md), which must stay byte-identical, so this thin forwarder survives
// while the logic lives on the interface.
procedure ClearCommandExecutorSurface(const AExecutor: ICommandExecutor);

implementation

uses
  System.IOUtils,
  System.JSON,
  System.Generics.Collections,
  Aefos.MCP.Provision,
  Aefos.MCP.ServerMerge,
  Aefos.Provider.Registry,
  Aefos.OTA.Chat.Core.BuiltInCommands,
  Aefos.OTA.Chat.Core.ChatCommand,
  Aefos.OTA.Chat.Core.ModelFallbackPolicy,
  Aefos.OTA.Chat.UI.Options.Binding,
  Aefos.OTA.Options.AIFlow;

type
  { The RAD Studio adapter onto IAefosCliHarnessInputs -- see the note above
    TCommandExecutor._ResolveMcpWiring. Refcounted (TInterfacedObject) because the
    executor holds it as an interface; the back-pointer to the owner is a plain
    field (the owner outlives this adapter). }
  TCommandExecutorHarnessInputs = class(TInterfacedObject, IAefosCliHarnessInputs)
  private
    FOwner: TCommandExecutor;
  public
    constructor Create(const AOwner: TCommandExecutor);
    function AgentMode: Boolean;
    function Vocabulary: TAefosIdeVocabulary;
    function MemoryText: UnicodeString;
    function RenderedContext: UnicodeString;
    function CommandBody: UnicodeString;
    function Selection: UnicodeString;
    function WorkingDirectory: UnicodeString;
    function DispatchModel: UnicodeString;
    procedure ResolveMcpWiring(const AProfileKind: TExecutorKind;
      var AWiring: TAefosCliMcpWiring);
    function EnsureSessionId: UnicodeString;
    function SessionStarted: Boolean;
    function ConversationId: UnicodeString;
  end;

constructor TCommandExecutorHarnessInputs.Create(const AOwner: TCommandExecutor);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TCommandExecutorHarnessInputs.AgentMode: Boolean;
begin
  Result := FOwner.FAgentMode;
end;

function TCommandExecutorHarnessInputs.Vocabulary: TAefosIdeVocabulary;
begin
  // The RAD Studio nouns for the one shared preamble (RAD Studio/.dfm/SetDFMContent).
  Result := TAefosCliHarness.RadStudioVocabulary;
end;

function TCommandExecutorHarnessInputs.MemoryText: UnicodeString;
begin
  Result := TChatGlobalSettings.LoadMemory;
end;

function TCommandExecutorHarnessInputs.RenderedContext: UnicodeString;
begin
  Result := FOwner.FDispRendered;
end;

function TCommandExecutorHarnessInputs.CommandBody: UnicodeString;
begin
  Result := FOwner.FDispBody;
end;

function TCommandExecutorHarnessInputs.Selection: UnicodeString;
begin
  Result := FOwner.FDispSelection;
end;

function TCommandExecutorHarnessInputs.WorkingDirectory: UnicodeString;
begin
  // Run the CLI IN the active project's directory so its file/search operations
  // resolve against the project (not the IDE bin). Falls back to '' when no
  // project is active.
  Result := '';
  if Assigned(FOwner.FWorkingDirResolver) then
    Result := FOwner.FWorkingDirResolver();
end;

function TCommandExecutorHarnessInputs.DispatchModel: UnicodeString;
begin
  // The chat header's model selector overrides the persisted Config.Model for
  // this conversation (FModel = '' -> use the configured model). Under the model-
  // fallback suppression (the CLI rejected the picked/configured model) NO model
  // is sent at all, so the CLI runs on its own default. Read the config model
  // FRESH so a retry sees the current value (unchanged from _BuildArgsFromConfig).
  if FOwner.FSuppressModel then
    Result := ''
  else if FOwner.FModel <> '' then
    Result := FOwner.FModel
  else
    Result := FOwner._ResolveConfig.Model;
end;

procedure TCommandExecutorHarnessInputs.ResolveMcpWiring(
  const AProfileKind: TExecutorKind; var AWiring: TAefosCliMcpWiring);
begin
  FOwner._ResolveMcpWiring(AProfileKind, AWiring);
end;

function TCommandExecutorHarnessInputs.EnsureSessionId: UnicodeString;
begin
  if FOwner.FSessionId = '' then
    FOwner.FSessionId := TAefosCliHarness.NewSessionId;
  Result := FOwner.FSessionId;
end;

function TCommandExecutorHarnessInputs.SessionStarted: Boolean;
begin
  Result := FOwner.FSessionStarted;
end;

function TCommandExecutorHarnessInputs.ConversationId: UnicodeString;
begin
  // Which id the PROMPT may state depends on who mints it.
  //   ssPinned: ours. Minting here is safe and idempotent -- BuildDispatchRequest
  // asks for the same id moments later, so turn 1 states the id it will really
  // run under instead of a needless "not assigned yet".
  //   ssCaptured: the CLI's. Return only what a run has actually minted; on the
  // first turn '' is the honest answer. Calling EnsureSessionId here would be
  // worse than useless -- it would invent a uuid the CLI never saw, which the
  // model would then quote back to the user as fact.
  if TProviderRegistry.ResolveExecutorProfile(
       FOwner._ResolveConfig.Executor).SessionSupport = ssPinned then
    Result := EnsureSessionId
  else
    Result := FOwner.FSessionId;
end;

{ TChatGlobalSettings }

class function TChatGlobalSettings.MemoryPath: string;
begin
  // Global (all projects), next to the other Aefos user data
  // (%AppData%\Roaming\Aefos\). TPath.GetHomePath = %AppData% on Windows.
  Result := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'),
    'memory.md');
end;

class function TChatGlobalSettings.LoadMemory: string;
var
  LPath: string;
begin
  Result := '';
  LPath := MemoryPath;
  if not TFile.Exists(LPath) then
    Exit;
  try
    Result := Trim(TFile.ReadAllText(LPath, TEncoding.UTF8));
  except
    // A locked/garbled memory file must never break a dispatch.
    Result := '';
  end;
end;

class procedure TChatGlobalSettings.SaveMemory(const AText: string);
var
  LPath: string;
begin
  LPath := MemoryPath;
  TDirectory.CreateDirectory(TPath.GetDirectoryName(LPath));
  TFile.WriteAllText(LPath, AText, TEncoding.UTF8);
end;

class function TChatGlobalSettings.McpConfigPath: string;
begin
  Result := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'),
    'mcp-servers.json');
end;

class function TChatGlobalSettings.LoadMcpConfig: string;
var
  LPath: string;
begin
  Result := '{}';
  LPath := McpConfigPath;
  if not TFile.Exists(LPath) then
    Exit;
  try
    Result := Trim(TFile.ReadAllText(LPath, TEncoding.UTF8));
    if Result = '' then
      Result := '{}';
  except
    // A locked/garbled config must never break a dispatch nor the modal.
    Result := '{}';
  end;
end;

class procedure TChatGlobalSettings.SaveMcpConfig(const AJson: string);
var
  LPath: string;
begin
  LPath := McpConfigPath;
  TDirectory.CreateDirectory(TPath.GetDirectoryName(LPath));
  TFile.WriteAllText(LPath, AJson, TEncoding.UTF8);
end;

class function TChatGlobalSettings.McpServerNames: TArray<string>;
var
  LVal: TJSONValue;
  LRoot: TJSONObject;
  LServers: TJSONValue;
  LI: Integer;
  LList: TArray<string>;
begin
  Result := nil;
  LList := nil;
  LVal := TJSONObject.ParseJSONValue(LoadMcpConfig);
  if not (LVal is TJSONObject) then
  begin
    LVal.Free; // nil-safe; Free on nil is a no-op
    Exit;
  end;
  LRoot := TJSONObject(LVal);
  try
    LServers := LRoot.GetValue('mcpServers');
    if LServers is TJSONObject then
      for LI := 0 to TJSONObject(LServers).Count - 1 do
        LList := LList + [TJSONObject(LServers).Pairs[LI].JsonString.Value];
  finally
    LRoot.Free;
  end;
  Result := LList;
end;

procedure ClearCommandExecutorSurface(const AExecutor: ICommandExecutor);
begin
  if Assigned(AExecutor) then
    AExecutor.ClearSurface;
end;

{ TCommandExecutor accessors (session/model/agent state, on the interface so no
  hard-cast into the concrete class is needed). }

procedure TCommandExecutor.ClearSurface;
begin
  // Teardown: drop the surface WITHOUT releasing it (raw pointer nil), so the
  // guarded shutdown never calls into a possibly-dead surface.
  Pointer(FSurface) := nil;
end;

function TCommandExecutor.GetIsRunning: Boolean;
begin
  Result := Assigned(FRunHandle) and FRunHandle.IsRunning;
end;

procedure TCommandExecutor.ResetSession;
begin
  // /new | /reset: drop the CLI session continuity so the next dispatch starts a
  // brand-new --session-id (instead of --resume-ing the accumulated context).
  FSessionId := '';
  FSessionStarted := False;
  // A fresh conversation also drops the model-fallback suppression.
  FSuppressModel := False;
end;

function TCommandExecutor.GetSession: string;
begin
  Result := FSessionId;
end;

procedure TCommandExecutor.SetSession(const AId: string);
begin
  // Resume: adopt the given --session-id and (when non-empty) mark the session
  // already started so the NEXT dispatch emits --resume <id> instead of
  // --session-id <id>. An empty id is equivalent to a reset (no continuity).
  FSessionId := AId;
  FSessionStarted := (AId <> '');
end;

procedure TCommandExecutor.SetAgentMode(const AAgent: Boolean);
begin
  // Chat|Agent toggle from the HTML header. Agent = tools on (the model acts on
  // the IDE); Chat = tools gated off + a "switch to Agent to act" instruction.
  FAgentMode := AAgent;
end;

procedure TCommandExecutor.SetModel(const AModel: string);
begin
  FModel := AModel;
  // An explicit pick (or an explicit "use default") ends the model-fallback
  // suppression — the user's choice always wins over the self-heal.
  FSuppressModel := False;
end;

function TCommandExecutor.GetModel: string;
begin
  Result := FModel;
end;

function TCommandExecutor.GetKind: TExecutorKind;
begin
  // Read from the CONFIG (not the cached FProfile) so the chat reflects an
  // executor change made in Options without a restart — the header re-feeds on
  // focus and picks up the new provider.
  Result := ekClaude;
  if Assigned(FConfigResolver) then
    Result := FConfigResolver().Executor;
end;

function TCommandExecutor.GetConfigModel: string;
begin
  // The persisted Config.Model (fresh) — shown in the header when there's no
  // per-conversation override picked yet.
  Result := '';
  if Assigned(FConfigResolver) then
    Result := FConfigResolver().Model;
end;

constructor TCommandExecutor.Create(const ARegistry: ICommandRegistry;
  const ABuilder: IProjectContextBuilder;
  const ADispatcher: ICLIDispatcher;
  const ASurface: IOutputPanelSurface;
  const AResolver: TCLIBinaryResolverFunc;
  const AProfile: IExecutorProfile;
  const AConfigResolver: TConfigResolverFunc = nil;
  const AWorkingDirResolver: TWorkingDirResolverFunc = nil;
  const ARelayPathResolver: TRelayPathResolverFunc = nil;
  const ATempRootResolver: TTempRootResolverFunc = nil);
begin
  inherited Create;
  // Default to Agent mode (IDE/MCP tools on) — the header toggle starts on Agent.
  FAgentMode := True;
  if not Assigned(ARegistry) then
    raise EArgumentNilException.Create('TCommandExecutor: ARegistry');
  if not Assigned(ABuilder) then
    raise EArgumentNilException.Create('TCommandExecutor: ABuilder');
  if not Assigned(ADispatcher) then
    raise EArgumentNilException.Create('TCommandExecutor: ADispatcher');
  if not Assigned(ASurface) then
    raise EArgumentNilException.Create('TCommandExecutor: ASurface');
  if not Assigned(AResolver) then
    raise EArgumentNilException.Create('TCommandExecutor: AResolver');
  if not Assigned(AProfile) then
    raise EArgumentNilException.Create('TCommandExecutor: AProfile');
  FRegistry := ARegistry;
  FBuilder := ABuilder;
  FDispatcher := ADispatcher;
  FSurface := ASurface;
  FResolver := AResolver;
  FProfile := AProfile;
  FConfigResolver := AConfigResolver;
  FWorkingDirResolver := AWorkingDirResolver;
  FRelayPathResolver := ARelayPathResolver;
  FTempRootResolver := ATempRootResolver;
  FPreinstalledRoots := TStringList.Create;
  FPreinstalledRoots.CaseSensitive := False;
  FPreinstalledRoots.Sorted := True;
  FPreinstalledRoots.Duplicates := dupIgnore;
end;

destructor TCommandExecutor.Destroy;
begin
  _CancelPrevious;
  _StopMcpServer;
  FPreinstalledRoots.Free;
  inherited;
end;

{ TCommandExecutorHarnessInputs -- the RAD Studio adapter onto
  IAefosCliHarnessInputs. It is the thin OTA glue that FEEDS the shared harness:
  the final-prompt text and the dispatch-request assembly now live ONCE in
  Aefos.Chat.Core.CliHarness; this only surfaces THIS executor's per-turn context
  (FDisp*), its config/model/session state and its Delphi-only MCP provisioning.
  It holds a plain (non-refcounted) back-pointer to its owner, which always
  outlives it (the owner holds the interface ref). }
procedure TCommandExecutor._ResolveMcpWiring(const AProfileKind: TExecutorKind;
  var AWiring: TAefosCliMcpWiring);
var
  LMergedMcp: string;
begin
  // The RAD Studio bridge/global-config MCP wiring (was inside
  // _BuildArgsFromConfig). ONE global config (%APPDATA%\Aefos\aefos-mcp.json =
  // the built-in aefos + the user's extra servers + the installed addons'
  // servers) that every CLI is pointed at; the bridge path feeds Codex's -c
  // override; the session is the named-pipe the chat host serves.
  //
  // FASE 0 (Desktop MCP): merge the user's extras with the addon aggregate that
  // `aefos install` writes to ~/.aefos/addons/mcp-servers.json BEFORE provisioning
  // -- without this an installed MCP addon (Desktop, Janus-DB, ...) never reaches
  // the agent. On a name collision the USER's hand-written server wins over the
  // addon's (see Aefos.MCP.ServerMerge). A missing/unreadable aggregate degrades
  // to the user's config alone.
  LMergedMcp := TMCPServerMerge.MergeServers(TChatGlobalSettings.LoadMcpConfig,
    TMCPProvision.LoadAddonAggregate);
  AWiring.McpConfigPath := TMCPProvision.EnsureGlobalConfig('plugin', LMergedMcp);
  AWiring.McpBridgePath := TMCPProvision.BridgePath;
  AWiring.McpSession := 'plugin';
  // The built-in host's server KEY (the tool namespace mcp__<name>), distinct
  // from the Lazarus edition's 'aefos-lazarus' so both IDEs stay addressable when
  // open together (owner decision 2026-07-18).
  AWiring.McpServerName := TMCPProvision.BuiltInServerKey;
  // Pre-authorize the MERGED set's tools (Claude gates mcp__<name> behind
  // --allowedTools) so addon MCP tools are usable, not merely declared.
  AWiring.ExtraMcpNames := TMCPServerMerge.ServerKeysOf(LMergedMcp);
  // The RAD Studio edition always provides the wiring; the driver gates its MCP
  // flags on ctx.AgentMode, which the header toggle drives.
  AWiring.AgentToolingActive := FAgentMode;
  // The user's ONE tool-permission choice, from Tools > Options > Aefos > AI Flow.
  AWiring.AllowNativeTools := TAIFlowOptions.AgentNativeTools;
  // Gemini has no MCP flag -- it reads ~/.gemini/settings.json. Provision the
  // aefos server there (agent mode only) so the driver's
  // --allowed-mcp-server-names aefos resolves. File provisioning can't live in
  // the leaf driver, so this CLI-specific side effect stays here.
  if (AProfileKind = ekGemini) and FAgentMode then
    TMCPProvision.EnsureGeminiConfig(AWiring.McpSession);
end;

procedure TCommandExecutor._EnsurePreinstalledOnce;
var
  LRootKey: string;
begin
  // Memoise per project-root signature. The registry's resolver is the
  // authority on "what root am I in"; we tag the call with EnsurePreinstalled
  // and cache by the resolver's result via the builder's project context. To
  // avoid a second OTA call here we use the registry call itself as the
  // first-call gate — no key needed, just a sentinel "any root" marker.
  LRootKey := '*'; // single executor instance, single bootstrap.
  if FPreinstalledRoots.IndexOf(LRootKey) >= 0 then
    Exit;
  FRegistry.EnsurePreinstalled;
  FPreinstalledRoots.Add(LRootKey);
end;

procedure TCommandExecutor._CancelPrevious;
begin
  if Assigned(FRunHandle) then
  begin
    if FRunHandle.IsRunning then
      FRunHandle.Cancel;
    FRunHandle := nil;
  end;
  _StopMcpServer;
end;

procedure TCommandExecutor.Cancel;
begin
  // Public stop entry point (composer Stop button). Reuses the same teardown
  // the next run would do: terminate the CLI process + stop the relay. The
  // terminated process closes its pipes -> the read thread hits EOF -> the
  // stream-end/completion path fires, returning the surface to idle.
  _CancelPrevious;
end;

procedure TCommandExecutor._StopMcpServer;
var
  LPath: string;
begin
  // The in-process MCP server path was removed (ESP cleanup): this now only
  // tears down the per-run .mcp.json relay config the CLI loaded.
  LPath := FMCPConfigPath;
  FMCPConfigPath := '';
  FMCPRunId := '';
  if (LPath <> '') and TFile.Exists(LPath) then
  begin
    try
      TFile.Delete(LPath);
    except
      // Per ADR-059, failure to delete is logged-but-not-fatal.
    end;
  end;
end;

procedure TCommandExecutor._ReportSurfaceError(const AException: Exception);
begin
  FSurface.Show;
  FSurface.ReportError(AException);
end;

function TCommandExecutor._ResolveConfig: TConfig;
begin
  // Fetch the resolved config once per dispatch; with no resolver wired the
  // defaults apply (TimeoutSeconds=0, ofpStrip) so behaviour is unchanged.
  if Assigned(FConfigResolver) then
    Result := FConfigResolver()
  else
    Result := DefaultConfig;
end;

procedure TCommandExecutor._DispatchPrompt(const AExecutorPath,
  APrompt: string);
var
  LRequest: TDispatchRequest;
  LConfig: TConfig;
  LProfile: IExecutorProfile;
  LSurface: IOutputPanelSurface;
  LExecutor: TCommandExecutor;
  LSelfRef: ICommandExecutor;
  LDispatched: Boolean;
  LPath: string;
  LPrompt: string;
  LHadModel: Boolean;
  LAccumulated: string;
  LExample: string;
  LSuggested: TArray<string>;
begin
  LConfig := _ResolveConfig;
  // Executor-aware example slug for a "model rejected" / quota hint below, so the
  // advice suggests a model of the ACTIVE executor (not a Gemini id for Codex).
  LExample := '';
  LSuggested := TExecutorModels.SuggestedModels(LConfig.Executor);
  if Length(LSuggested) > 0 then
    LExample := LSuggested[0];
  // Model-fallback self-heal captures: the SAME prompt is re-dispatched once if
  // the CLI rejects the model, so copy the (const) params into capturable
  // locals. LHadModel: a --model was actually emitted this dispatch — without
  // one there is nothing to fall back FROM. LAccumulated collects the run's
  // stdout+stderr text (chunks arrive on the main thread via TThread.Queue, so
  // plain string appends are safe) for the failure probe; it is only READ on a
  // non-zero exit, so the success path pays nothing beyond the appends.
  LPath := AExecutorPath;
  LPrompt := APrompt;
  LHadModel := (not FSuppressModel) and
    ((FModel <> '') or (LConfig.Model <> ''));
  LAccumulated := '';
  // Resolve the driver from the FRESH config executor (FProfile can lag after an
  // Options switch, which once sent Claude's --allowedTools to copilot.exe), then
  // DELEGATE the whole request assembly (prompt + args + env + session + timeout +
  // filter) to the SHARED harness. The per-CLI flag dialect stays in the driver;
  // the orchestration rule stays in TAefosCliHarness -- this executor keeps none.
  LProfile := TProviderRegistry.ResolveExecutorProfile(LConfig.Executor);
  LRequest := TAefosCliHarness.BuildDispatchRequest(FHarnessInputs, LConfig,
    LProfile, AExecutorPath, APrompt);
  LSurface := FSurface;
  LSelfRef := Self;
  LExecutor := Self;
  LDispatched := False;
  try
    FRunHandle := FDispatcher.Dispatch(
      LRequest,
      procedure(const AChunk: string)
      begin
        LAccumulated := LAccumulated + AChunk;
        LSurface.AppendChunk(AChunk, stStdout);
      end,
      procedure(const AExitCode: Integer; const ADurationMs: Cardinal)
      var
        LHint: string;
        LCapturedId: string;
        LRawErr: string;
      begin
        // Conversation continuity for the CLIs that MINT their own id (Codex,
        // the local agent CLI): the id does not exist until the run printed it,
        // so it is scraped HERE, at completion, out of the accumulated
        // stdout+stderr. Captured exactly ONCE per conversation -- a resumed run
        // reprints the same id, so re-reading it every turn would only add a
        // chance to overwrite a good id with a bad parse.
        //   Deliberately NOT gated on AExitCode = 0: a turn that timed out or
        // died mid-answer still created (and, for the agent CLI, still SAVED)
        // the conversation, and dropping the id there would silently restart the
        // history on the next message -- the exact failure this whole change
        // exists to kill.
        //   LAccumulated alone was NOT enough, and that is what broke this in
        // the field. stderr only reaches the error callback when the process
        // FAILED (CLIDispatcher._BuildErrorText) -- deliberately, so CLI chatter
        // is not rendered as an error on a good turn. But Codex prints its
        // `session id:` header to stderr on EVERY run, so on a successful turn
        // the id was discarded before anything could read it, SessionStarted
        // never went True, and every message started a brand-new session. The
        // agent kept answering with no memory of the previous one -- "o contexto
        // que recebi nao contem a mensagem anterior", verbatim, in the panel.
        //   Reading the handle's raw stderr fixes it without changing what the
        // PANEL shows: errors stay errors, and the scrape sees the header.
        LRawErr := '';
        if Assigned(LExecutor.FRunHandle) then
          LRawErr := LExecutor.FRunHandle.StderrText;
        if Assigned(LSelfRef) and (LExecutor.FSessionId = '') and
           (LProfile.SessionSupport = ssCaptured) and
           LProfile.TryCaptureSessionId(LAccumulated + LRawErr, LCapturedId) then
        begin
          LExecutor.FSessionId := LCapturedId;
          LExecutor.FSessionStarted := True;
        end;
        // Model-fallback self-heal: the run failed AND its output says the
        // picked model is not supported by this CLI/account (retired slug,
        // wrong account tier, ...). Re-dispatch the SAME prompt exactly ONCE
        // with no --model at all, so the CLI runs on its own default.
        // FModelRetryDone guards the loop (one retry per turn); a failing
        // retry falls through to the normal completion below. Dispatcher
        // callbacks fire error-then-complete on the main thread, so
        // LAccumulated already holds the stderr text here.
        if (AExitCode <> 0) and LHadModel and Assigned(LSelfRef) and
           (not LExecutor.FModelRetryDone) and
           ModelNotSupported(LAccumulated) then
        begin
          LExecutor.FModelRetryDone := True;
          // Drop the dead model for the rest of the conversation: clear the
          // per-conversation override AND suppress the configured model, so
          // this retry (and the next turns) emit NO --model until the user
          // explicitly picks a model again.
          LExecutor.FModel := '';
          LExecutor.FSuppressModel := True;
          LSurface.AppendChunk(
            'The selected model was rejected by the CLI; retrying with its ' +
            'default model.' + sLineBreak, stStderr);
          try
            LExecutor._DispatchPrompt(LPath, LPrompt);
            // The retry run reports its own completion.
            Exit;
          except
            // The retry could not even be dispatched — surface it and let the
            // ORIGINAL completion below close the run normally.
            on E: Exception do
              LExecutor._ReportSurfaceError(E);
          end;
        end;
        // Turn a cryptic provider failure (a 400 "[object Object]", a 429 quota
        // wall, a dead OAuth login) into one actionable English line above the
        // raw CLI dump, so a failed run reads clearly instead of scaring the
        // user with a stack trace. Empty when the failure isn't recognised.
        if AExitCode <> 0 then
        begin
          LHint := ClassifyCliFailure(LAccumulated, LExample);
          if LHint <> '' then
            LSurface.AppendChunk('Aefos: ' + LHint + sLineBreak, stStderr);
        end;
        LSurface.ReportComplete(AExitCode);
        if Assigned(LSelfRef) then
          LExecutor._StopMcpServer;
      end,
      procedure(const AMessage: string)
      begin
        LAccumulated := LAccumulated + AMessage;
        LSurface.AppendChunk(AMessage, stStderr);
      end);
    LDispatched := True;
    // A PINNED session counts as started only once the CLI actually SPAWNED.
    // Dispatch raises on spawn failure, so reaching this line is the proof.
    // Marking it earlier (which is what this did) meant a turn that never
    // launched still flipped the flag, and the NEXT turn resumed an id no CLI
    // had ever seen -- Claude answers that with "No conversation found with
    // session ID: ..." and exit 0, so the error lands in the chat looking
    // exactly like a normal model reply. Captured sessions mark themselves in
    // the completion callback above, where their id is born.
    if LProfile.SessionSupport = ssPinned then
      FSessionStarted := True;
  finally
    if not LDispatched then
      _StopMcpServer;
  end;
end;

// Loads a stored command's body, accepting "<name> <what the developer wants>".
//
// The slash is the whole signal, and it is why the panel now dispatches the text
// AS TYPED. "/release these notes" is the command plus a request; "release these
// notes" is a sentence that happens to start with the name of an installed
// command. Without the slash the two are the same string, and the only safe
// reading of an identical pair is the literal one.
//
// Same shape the built-ins have always had (FindBuiltInCommand splits on the
// first space) - stored and addon commands simply never got it, so anything
// typed after the name reached the model as raw text with the COMMAND.md never
// loaded. Measured live on /analyst.
function TCommandExecutor._LoadStoredBody(const AText: string): string;
var
  LText, LName, LArgs: string;
  LSpace: Integer;
begin
  LText := Trim(AText);
  if not LText.StartsWith('/') then
    // No slash: the caller means this exact name (the picker's path) or it is
    // free text. Unchanged behaviour - LoadBody raises and the caller falls back.
    Exit(FRegistry.LoadBody(LText));
  LText := Trim(Copy(LText, 2, MaxInt));
  LArgs := '';
  LSpace := Pos(' ', LText);
  if LSpace > 0 then
  begin
    LArgs := Trim(Copy(LText, LSpace + 1, MaxInt));
    LName := Copy(LText, 1, LSpace - 1);
  end
  else
    LName := LText;
  Result := FRegistry.LoadBody(LName);
  if LArgs <> '' then
    Result := Result + sLineBreak + sLineBreak +
      'The developer''s initial request: ' + LArgs;
end;

function TCommandExecutor._PrepareContext(const ACommandName, ASelection: string;
  out ARendered: string; out ACommandBody: string): Boolean;
var
  LContext: TProjectContext;
  LLastRoot: string;
  LUserText: string;
  LBuiltin: TBuiltInCommand;
  LBare: string;
begin
  Result := False;
  // The panel dispatches the text AS TYPED so the slash survives to
  // _LoadStoredBody, which is the only thing that needs it. Everything else here
  // wants the bare text: the built-in table matches on names without one, and
  // the free-chat fallback must not echo a slash the user's prompt did not mean
  // as a command.
  LBare := StripLeadingSlash(Trim(ACommandName));
  try
    // No active project (e.g. the agent just closed them all) must NOT abort the
    // dispatch — the chat should still converse/act. Degrade each project-bound
    // step gracefully instead of surfacing a raw exception.
    try
      _EnsurePreinstalledOnce;
    except
      on ECommandFolderUnavailable do
        ; // no project/commands folder yet — nothing to preinstall, carry on
    end;
    try
      if FindBuiltInCommand(LBare, LBuiltin, LUserText) and
         (LBuiltin.Kind = bikAgentic) then
      begin
        // Built-in agentic command (e.g. /new-project): inject its prompt-guide
        // as the body so the agent drives the flow with the MCP tools. The
        // registry (Core.BuiltInCommands) is the single source — no name is
        // hardcoded here.
        ACommandBody := LBuiltin.Guide;
        if LUserText <> '' then
          ACommandBody := ACommandBody + sLineBreak + sLineBreak +
            'The developer''s initial request: ' + LUserText;
      end
      else
        ACommandBody := _LoadStoredBody(ACommandName);
    except
      // Free-form chat fallback: ANY failure to load a command body means the typed
      // text isn't a command, so treat the text itself as the prompt and let the
      // CLI handle it. Covers ECommandNotFound (no such command), ECommandFolderUnavailable
      // (no project yet) AND EInOutArgumentException — the text has filename-invalid
      // chars (?, :, ...), e.g. a pasted/attached file path, so the command-path build
      // threw. A plain message or a path then goes straight to the CLI instead of
      // crashing with "Invalid characters in path".
      on Exception do
        ACommandBody := LBare;
    end;
    try
      LContext := FBuilder.Build(ASelection);
      ARendered := FBuilder.Render(LContext);
    except
      on EProjectContextError do
      begin
        // No active project: dispatch with an explicit "no project" context plus
        // the LAST known project folder (the working-dir resolver falls back to
        // it), so the model can (re)open the .dproj there via the file/OpenFile
        // tools instead of aborting with a raw error.
        LLastRoot := '';
        if Assigned(FWorkingDirResolver) then
          LLastRoot := FWorkingDirResolver();
        ARendered := '## Project context' + sLineBreak + sLineBreak +
          'No Delphi project is currently open.';
        if LLastRoot <> '' then
          ARendered := ARendered + ' The last project folder was: ' + LLastRoot +
            ' — if the user asks to reopen, PREFER opening the project group file' +
            ' (.groupproj) found there, which restores ALL projects of the group;' +
            ' fall back to a single .dproj only if there is no .groupproj.';
      end;
    end;
    Result := True;
  except
    on E: Exception do
      _ReportSurfaceError(E);
  end;
end;

procedure TCommandExecutor.Execute(const ACommandName, ASelection: string);
var
  LCommandBody: string;
  LRendered: string;
  LFinalPrompt: string;
  LExecutorPath: string;
begin
  _CancelPrevious;
  // Fresh user-initiated turn: the model-fallback retry is armed again (one
  // retry per turn, never two within the same turn).
  FModelRetryDone := False;
  FSurface.Show;
  FSurface.Clear;
  if not _PrepareContext(ACommandName, ASelection, LRendered, LCommandBody) then
    Exit;
  LExecutorPath := FResolver();
  if LExecutorPath = '' then
  begin
    // Vendor-neutral: Aefos is CLI-agnostic and never names a specific CLI in the
    // UI. Point the user at the settings page where they choose their CLI + path.
    _ReportSurfaceError(ECLINotFound.Create(
      'No AI CLI was found. Open Tools > Options > Aefos > AI Chat and set the ' +
      'Executor (its path), or put your AI CLI on PATH.'));
    Exit;
  end;
  // Publish this turn's context to the harness inputs adapter and DELEGATE the
  // final-prompt assembly to the shared harness (the ONE owner of that text).
  // The adapter is held for the whole turn because the model-fallback retry
  // re-enters _DispatchPrompt, which re-reads it to rebuild the request.
  FDispRendered := LRendered;
  FDispBody := LCommandBody;
  FDispSelection := ASelection;
  FHarnessInputs := TCommandExecutorHarnessInputs.Create(Self);
  LFinalPrompt := TAefosCliHarness.AssembleFinalPrompt(FHarnessInputs);
  try
    _DispatchPrompt(LExecutorPath, LFinalPrompt);
  except
    on E: Exception do
      _ReportSurfaceError(E);
  end;
end;

end.
