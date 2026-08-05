unit Aefos.OTA.Chat.Register;

{
  Composition root for the Aefos OTA plugin.

  Demand 5/5 closes the Phase 1 MVP wave by adding the command replicator
  to the wiring graph. Init order:
    notifier → dispatcher → command registry → context builder
            → output panel → command replicator → command executor
            → main menu → AgentSuggest binding.
  Shutdown reverses the order — replicator finalised after executor
  (AC-013).

  The active-project resolver lambdas are the only places that touch OTA
  in this composition root. The Core.* and UI.OutputPanel.* units stay
  OTA-free for testability.
}

interface

procedure Register;

implementation

uses
  Winapi.Windows,
  Winapi.ShellAPI,
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.Variants,
  System.NetEncoding,
  Vcl.Forms,
  Vcl.Menus,
  ToolsAPI,
  DockForm,
  Aefos.OTA.Chat.Core.MainMenu,
  Aefos.OTA.Chat.Core.CLIDispatcher,
  Aefos.OTA.Chat.Core.CommandRegistry.Types,
  Aefos.OTA.Chat.Core.CommandRegistry,
  Aefos.OTA.Chat.Core.ProjectContextBuilder.Types,
  Aefos.OTA.Chat.Core.ProjectContextBuilder,
  Aefos.OTA.Chat.Core.CLIBinaryResolver,
  Aefos.MCP.Provision,
  Aefos.OTA.Chat.Core.Config.Types,
  Aefos.OTA.Chat.Core.Config,
  Aefos.MCP.Types,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.Server,
  Aefos.MCP.AddonGateway,
  Aefos.Chat.Core.VisualBroadcast,
  Aefos.Chat.Core.VisualReporter,
  Aefos.MCP.AuditLog,
  Aefos.MCP.InspectorBridge,
  Aefos.OTA.UI.MCPToolInspector,
  Aefos.MCP.Tools,
  Aefos.MCP.Tools.Project,
  Aefos.MCP.Tools.Units,
  Aefos.MCP.Tools.Editor,
  Aefos.MCP.Tools.Build,
  Aefos.MCP.Tools.Debug,
  Aefos.MCP.Tools.FormsDFM,
  Aefos.MCP.Tools.DPR,
  Aefos.MCP.Tools.CodeInsight,
  Aefos.MCP.Tools.ProjectGroup,
  Aefos.MCP.Tools.Packages,
  Aefos.MCP.Tools.IDE,
  Aefos.MCP.Tools.Resources,
  Aefos.MCP.GitFacade,
  Aefos.MCP.Tools.Git,
  Aefos.MCP.Tools.VCS,
  Aefos.MCP.Tools.Rename,
  Aefos.MCP.Tools.AuditQuery,
  Aefos.MCP.ChatInspector.Types,
  Aefos.MCP.Tools.ChatInspector,
  Aefos.MCP.Tools.PyTools,
  Aefos.MCP.Tools.ProjectText,
  Aefos.MCP.Tools.Scaffold,
  System.JSON,
  Aefos.Tools.Project,
  Aefos.Tools.Templates,
  Aefos.Tools.Files,
  Aefos.OTA.IDE.GutterReview,
  Aefos.OTA.MCP.IssueReport,
  Aefos.OTA.MCP.PyToolsManager,
  Aefos.MCP.DFMParser,
  Aefos.MCP.DPRParser,
  Aefos.MCP.PasParser,
  Aefos.MCP.BuildManager,
  Aefos.MCP.Resources,
  Aefos.MCP.ReAnchor,
  Aefos.MCP.Transport.NamedPipe,
  Aefos.MCP.Transport.Http,
  // Facade unification (Passo 3): the single shared IMCPWorkspaceFacade impl
  // now lives in the Aefos.MCP.Tools.OTA runtime BPL (requires above).
  // The Chat composition root instantiates it instead of the legacy local
  // TOTAFacade, so both the Chat and Terminal BPLs serve MCP from one facade.
  Aefos.MCP.OTA.WorkspaceFacade,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ConsentService, // SetGlobalConsentPresenter moved here (SOLID split)
  Aefos.OTA.Chat.Core.CommandReplicator.Types,
  Aefos.OTA.Chat.Core.CommandReplicator,
  Aefos.OTA.Chat.Core.CommandExecutor,
  Aefos.Provider.Types,
  Aefos.Provider.Registry,
  Aefos.OTA.Chat.UI.Options.Binding,
  Aefos.OTA.Chat.Adapter.IDENotifier,
  Aefos.OTA.Chat.Adapter.DebuggerNotifier,
  Aefos.License.Gate,
  Aefos.OTA.Chat.Adapter.MainMenu,
  Aefos.OTA.Chat.Adapter.AgentSuggest,
  Aefos.OTA.InlineGhost,
  Aefos.OTA.Chat.UI.OutputPanel.Edge,
  Aefos.OTA.Chat.UI.ChatInspectorFacade,
  Aefos.OTA.Chat.UI.ChatPanel,
  Aefos.OTA.Chat.UI.Options.Registration,
  Aefos.OTA.Options.AIFlow,
  Aefos.OTA.Chat.UI.AboutForm,
  Aefos.OTA.Chat.UI.Branding,
  // ONE consent modal for both hosts. There used to be a chat-local copy of
  // this form; it drifted from the one the consent service actually shows.
  Aefos.OTA.UI.MCPConsentDialog,
  Aefos.OTA.Chat.UI.ConsentWebForm,
  Aefos.MCP.ConsentView,
  Aefos.OTA.Chat.Core.CommandPalette.Types,
  Aefos.OTA.Chat.Core.CommandPalette,
  Aefos.OTA.Chat.Core.CommandPalette.Actions,
  Aefos.OTA.Chat.Core.PaletteState.Types,
  Aefos.OTA.Chat.Core.PaletteState,
  Vcl.ExtCtrls,
  Vcl.ActnList,
  System.Actions,
  Vcl.Dialogs,
  Xml.XMLDoc,
  Xml.XMLIntf;

const
  // ESP-002 Epic 2/4 Demand 2/3 (ADR-275): onboarding detection targets the
  // Claude Code MVP binary through the shared ResolveCLIBinary ladder. The
  // evaluator stays executor-agnostic (consumes a resolved path + kind), so
  // Codex detection slots in later without touching it.
  ONBOARDING_CLI_BINARY_NAME = 'claude';

var
  GCLIDispatcher: ICLIDispatcher;
  GCommandRegistry: ICommandRegistry;
  GContextBuilder: IProjectContextBuilder;
  GOutputPanel: IOutputPanelSurface;
  GConfig: IConfig;
  GExecutorProfile: IExecutorProfile;
  GCommandReplicator: ICommandReplicator;
  GCommandExecutor: ICommandExecutor;
  GCommandPalette: ICommandPalette;
  // Persistent MCP server for the 'dev' session (this Claude Code terminal).
  // Lives on a named pipe so the mcp-bridge.ps1 (-Session dev) can connect
  // from outside the IDE.
  GDevSessionServer: IMCPServer;
  GLastResolvedProjectRoot: string = '';

// ADR-083/084/085: re-runnable, guarded composition of the
// config-and-executor graph. Forward-declared so callers earlier in the unit
// can trigger it; implemented before Register.
procedure _ResolveExecutorGraph; forward;

var
  // Last non-empty active-project root (see _ResolveActiveProjectRoot).
  GLastProjectRoot: string = '';

function _ResolveActiveProjectRoot: string;
var
  LModuleServices: IOTAModuleServices;
  LProject: IOTAProject;
begin
  Result := '';
  try
    if Assigned(BorlandIDEServices)
      and Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    begin
      LProject := LModuleServices.GetActiveProject;
      if Assigned(LProject) then
        Result := TPath.GetDirectoryName(LProject.FileName);
    end;
  except
    Result := '';
  end;
  // No active project (e.g. the agent just closed them all): fall back to the
  // last root we saw so the commands folder, config and the claude cwd (which
  // resolves .mcp.json -> the MCP tools) stay available. Without this, closing
  // every project disconnects the agent from its own tools and the command layer
  // raises ECommandFolderUnavailable. The in-process MCP server is project-
  // agnostic, so the agent still operates on the live IDE and can reopen.
  if Result <> '' then
    GLastProjectRoot := Result
  else
    Result := GLastProjectRoot;
end;

// The executor/runtime settings (config.json: which CLI, its path, model, timeout,
// output filter, inspector) are MACHINE-GLOBAL, not per-project — the CLI binary and
// login are the same regardless of which project is open. They live under
// %APPDATA%\Aefos so the Options page is editable even on the Welcome page with no
// project (install-feedback #1). Genuinely per-project things — command registry /
// replication, project context — keep _ResolveActiveProjectRoot.
function _ResolveGlobalConfigRoot: string;
begin
  Result := TPath.Combine(TPath.GetHomePath, 'Aefos');
end;

procedure _InitDispatcher;
begin
  GCLIDispatcher := TCLIDispatcher.Create;
end;

procedure _ShutdownDispatcher;
begin
  GCLIDispatcher := nil;
end;

procedure _InitCommandRegistry;
begin
  GCommandRegistry := TCommandRegistry.Create(
    function: string
    begin
      Result := _ResolveActiveProjectRoot;
    end);
end;

procedure _ShutdownCommandRegistry;
begin
  GCommandRegistry := nil;
end;

function _TryGetActiveProject(out AProject: IOTAProject): Boolean;
var
  LModuleServices: IOTAModuleServices;
begin
  AProject := nil;
  Result := False;
  if not Assigned(BorlandIDEServices) then
    Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  AProject := LModuleServices.GetActiveProject;
  Result := Assigned(AProject);
end;

function _TryGetActiveBuffer(out ABuffer: IOTAEditBuffer): Boolean;
var
  LEditorServices: IOTAEditorServices;
  LView: IOTAEditView;
begin
  ABuffer := nil;
  Result := False;
  if not Assigned(BorlandIDEServices) then
    Exit;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
    Exit;
  LView := LEditorServices.TopView;
  if not Assigned(LView) then
    Exit;
  ABuffer := LView.Buffer;
  Result := Assigned(ABuffer);
end;

// Returns True when any source editor buffer in AModule has unsaved changes.
// IOTAModule does not expose IsModified directly; the flag lives on IOTAEditBuffer60.
function _IsModuleModified(const AModule: IOTAModule): Boolean;
var
  LIdx: Integer;
  LEditor: IOTAEditor;
  LBuffer: IOTAEditBuffer;
begin
  Result := False;
  for LIdx := 0 to AModule.GetModuleFileCount - 1 do
  begin
    LEditor := AModule.GetModuleFileEditor(LIdx);
    if Supports(LEditor, IOTAEditBuffer, LBuffer) then
      if LBuffer.IsModified then
        Exit(True);
  end;
end;

procedure _FillEditorFields(const ABuffer: IOTAEditBuffer; var AInfo: TActiveProjectInfo);
var
  LReader: IOTAEditReader;
  LBytes: TBytes;
  LSize: Integer;
begin
  AInfo.ActiveUnitName := TPath.GetFileName(ABuffer.FileName);
  LReader := ABuffer.CreateReader;
  if not Assigned(LReader) then
    Exit;
  SetLength(LBytes, 64 * 1024);
  LSize := LReader.GetText(0, PAnsiChar(@LBytes[0]), Length(LBytes));
  AInfo.ActiveUnitBody := DecodeUnitBodyBytes(LBytes, LSize);
end;

function _ResolveActiveProjectInfo: TActiveProjectInfo;
var
  LProject: IOTAProject;
  LBuffer: IOTAEditBuffer;
begin
  Result := Default(TActiveProjectInfo);
  try
    if not Assigned(BorlandIDEServices) then
      Exit;
    if _TryGetActiveProject(LProject) then
    begin
      Result.ProjectFile := LProject.FileName;
      Result.ProjectName := TPath.GetFileNameWithoutExtension(LProject.FileName);
    end;
    if _TryGetActiveBuffer(LBuffer) then
      _FillEditorFields(LBuffer, Result);
  except
    Result := Default(TActiveProjectInfo);
  end;
end;

procedure _InitContextBuilder;
begin
  GContextBuilder := TProjectContextBuilder.Create(
    function: TActiveProjectInfo
    begin
      Result := _ResolveActiveProjectInfo;
    end);
end;

procedure _ShutdownContextBuilder;
begin
  GContextBuilder := nil;
end;

// ADR-099: RegisterFormClass disabled — causes IDE Access Violation on form free.
// When RegisterFormClass is active, the IDE VCL style engine installs internal hooks
// (via TApplicationEvents.OnDeactivate) on each form instance. When the form is freed
// but the IDE still holds the hook reference, DoDeactivate fires and crashes.
// Theming is applied safely via explicit LTheming.ApplyTheme() + ApplyPremiumTheme()
// calls within each dialog's own constructor / class Edit method.
procedure _InitTheming;
begin
  // Intentional no-op — see ADR-099
end;

procedure _ShutdownTheming;
begin
  // Intentional no-op — see ADR-099
end;

procedure _ShutdownOutputPanel;
begin
  GOutputPanel := nil;
  TChatPanelHost.UnregisterChatPanel;
end;

procedure _InitConfig;
begin
  GConfig := TConfigService.Create(
    function: string
    begin
      Result := _ResolveGlobalConfigRoot; // global, not per-project (feedback #1)
    end);
  try
    GConfig.Load;
  except
    on E: Exception do
      OutputDebugString(PChar(
        'Aefos.Register: initial config load failed: ' + E.Message));
  end;
end;

procedure _ShutdownConfig;
begin
  GConfig := nil;
end;

// ESP-002 Epic 4/4 Demand 1/1 (ADR-208/211): register the Aefos node in
// Tools->Options. The pages bind to the active project's IConfig through the
// shared root resolver; a persist-on-accept re-resolves the executor graph so
// a Chat-page executor switch takes effect exactly as the retired modal did.
procedure _InitOptions;
begin
  RegisterAefosOptions(
    GConfig,
    function: string
    begin
      Result := _ResolveGlobalConfigRoot; // global config (feedback #1): the page is
                                           // editable on Welcome, no project needed
    end,
    procedure
    begin
      _ResolveExecutorGraph;
      // ESP-002 Demand 2/3 (AC-08): a Chat-page executor change may not
      // re-resolve the graph (same kind + root early-exits), but the onboarding
      // empty-state must still re-tick the executor step on save — recompute it
      // in place. No-op once the panel is osReady.
      if Assigned(GChatPanel) then
        GChatPanel.RefreshOnboarding;
    end);
  // Shared AI Flow page (silent-reload knob) lives in MCP.Tools.OTA and is
  // refcounted — Terminal registers it too; whichever host loads first wins.
  TAIFlowOptions.RegisterAIFlowOptions;
end;

procedure _ShutdownOptions;
begin
  TAIFlowOptions.UnregisterAIFlowOptions;
  UnregisterAefosOptions;
end;

procedure _InitCodexExecutorProfile(const AConfigPath: string);
begin
  // Probe removed (dead perf, ESP cleanup): the Codex MCP-capability probe
  // (ProbeMcpSupport) spawned a process per IDE composition whose result
  // (McpSupport) only gated BuildMcpConfigJson — which has NO caller now (the
  // chat runs the CLI in the project folder so it loads the project .mcp.json
  // relay). msUnknown is behavior-neutral; only tests read McpSupport.
  GExecutorProfile := TProviderRegistry.ResolveExecutorProfile(ekCodex, msUnknown);
end;

procedure _InitExecutorProfile;
var
  LKind: TExecutorKind;
  LConfigPath: string;
begin
  // BR-2: the active profile is resolved here, once, from the loaded config.
  LKind := ekClaude;
  LConfigPath := '';
  if Assigned(GConfig) then
  begin
    LKind := GConfig.Snapshot.Executor;
    LConfigPath := GConfig.Snapshot.ExecutorPath;
  end;
  if LKind = ekCodex then
    _InitCodexExecutorProfile(LConfigPath)
  else if LKind = ekOllama then
    // Local models: HTTP dispatcher composition (no binary, no probe).
    GExecutorProfile := TProviderRegistry.ResolveExecutorProfile(ekOllama)
  else
    // ekClaude: no probe — v0.7.0 behaviour byte-identical (C-5, AC-13a).
    GExecutorProfile := TProviderRegistry.ResolveExecutorProfile(ekClaude);
end;

procedure _ShutdownExecutorProfile;
begin
  GExecutorProfile := nil;
end;

procedure _InitCommandReplicator;
begin
  // ADR-239: replication root governed exclusively by IExecutorProfile.
  GCommandReplicator := TCommandReplicator.Create(
    GCommandRegistry,
    function: string
    begin
      Result := _ResolveActiveProjectRoot;
    end,
    GExecutorProfile);
end;

procedure _ShutdownCommandReplicator;
begin
  GCommandReplicator := nil;
end;

type
  // Captures the result of an asynchronous build (ADR-068). RAD Studio
  // fires ProjectCompileFinished on the IDE main thread once the build
  // ends; the captured TMCPBuildState is read back by QueryBuildResult.
  TBuildResultProc = reference to procedure(const AState: TMCPBuildState);

  TBuildCompileNotifier = class(TInterfacedObject, IOTAProjectCompileNotifier)
  private
    FOnFinished: TBuildResultProc;
  public
    constructor Create(const AOnFinished: TBuildResultProc);
    // IOTAProjectCompileNotifier
    procedure AfterCompile(var CompileInfo: TOTAProjectCompileInfo);
    procedure BeforeCompile(var CompileInfo: TOTAProjectCompileInfo);
    procedure Destroyed;
  end;

  // ── Re-anchoring OTA-event observer (ESP-002 Demand 5/5, ADR-072) ──────
  //
  // Translates IDE events into TMCPReAnchorNotifier calls — the only
  // genuinely new OTA-touching code of this demand; the exact OTA surface
  // is maintainer-verified at AC-19 (ESP R-2 / OQ-2). Discrete events
  // forward straight through; cursor activity (re)arms a ~400 ms debounce
  // timer whose OnTimer flushes a single coalesced cursor re-anchor.

  TMCPSaveCallback = reference to procedure;

  // Per-module save notifier — AfterSave fires the re-anchor callback.
  TMCPModuleSaveNotifier = class(TNotifierObject, IOTANotifier,
    IOTAModuleNotifier)
  private
    FOnSaved: TMCPSaveCallback;
  public
    constructor Create(const AOnSaved: TMCPSaveCallback);
    // IOTANotifier — TNotifierObject's AfterSave is not virtual, so this
    // is a name-resolved interface implementation rather than an override.
    procedure AfterSave;
    // IOTAModuleNotifier
    function CheckOverwrite: Boolean;
    procedure ModuleRenamed(const NewName: string);
  end;

  IMCPReAnchorObserver = interface
    ['{7D5E0463-2B81-4C9F-A0E3-6F1D8B4A2C90}']
    procedure Activate;
    procedure Shutdown;
  end;

  TMCPReAnchorObserver = class(TNotifierObject, IOTANotifier,
    INTAEditServicesNotifier, IMCPReAnchorObserver)
  private
    FNotifier: IMCPReAnchorNotifier;
    FTimer: TTimer;
    FEditIndex: Integer;
    FSaveModule: IOTAModule;
    FSaveIndex: Integer;
    procedure _OnDebounceTimer(Sender: TObject);
    procedure _Fire(const AEvent: TMCPReAnchorEvent);
    procedure _ArmCursorDebounce;
    procedure _TrackModuleForSave(const AFileName: string);
    procedure _DetachSaveNotifier;
  public
    constructor Create(const ANotifier: IMCPReAnchorNotifier);
    destructor Destroy; override;
    // IMCPReAnchorObserver
    procedure Activate;
    procedure Shutdown;
    // INTAEditServicesNotifier
    procedure WindowShow(const EditWindow: INTAEditWindow;
      Show, LoadedFromDesktop: Boolean);
    procedure WindowNotification(const EditWindow: INTAEditWindow;
      Operation: TOperation);
    procedure WindowActivated(const EditWindow: INTAEditWindow);
    procedure WindowCommand(const EditWindow: INTAEditWindow;
      Command, Param: Integer; var Handled: Boolean);
    procedure EditorViewActivated(const EditWindow: INTAEditWindow;
      const EditView: IOTAEditView);
    procedure EditorViewModified(const EditWindow: INTAEditWindow;
      const EditView: IOTAEditView);
    procedure DockFormVisibleChanged(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
    procedure DockFormUpdated(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
    procedure DockFormRefresh(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
  end;

// Resolves the open source editor for AUnitPath and returns its current
// buffer body. Shared by ReadUnit and EditUnit so both see one source of
// truth (BR-3). Returns False when the unit is not open in the IDE.
function _FindSourceEditor(const AUnitPath: string;
  out ASource: IOTASourceEditor; out ABody: string): Boolean;
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LIndex: Integer;
  LEditor: IOTAEditor;
  LReader: IOTAEditReader;
  LBytes: TBytes;
  LSize: Integer;
begin
  Result := False;
  ASource := nil;
  ABody := '';
  if not Assigned(BorlandIDEServices) then
    Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  LModule := LModuleServices.FindModule(AUnitPath);
  if not Assigned(LModule) then
    Exit;
  for LIndex := 0 to LModule.GetModuleFileCount - 1 do
  begin
    LEditor := LModule.GetModuleFileEditor(LIndex);
    if Supports(LEditor, IOTASourceEditor, ASource) then
    begin
      LReader := ASource.CreateReader;
      if not Assigned(LReader) then
      begin
        ASource := nil;
        Continue;
      end;
      SetLength(LBytes, 256 * 1024);
      LSize := LReader.GetText(0, PAnsiChar(@LBytes[0]), Length(LBytes));
      ABody := DecodeUnitBodyBytes(LBytes, LSize);
      Result := True;
      Exit;
    end;
  end;
end;

// Counts non-overlapping occurrences of ANeedle in AHaystack.
function _CountOccurrences(const AHaystack, ANeedle: string): Integer;
var
  LFrom: Integer;
  LAt: Integer;
begin
  Result := 0;
  if ANeedle = '' then
    Exit;
  LFrom := 1;
  repeat
    LAt := Pos(ANeedle, AHaystack, LFrom);
    if LAt = 0 then
      Break;
    Inc(Result);
    LFrom := LAt + Length(ANeedle);
  until False;
end;

// Replaces AOldLen characters at ACharPos with ANewText through an
// undoable edit writer (ADR-062). The buffer tail is preserved when the
// writer is released; the file is not saved.
procedure _ApplyReplacement(const ASource: IOTASourceEditor;
  const ACharPos, AOldLen: Integer; const ANewText: string);
var
  LWriter: IOTAEditWriter;
  LNewAnsi: UTF8String;
begin
  LNewAnsi := UTF8String(ANewText);
  LWriter := ASource.CreateUndoableWriter;
  LWriter.CopyTo(ACharPos);
  LWriter.DeleteTo(ACharPos + AOldLen);
  if Length(LNewAnsi) > 0 then
    LWriter.Insert(PAnsiChar(LNewAnsi));
end;

{ TBuildCompileNotifier }

constructor TBuildCompileNotifier.Create(const AOnFinished: TBuildResultProc);
begin
  inherited Create;
  FOnFinished := AOnFinished;
end;

procedure TBuildCompileNotifier.BeforeCompile(
  var CompileInfo: TOTAProjectCompileInfo);
begin
end;

procedure TBuildCompileNotifier.AfterCompile(
  var CompileInfo: TOTAProjectCompileInfo);
begin
  // RAD Studio fires this on the IDE main thread once the async build ends;
  // CompileInfo.Result is True on success (ESP R-3).
  if not Assigned(FOnFinished) then
    Exit;
  if CompileInfo.Result then
    FOnFinished(bsSucceeded)
  else
    FOnFinished(bsFailed);
end;

procedure TBuildCompileNotifier.Destroyed;
begin
end;

// ── Shared OTA helpers ─────────────────────────────────────────────────────
// The IMCPWorkspaceFacade implementation now lives in the shared
// Aefos.MCP.Tools.OTA BPL (TMCPWorkspaceFacade). The standalone
// helpers below are still used by the plugin composition root and the DFM
// resource helpers.

// Resolves IOTAModuleServices from the IDE service broker.
function _TryGetModuleServices(out AServices: IOTAModuleServices): Boolean;
begin
  AServices := nil;
  Result := Assigned(BorlandIDEServices) and
    Supports(BorlandIDEServices, IOTAModuleServices, AServices);
end;

// Removes and releases the compile notifier registered for the current
// build. Called once the build leaves bsRunning (ESP R-3).
// ── Project group (Epic 7/7 Demand 2/8, ADR-121/122/123/124/125) ──────
// All facade reads early-exit with sentinel when there is no active project;
// writes return False. Exceptions never cross the MCP boundary (BR-3).

function _TryGetProjectOptions(out AOptions: IOTAProjectOptions): Boolean;
var
  LProject: IOTAProject;
begin
  AOptions := nil;
  Result := False;
  if not _TryGetActiveProject(LProject) then
    Exit;
  AOptions := LProject.ProjectOptions;
  Result := Assigned(AOptions);
end;

function _TryGetProjectOptionsConfigurations(
  out AConfigs: IOTAProjectOptionsConfigurations): Boolean;
var
  LOptions: IOTAProjectOptions;
begin
  AConfigs := nil;
  Result := False;
  if not _TryGetProjectOptions(LOptions) then
    Exit;
  Result := Supports(LOptions, IOTAProjectOptionsConfigurations, AConfigs);
end;

function _ReadOptionString(const AOptions: IOTAProjectOptions;
  const AKey: string): string;
begin
  Result := '';
  try
    Result := VarToStr(AOptions.Values[AKey]);
  except
    Result := '';
  end;
end;

function _ReadOptionInt(const AOptions: IOTAProjectOptions;
  const AKey: string): Integer;
var
  LValue: Variant;
begin
  try
    LValue := AOptions.Values[AKey];
    Result := StrToIntDef(VarToStr(LValue), 0);
  except
    Result := 0;
  end;
end;

// Classifies the active project per AC-09: reads IOTAProject.ApplicationType
// first (the canonical post-IOTAProject signal), falls back to personality.
// ── Units group (Epic 7/7 Demand 3/8, ADR-126..ADR-131) ────────────────
// Reads return sentinels on unknown/no-active-project; writes return False
// on OTA refusal. Exceptions never cross the MCP boundary (BR-3).

// Resolves a unit by NAME or PATH using IOTAModuleServices.FindModule. The
// OTA surface accepts both forms; tries the name as-is, then with .pas, then
// as a direct path.
function _ResolveUnitModule(const AUnitNameOrPath: string;
  out AModule: IOTAModule): Boolean;
var
  LServices: IOTAModuleServices;
begin
  AModule := nil;
  Result := False;
  if AUnitNameOrPath = '' then
    Exit;
  if not _TryGetModuleServices(LServices) then
    Exit;
  AModule := LServices.FindModule(AUnitNameOrPath);
  if not Assigned(AModule) and (ExtractFileExt(AUnitNameOrPath) = '') then
    AModule := LServices.FindModule(AUnitNameOrPath + '.pas');
  Result := Assigned(AModule);
end;

// Returns the IOTASourceEditor of AModule (the first source editor view) or
// nil when none is open. Carries no exception path.
function _ModuleSourceEditor(const AModule: IOTAModule): IOTASourceEditor;
var
  LIndex: Integer;
  LEditor: IOTAEditor;
  LSource: IOTASourceEditor;
begin
  Result := nil;
  if not Assigned(AModule) then
    Exit;
  for LIndex := 0 to AModule.GetModuleFileCount - 1 do
  begin
    LEditor := AModule.GetModuleFileEditor(LIndex);
    if Supports(LEditor, IOTASourceEditor, LSource) then
      Exit(LSource);
  end;
end;

// Reads the full body of a source editor (truncated at 256 KB — same budget
// as ReadUnit). Returns empty string on missing reader.
function _ReadEditorBody(const ASource: IOTASourceEditor): string;
var
  LReader: IOTAEditReader;
  LBytes: TBytes;
  LSize: Integer;
begin
  Result := '';
  if not Assigned(ASource) then
    Exit;
  LReader := ASource.CreateReader;
  if not Assigned(LReader) then
    Exit;
  SetLength(LBytes, 256 * 1024);
  LSize := LReader.GetText(0, PAnsiChar(@LBytes[0]), Length(LBytes));
  Result := DecodeUnitBodyBytes(LBytes, LSize);
end;

// Strips the optional `in 'path'` qualifier and adds the bare unit name to
// AResult, then clears ABuf. Called after each comma and at end-of-input.
procedure _FlushUsesEntry(const ABuf: TStringBuilder;
  const AResult: TList<string>);
var
  LBare: string;
  LInPos: Integer;
begin
  LBare := Trim(ABuf.ToString);
  if LBare <> '' then
  begin
    LInPos := Pos(' in ', LowerCase(LBare));
    if LInPos > 0 then
      LBare := Trim(Copy(LBare, 1, LInPos - 1));
    if LBare <> '' then
      AResult.Add(LBare);
  end;
  ABuf.Clear;
end;

// Processes one character of a uses-clause body, updating the lexer state
// (ABraceComment, ALineComment) and the accumulation buffer (ABuf). When a
// comma is encountered the current token is flushed to AResult.
procedure _StepUsesChar(const ABody: string; const APos: Integer;
  var ABraceComment, ALineComment: Boolean;
  const ABuf: TStringBuilder; const AResult: TList<string>);
var
  LCh: Char;
begin
  LCh := ABody[APos];
  if ALineComment then
  begin
    if (LCh = #10) or (LCh = #13) then
      ALineComment := False;
  end
  else if ABraceComment then
  begin
    if LCh = '}' then
      ABraceComment := False;
  end
  else if LCh = '{' then
    ABraceComment := True
  else if (LCh = '/') and (APos < Length(ABody)) and (ABody[APos + 1] = '/') then
    ALineComment := True
  else if LCh = ',' then
    _FlushUsesEntry(ABuf, AResult)
  else
    ABuf.Append(LCh);
end;

// Parses a Pascal uses-clause body (the text between `uses` and `;`) into
// bare unit identifiers. Tolerates `<unit> in '<path>'`, line comments,
// {$IFDEF} blocks (treated as opaque), and multi-line layouts (C-8).
function _ParseUsesEntries(const AClauseBody: string): TArray<string>;
var
  LBuf: TStringBuilder;
  LFor: Integer;
  LInBraceComment: Boolean;
  LInLineComment: Boolean;
  LResult: TList<string>;
begin
  LResult := TList<string>.Create;
  LBuf := TStringBuilder.Create;
  try
    LInBraceComment := False;
    LInLineComment := False;
    for LFor := 1 to Length(AClauseBody) do
      _StepUsesChar(AClauseBody, LFor, LInBraceComment, LInLineComment,
        LBuf, LResult);
    _FlushUsesEntry(LBuf, LResult);
    Result := LResult.ToArray;
  finally
    LBuf.Free;
    LResult.Free;
  end;
end;

// Returns the body text between `uses` and the next `;`, along with the
// 1-based char offsets of the body's start/end (inclusive of the `;`).
// Returns False when the section's uses clause cannot be located.
function _FindUsesClause(const ASource, ASectionKeyword: string;
  out ABodyStart, ABodySemicolonPos: Integer; out ABody: string): Boolean;
var
  LLower: string;
  LSectionAt, LUsesAt, LSemiAt: Integer;
begin
  Result := False;
  ABody := '';
  ABodyStart := 0;
  ABodySemicolonPos := 0;
  LLower := LowerCase(ASource);
  LSectionAt := Pos(LowerCase(ASectionKeyword), LLower);
  if LSectionAt = 0 then
    Exit;
  LUsesAt := PosEx('uses', LLower, LSectionAt + Length(ASectionKeyword));
  if LUsesAt = 0 then
    Exit;
  // Stop before the matching `implementation` keyword for the interface
  // section so we never pick up `implementation`'s uses clause by accident.
  if SameText(ASectionKeyword, 'interface') then
  begin
    LSectionAt := Pos('implementation', LLower);
    if (LSectionAt > 0) and (LUsesAt > LSectionAt) then
      Exit;
  end;
  LSemiAt := PosEx(';', ASource, LUsesAt + 4);
  if LSemiAt = 0 then
    Exit;
  ABodyStart := LUsesAt + 4;  // skip past "uses"
  ABodySemicolonPos := LSemiAt;
  ABody := Copy(ASource, ABodyStart, LSemiAt - ABodyStart);
  Result := True;
end;

// Minimal Pascal template for CreateNewUnit (WithForm=false). ADR-129.
function _MinimalUnitTemplate(const AUnitName: string): string;
const
  CLF = sLineBreak;
begin
  Result :=
    'unit ' + AUnitName + ';' + CLF + CLF +
    'interface' + CLF + CLF +
    'implementation' + CLF + CLF +
    'end.' + CLF;
end;

// Minimal .dfm stub paired with WithForm=true. The IDE re-formats the .dfm
// the first time the form is opened in the designer; this stub is just a
// placeholder so the .pas/.dfm pair is consistent on disk.
function _MinimalFormTemplate(const AUnitName: string): string;
const
  CLF = sLineBreak;
var
  LClassName, LVarName: string;
begin
  LClassName := 'T' + AUnitName + 'Form';
  LVarName   := AUnitName + 'Form';
  Result :=
    'unit ' + AUnitName + ';' + CLF + CLF +
    'interface' + CLF + CLF +
    'uses' + CLF +
    '  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,' +
    CLF +
    '  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs;' +
    CLF + CLF +
    'type' + CLF +
    '  ' + LClassName + ' = class(TForm)' + CLF +
    '  private' + CLF +
    '  public' + CLF +
    '  end;' + CLF + CLF +
    'var' + CLF +
    '  ' + LVarName + ': ' + LClassName + ';' + CLF + CLF +
    'implementation' + CLF + CLF +
    '{$R *.dfm}' + CLF + CLF +
    'end.' + CLF;
end;

function _MinimalDfmStub(const AUnitName: string): string;
const
  CLF = sLineBreak;
var
  LClassName, LCaption: string;
begin
  LClassName := 'T' + AUnitName + 'Form';
  LCaption   := AUnitName + 'Form';
  Result :=
    'object ' + LCaption + ': ' + LClassName + CLF +
    '  Left = 0' + CLF +
    '  Top = 0' + CLF +
    '  Caption = ''' + LCaption + '''' + CLF +
    '  ClientHeight = 240' + CLF +
    '  ClientWidth = 320' + CLF +
    '  TextHeight = 15' + CLF +
    'end' + CLF;
end;

// FMX template for CreateNewUnit when the active project uses FMX framework.
// Uses Position.X/Position.Y for component layout (FMX convention).
function _MinimalFMXFormTemplate(const AUnitName: string): string;
const
  CLF = sLineBreak;
var
  LClassName, LVarName: string;
begin
  LClassName := 'T' + AUnitName + 'Form';
  LVarName   := AUnitName + 'Form';
  Result :=
    'unit ' + AUnitName + ';' + CLF + CLF +
    'interface' + CLF + CLF +
    'uses' + CLF +
    '  System.SysUtils, System.Types, System.UITypes, System.Classes,' +
    CLF +
    '  FMX.Types, FMX.Controls, FMX.Forms, FMX.Dialogs,' + CLF +
    '  FMX.Controls.Presentation, FMX.StdCtrls;' + CLF + CLF +
    'type' + CLF +
    '  ' + LClassName + ' = class(TForm)' + CLF +
    '  private' + CLF +
    '  public' + CLF +
    '  end;' + CLF + CLF +
    'var' + CLF +
    '  ' + LVarName + ': ' + LClassName + ';' + CLF + CLF +
    'implementation' + CLF + CLF +
    '{$R *.dfm}' + CLF + CLF +
    'end.' + CLF;
end;

// FMX DFM stub: uses FormFactor (FMX-specific) instead of VCL Color/Font.
// Designer will show "Position.X does not exist" until first RunBuild —
// this is expected; build and run normally even with designer errors.
function _MinimalFMXDfmStub(const AUnitName: string): string;
const
  CLF = sLineBreak;
var
  LClassName, LCaption: string;
begin
  LClassName := 'T' + AUnitName + 'Form';
  LCaption   := AUnitName + 'Form';
  Result :=
    'object ' + LCaption + ': ' + LClassName + CLF +
    '  Left = 0' + CLF +
    '  Top = 0' + CLF +
    '  Caption = ''' + LCaption + '''' + CLF +
    '  ClientHeight = 480' + CLF +
    '  ClientWidth = 640' + CLF +
    '  FormFactor.Width = 320' + CLF +
    '  FormFactor.Height = 480' + CLF +
    '  FormFactor.Devices = [desktop]' + CLF +
    '  PixelsPerInch = 96' + CLF +
    '  TextHeight = 13' + CLF +
    'end' + CLF;
end;

// ── CreateNewProject helpers ──────────────────────────────────────────────────

const
  SCRATCH_SUBDIR = 'Aefos';
  OTA_PERSONALITY = 'Delphi.Personality';
  OTA_PLATFORM_WIN32 = 'Win32';

// Validates that AName is a single Pascal identifier (safe for use as filename).
function _IsValidProjectName(const AName: string): Boolean;
var
  LI: Integer;
begin
  Result := False;
  if AName = '' then Exit;
  if not CharInSet(AName[1], ['A'..'Z', 'a'..'z', '_']) then Exit;
  for LI := 2 to Length(AName) do
    if not CharInSet(AName[LI], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then Exit;
  Result := True;
end;

type
  // Project kind enum — kept local so no RADShell dependency is needed.
  TNewProjectKind = (npkUnsupported, npkVCL, npkFMX, npkConsole, npkPackage,
    npkLibrary, npkDUnit, npkDUnitX);

  // Minimal OTA source file — supplies the initial .dpr/.dpk source text.
  TProjectSourceFile = class(TInterfacedObject, IOTAFile)
  private
    FSource: string;
  public
    constructor Create(const ASource: string);
    function GetSource: string;
    function GetAge: TDateTime;
  end;

  // OTA project creator — drives IOTAModuleServices.CreateModule for one kind.
  TNewProjectCreator = class(TInterfacedObject, IOTACreator,
    IOTAProjectCreator, IOTAProjectCreator50, IOTAProjectCreator80,
    IOTAProjectCreator160)
  private
    FKind: TNewProjectKind;
    FFileName: string;  // full path to .dpr/.dpk
    FSource: string;
  public
    constructor Create(const AKind: TNewProjectKind;
      const AFileName, ASource: string);
    // IOTACreator
    function GetCreatorType: string;
    function GetExisting: Boolean;
    function GetFileSystem: string;
    function GetOwner: IOTAModule;
    function GetUnnamed: Boolean;
    // IOTAProjectCreator
    function GetFileName: string;
    function GetOptionFileName: string;
    function GetShowSource: Boolean;
    procedure NewDefaultModule;
    function NewOptionSource(const AProjectName: string): IOTAFile;
    procedure NewProjectResource(const AProject: IOTAProject);
    function NewProjectSource(const AProjectName: string): IOTAFile;
    // IOTAProjectCreator50
    procedure NewDefaultProjectModule(const AProject: IOTAProject);
    // IOTAProjectCreator80
    function GetProjectPersonality: string;
    // IOTAProjectCreator160
    function GetFrameworkType: string;
    function GetPlatforms: TArray<string>;
    function GetPreferredPlatform: string;
    procedure SetInitialOptions(const ANewProject: IOTAProject);
  end;

{ TProjectSourceFile }

constructor TProjectSourceFile.Create(const ASource: string);
begin
  inherited Create;
  FSource := ASource;
end;

function TProjectSourceFile.GetSource: string;
begin
  Result := FSource;
end;

function TProjectSourceFile.GetAge: TDateTime;
begin
  Result := -1;
end;

{ TNewProjectCreator }

constructor TNewProjectCreator.Create(const AKind: TNewProjectKind;
  const AFileName, ASource: string);
begin
  inherited Create;
  FKind     := AKind;
  FFileName := AFileName;
  FSource   := ASource;
end;

function TNewProjectCreator.GetCreatorType: string;
begin
  case FKind of
    npkVCL, npkFMX: Result := 'Application';
    npkConsole:     Result := 'Console';
    npkPackage:     Result := 'Package';
    npkLibrary:     Result := 'Library';
  else
    Result := 'Application';
  end;
end;

function TNewProjectCreator.GetExisting: Boolean;
begin
  Result := False;
end;

function TNewProjectCreator.GetFileSystem: string;
begin
  Result := '';
end;

function TNewProjectCreator.GetOwner: IOTAModule;
begin
  Result := nil;
end;

function TNewProjectCreator.GetUnnamed: Boolean;
begin
  Result := False;
end;

function TNewProjectCreator.GetFileName: string;
begin
  Result := FFileName;
end;

function TNewProjectCreator.GetOptionFileName: string;
begin
  Result := '';
end;

function TNewProjectCreator.GetShowSource: Boolean;
begin
  Result := False;
end;

procedure TNewProjectCreator.NewDefaultModule;
begin
end;

function TNewProjectCreator.NewOptionSource(
  const AProjectName: string): IOTAFile;
begin
  Result := nil;
end;

procedure TNewProjectCreator.NewProjectResource(const AProject: IOTAProject);
begin
end;

function TNewProjectCreator.NewProjectSource(
  const AProjectName: string): IOTAFile;
begin
  Result := TProjectSourceFile.Create(FSource);
end;

procedure TNewProjectCreator.NewDefaultProjectModule(
  const AProject: IOTAProject);
begin
end;

function TNewProjectCreator.GetProjectPersonality: string;
begin
  Result := OTA_PERSONALITY;
end;

function TNewProjectCreator.GetFrameworkType: string;
begin
  case FKind of
    npkVCL: Result := 'VCL';
    npkFMX: Result := 'FMX';
  else
    Result := '';
  end;
end;

function TNewProjectCreator.GetPlatforms: TArray<string>;
begin
  Result := [OTA_PLATFORM_WIN32];
end;

function TNewProjectCreator.GetPreferredPlatform: string;
begin
  Result := OTA_PLATFORM_WIN32;
end;

procedure TNewProjectCreator.SetInitialOptions(const ANewProject: IOTAProject);
begin
end;

// Generates the minimal project source for the given kind.
function _ProjectSource(const AName: string;
  const AKind: TNewProjectKind): string;
const
  NL = sLineBreak;
begin
  case AKind of
    npkVCL:
      Result := 'program ' + AName + ';' + NL + NL +
                'uses' + NL +
                '  Vcl.Forms;' + NL + NL +
                '{$R *.res}' + NL + NL +
                'begin' + NL +
                '  Application.Initialize;' + NL +
                '  Application.MainFormOnTaskbar := True;' + NL +
                '  Application.Run;' + NL +
                'end.' + NL;
    npkFMX:
      Result := 'program ' + AName + ';' + NL + NL +
                'uses' + NL +
                '  FMX.Forms;' + NL + NL +
                '{$R *.res}' + NL + NL +
                'begin' + NL +
                '  Application.Initialize;' + NL +
                '  Application.Run;' + NL +
                'end.' + NL;
    npkConsole:
      Result := 'program ' + AName + ';' + NL + NL +
                '{$APPTYPE CONSOLE}' + NL + NL +
                'uses' + NL +
                '  System.SysUtils;' + NL + NL +
                'begin' + NL +
                'end.' + NL;
    npkPackage:
      Result := 'package ' + AName + ';' + NL + NL +
                '{$IMPLICITBUILD ON}' + NL + NL +
                'requires' + NL +
                '  rtl;' + NL + NL +
                'end.' + NL;
    npkLibrary:
      Result := 'library ' + AName + ';' + NL + NL +
                'uses' + NL +
                '  System.SysUtils;' + NL + NL +
                '{$R *.res}' + NL + NL +
                'begin' + NL +
                'end.' + NL;
    npkDUnit:
      Result := 'program ' + AName + ';' + NL + NL +
                '{$IFDEF CONSOLE_TESTRUNNER}' + NL +
                '{$APPTYPE CONSOLE}' + NL +
                '{$ENDIF}' + NL + NL +
                'uses' + NL +
                '  DUnitTestRunner;' + NL + NL +
                '{$R *.RES}' + NL + NL +
                'begin' + NL +
                '  DUnitTestRunner.RunRegisteredTests;' + NL +
                'end.' + NL;
    npkDUnitX:
      Result := 'program ' + AName + ';' + NL + NL +
                '{$IFNDEF TESTINSIGHT}' + NL +
                '{$APPTYPE CONSOLE}' + NL +
                '{$ENDIF}' + NL + NL +
                'uses' + NL +
                '  System.SysUtils,' + NL +
                '  DUnitX.TestFramework,' + NL +
                '  DUnitX.Loggers.Console;' + NL + NL +
                '{$R *.RES}' + NL + NL +
                'begin' + NL +
                '  try' + NL +
                '    var LRunner := TDUnitX.CreateRunner;' + NL +
                '    LRunner.AddLogger(TDUnitXConsoleLogger.Create(True));' + NL +
                '    TDUnitX.Run(LRunner);' + NL +
                '  except' + NL +
                '    on E: Exception do' + NL +
                '      Writeln(E.ClassName, '': '', E.Message);' + NL +
                '  end;' + NL +
                'end.' + NL;
  else
    Result := '';
  end;
end;

// Maps the ATypeName string (case-insensitive) to a project kind.
function _ClassifyProjectType(const ATypeName: string): TNewProjectKind;
type
  TKindAlias = record Token: string; Kind: TNewProjectKind; end;
const
  ALIASES: array[0..19] of TKindAlias = (
    (Token: 'vcl';             Kind: npkVCL),
    (Token: 'vclapp';          Kind: npkVCL),
    (Token: 'vclapplication';  Kind: npkVCL),
    (Token: 'fmx';             Kind: npkFMX),
    (Token: 'firemonkey';      Kind: npkFMX),
    (Token: 'fmxapp';          Kind: npkFMX),
    (Token: 'console';         Kind: npkConsole),
    (Token: 'consoleapp';      Kind: npkConsole),
    (Token: 'package';         Kind: npkPackage),
    (Token: 'pkg';             Kind: npkPackage),
    (Token: 'bpl';             Kind: npkPackage),
    (Token: 'library';         Kind: npkLibrary),
    (Token: 'lib';             Kind: npkLibrary),
    (Token: 'dll';             Kind: npkLibrary),
    (Token: 'dunit';           Kind: npkDUnit),
    (Token: 'dunit2';          Kind: npkDUnit),
    (Token: 'nunit';           Kind: npkDUnit),
    (Token: 'dunitx';          Kind: npkDUnitX),
    (Token: 'dunitx2';         Kind: npkDUnitX),
    (Token: 'testproject';     Kind: npkDUnitX));
var
  LToken: string;
  LI: Integer;
begin
  LToken := Trim(ATypeName).ToLower;
  for LI := 0 to High(ALIASES) do
    if SameText(LToken, ALIASES[LI].Token) then
      Exit(ALIASES[LI].Kind);
  Result := npkUnsupported;
end;

// Returns True when AEntries (bare unit identifiers) already contains AName
// under case-insensitive comparison.
function _UsesContains(const AEntries: TArray<string>;
  const AName: string): Boolean;
var
  LFor: Integer;
begin
  Result := False;
  for LFor := 0 to High(AEntries) do
    if SameText(AEntries[LFor], AName) then
      Exit(True);
end;

// Rewrites the whole AUnitName module body via the undoable writer. Helper
// for AddToUses/RemoveFromUses — the source editor is already open at this
// point (callers must verify).
procedure _ReplaceWholeBody(const ASource: IOTASourceEditor;
  const AOldBody, ANewBody: string);
begin
  _ApplyReplacement(ASource, 0, Length(AOldBody), ANewBody);
end;

// Returns True when the character at APos is not an identifier continuation
// character — used to validate identifier boundaries inside a uses clause.
function _IsIdentBoundary(const AStr: string; APos: Integer): Boolean; inline;
begin
  Result := not CharInSet(AStr[APos], ['a'..'z', '0'..'9', '_']);
end;

// Advances AEnd past an optional ` in 'path'` qualifier that follows a unit
// identifier in a uses clause (e.g. `SomeUnit in 'Source\SomeUnit.pas'`).
procedure _SkipInQualifier(const AClause: string; var AEnd: Integer);
begin
  // Skip leading whitespace before the optional `in` keyword.
  while (AEnd <= Length(AClause)) and CharInSet(AClause[AEnd], [' ', #9]) do
    Inc(AEnd);
  // Check for the `in ` keyword.
  if (AEnd + 2 > Length(AClause)) or
     not SameText(Copy(AClause, AEnd, 3), 'in ') then
    Exit;
  Inc(AEnd, 3);
  // Skip to the opening quote.
  while (AEnd <= Length(AClause)) and (AClause[AEnd] <> '''') do
    Inc(AEnd);
  if AEnd <= Length(AClause) then
    Inc(AEnd); // skip opening quote
  // Skip to the closing quote.
  while (AEnd <= Length(AClause)) and (AClause[AEnd] <> '''') do
    Inc(AEnd);
  if AEnd <= Length(AClause) then
    Inc(AEnd); // skip closing quote
end;

// Adjusts LStart/LEnd to absorb the comma that delimits the entry.
// Prefers eating a leading comma (`,<entry>`) over a trailing one (`<entry>,`).
procedure _EatComma(const AClause: string;
  var AStart, AEnd: Integer);
begin
  if (AStart > 1) and (Copy(AClause, AStart - 1, 1) = ',') then
  begin
    Dec(AStart);
    Exit;
  end;
  // No leading comma — try trailing comma (eat whitespace first).
  while (AEnd <= Length(AClause)) and
        CharInSet(AClause[AEnd], [' ', #9, #10, #13]) do
    Inc(AEnd);
  if (AEnd <= Length(AClause)) and (AClause[AEnd] = ',') then
    Inc(AEnd);
end;

// Searches AClause for AName as a bare identifier (case-insensitive) and
// removes it together with the adjacent comma. Returns the rewritten clause
// body. AChanged is True only when a removal happened.
function _RemoveFromClauseBody(const AClause, AName: string;
  out AChanged: Boolean): string;
var
  LLower, LLowerName: string;
  LAt, LStart, LEnd, LNameLen: Integer;
begin
  AChanged := False;
  Result := AClause;
  LLower := LowerCase(AClause);
  LLowerName := LowerCase(AName);
  LNameLen := Length(LLowerName);
  LAt := 1;
  while LAt <= Length(LLower) do
  begin
    LAt := PosEx(LLowerName, LLower, LAt);
    if LAt = 0 then
      Exit;
    // Validate left identifier boundary.
    if (LAt > 1) and not _IsIdentBoundary(LLower, LAt - 1) then
    begin
      Inc(LAt);
      Continue;
    end;
    // Validate right identifier boundary.
    if (LAt + LNameLen - 1 < Length(LLower)) and
       not _IsIdentBoundary(LLower, LAt + LNameLen) then
    begin
      Inc(LAt);
      Continue;
    end;
    // Identifier confirmed — mark the slice and expand for optional qualifier.
    LStart := LAt;
    LEnd := LAt + LNameLen;
    _SkipInQualifier(AClause, LEnd);
    _EatComma(AClause, LStart, LEnd);
    Result := Copy(AClause, 1, LStart - 1) + Copy(AClause, LEnd, MaxInt);
    AChanged := True;
    Exit;
  end;
end;


// ── Editor group (Epic 7/7 Demand 4/8, ADR-133..ADR-135) ────────────────

function _EditPosToCharPos(const ABody: string; ALine, ACol: Integer): Integer;
var
  LCurrentLine, LIndex: Integer;
begin
  LCurrentLine := 1;
  LIndex := 1;
  while (LIndex <= Length(ABody)) and (LCurrentLine < ALine) do
  begin
    if ABody[LIndex] = #10 then
      Inc(LCurrentLine);
    Inc(LIndex);
  end;
  Result := (LIndex - 1) + (ACol - 1);
  if Result > Length(ABody) then
    Result := Length(ABody);
end;

procedure _SearchModuleContent(const APath, AText: string; ACaseSensitive: Boolean;
  const AList: TList<TMCPCursorInfo>);
var
  LBody: string;
  LSource: IOTASourceEditor;
  LLines: TArray<string>;
  LForLine, LAt, LStart: Integer;
  LSearchLine, LSearchNeedle: string;
  LPosInfo: TMCPCursorInfo;
begin
  LBody := '';
  if _FindSourceEditor(APath, LSource, LBody) then
  begin
    // Active buffer already filled
  end
  else if TFile.Exists(APath) then
  begin
    try
      LBody := TFile.ReadAllText(APath);
    except
      LBody := '';
    end;
  end;

  if LBody = '' then
    Exit;

  LLines := LBody.Split([#13#10, #13, #10]);
  for LForLine := 0 to High(LLines) do
  begin
    LSearchLine := LLines[LForLine];
    LSearchNeedle := AText;
    if not ACaseSensitive then
    begin
      LSearchLine := LSearchLine.ToLower;
      LSearchNeedle := LSearchNeedle.ToLower;
    end;

    LStart := 1;
    repeat
      LAt := Pos(LSearchNeedle, LSearchLine, LStart);
      if LAt = 0 then
        Break;

      LPosInfo := Default(TMCPCursorInfo);
      LPosInfo.UnitPath := APath;
      LPosInfo.Line := LForLine + 1;
      LPosInfo.Column := LAt;
      LPosInfo.Available := True;
      AList.Add(LPosInfo);

      LStart := LAt + Length(LSearchNeedle);
    until False;
  end;
end;

// ── Build group (Epic 7/7 Demand 5/8, ADR-136..ADR-138) ────────────────
// Reads return sentinels on missing project / unknown key; writes return
// False on no-active-project, option-key-not-found, or OTA refusal.
// Exceptions never cross the MCP boundary (BR-3).

// Alternates lists per ADR-138 — first match wins, scanning the live
// IOTAProjectOptions.GetOptionNames dictionary. New entries must EXTEND,
// not replace, these lists in future demands.
const
  CSearchPathKeys: array[0..2] of string =
    ('SrcDir', 'UnitSearchPath', 'DCC_UnitSearchPath');
  CDefinesKeys: array[0..2] of string =
    ('Defines', 'DCC_Define', 'ConditionalDefines');
  CDCUOutputKeys: array[0..2] of string =
    ('DcuOutput', 'DCC_DcuOutput', 'DCC_UnitOutputDir');

// Resolves the canonical key from AAlternates against the option dictionary.
// Returns '' when none of the alternates is exposed by the IDE (ADR-138).
function _ResolveOptionKey(const AOptions: IOTAProjectOptions;
  const AAlternates: array of string): string;
var
  LNames: TOTAOptionNameArray;
  LFor, LIdx: Integer;
begin
  Result := '';
  if not Assigned(AOptions) then
    Exit;
  try
    LNames := AOptions.GetOptionNames;
  except
    SetLength(LNames, 0);
  end;
  for LFor := Low(AAlternates) to High(AAlternates) do
    for LIdx := 0 to High(LNames) do
      if SameText(LNames[LIdx].Name, AAlternates[LFor]) then
        Exit(LNames[LIdx].Name);
end;

// Splits a `;`-delimited OTA option string into bare entries, trimming
// whitespace and dropping empties.
function _SplitOptionList(const AValue: string): TArray<string>;
var
  LParts: TArray<string>;
  LFor, LWrite: Integer;
  LEntry: string;
begin
  SetLength(Result, 0);
  if AValue = '' then
    Exit;
  LParts := AValue.Split([';']);
  SetLength(Result, Length(LParts));
  LWrite := 0;
  for LFor := 0 to High(LParts) do
  begin
    LEntry := Trim(LParts[LFor]);
    if LEntry <> '' then
    begin
      Result[LWrite] := LEntry;
      Inc(LWrite);
    end;
  end;
  SetLength(Result, LWrite);
end;

// Rejoins entries with `;`. No-op when AEntries is empty.
function _JoinOptionList(const AEntries: TArray<string>): string;
begin
  Result := string.Join(';', AEntries);
end;

// Deduplicates ADefines preserving first occurrence order. Case-insensitive.
function _DedupDefines(const ADefines: TArray<string>): TArray<string>;
var
  LList: TStringList;
  LFor: Integer;
begin
  LList := TStringList.Create;
  try
    LList.CaseSensitive := False;
    for LFor := 0 to High(ADefines) do
      if LList.IndexOf(ADefines[LFor]) < 0 then
        LList.Add(ADefines[LFor]);
    SetLength(Result, LList.Count);
    for LFor := 0 to LList.Count - 1 do
      Result[LFor] := LList[LFor];
  finally
    LList.Free;
  end;
end;

// Returns True when the IDE reports at least one active debugged process.
// Falls back to False when the debugger services interface is unavailable.
function _ProcessIsRunning: Boolean;
var
  LDebugger: IOTADebuggerServices;
begin
  Result := False;
  try
    if not Assigned(BorlandIDEServices) then
      Exit;
    if not Supports(BorlandIDEServices, IOTADebuggerServices, LDebugger) then
      Exit;
    Result := LDebugger.ProcessCount > 0;
  except
    Result := False;
  end;
end;

// Looks up an IDE TBasicAction by name on the live INTAServices.ActionList.
// Multiple candidate names are accepted because action identifiers have
// drifted across RAD Studio releases (ADR-138 fallback pattern). Returns
// nil when none of the alternates is registered.
function _ResolveIDEAction(
  const AAlternates: array of string): TBasicAction;
var
  LServices: INTAServices;
  LList: TCustomActionList;
  LFor, LIdx: Integer;
  LAction: TContainedAction;
begin
  Result := nil;
  try
    if not Assigned(BorlandIDEServices) then
      Exit;
    if not Supports(BorlandIDEServices, INTAServices, LServices) then
      Exit;
    LList := LServices.ActionList;
    if not Assigned(LList) then
      Exit;
    for LFor := Low(AAlternates) to High(AAlternates) do
      for LIdx := 0 to LList.ActionCount - 1 do
      begin
        LAction := LList.Actions[LIdx];
        if Assigned(LAction) and SameText(LAction.Name, AAlternates[LFor]) then
          Exit(LAction);
      end;
  except
    Result := nil;
  end;
end;

// ── DPR + Forms & DFM groups (Epic 7/7 Demand 6/8) ────────────────────

// Returns the absolute path to the active project's `.dpr` source file.
// Empty when no active project is open or the project type is non-DPR
// (e.g. package — `.dpk`). Caller swallows the file IO; sentinel on miss.
function _ActiveDPRPath(out APath: string): Boolean;
var
  LProject: IOTAProject;
  LFile: string;
begin
  APath := '';
  Result := False;
  if not _TryGetActiveProject(LProject) then
    Exit;
  LFile := LProject.FileName;
  if LFile = '' then
    Exit;
  // `.dproj` is the IDE-side wrapper; the source program is the sibling
  // file with the same base name and `.dpr`/`.dpk` extension.
  if SameText(ExtractFileExt(LFile), '.dproj') then
  begin
    LFile := ChangeFileExt(LFile, '.dpr');
    if not TFile.Exists(LFile) then
      LFile := ChangeFileExt(LProject.FileName, '.dpk');
  end;
  if not TFile.Exists(LFile) then
    Exit;
  APath := LFile;
  Result := True;
end;

// Returns the sibling `.dproj` path for ADPRPath (same base name, `.dproj`
// extension). Returns empty when the sibling does not exist.
function _SiblingDProjPath(const ADPRPath: string): string;
var
  LCandidate: string;
begin
  Result := '';
  LCandidate := ChangeFileExt(ADPRPath, '.dproj');
  if TFile.Exists(LCandidate) then
    Result := LCandidate;
end;

// Rewrites the <MainSource> node of ADProjPath to ANewBase ('NewName.dpr').
// Returns True on success. Caller wraps the call in a try/except and rolls
// back the filesystem rename when this returns False (ADR-141).
function _RewriteMainSource(const ADProjPath, ANewBase: string): Boolean;
var
  LXml: IXMLDocument;
  LRoot, LNode: IXMLNode;
  LFor: Integer;
begin
  Result := False;
  LXml := TXMLDocument.Create(nil);
  try
    LXml.LoadFromFile(ADProjPath);
    LRoot := LXml.DocumentElement;
    if not Assigned(LRoot) then
      Exit;
    // <MainSource> lives under one of the <PropertyGroup> nodes. Walk the
    // tree depth-1 then depth-2 to find it.
    for LFor := 0 to LRoot.ChildNodes.Count - 1 do
    begin
      LNode := LRoot.ChildNodes[LFor];
      if SameText(LNode.NodeName, 'PropertyGroup')
        and LNode.HasChildNodes then
      begin
        if LNode.ChildNodes.FindNode('MainSource') <> nil then
        begin
          LNode.ChildNodes.FindNode('MainSource').Text := ANewBase;
          LXml.SaveToFile(ADProjPath);
          Exit(True);
        end;
      end;
    end;
  finally
    LXml := nil;
  end;
end;

// Helper: walk active project modules; return entries that have a `.dfm`
// companion file on disk (single source of truth — designer files always
// live next to the `.pas`).
// Helper: resolve the `.dfm` path that belongs to AUnitName (case-insensitive).
// Returns empty when no match is found.
function _ResolveDFMPath(const AUnitName: string): string;
var
  LForms: TArray<TMCPRecordProjectForm>;
  LFor: Integer;
  LFacade: IMCPWorkspaceFacade;
begin
  Result := '';
  // Facade unification (Passo 3): use the shared interface; the interface
  // reference frees itself, no explicit destructor call needed.
  LFacade := TMCPWorkspaceFacade.Create(0, '');
  LForms := LFacade.ListProjectForms;
  for LFor := 0 to High(LForms) do
    if SameText(LForms[LFor].Name, AUnitName)
      or SameText(LForms[LFor].Name + '.pas', AUnitName) then
      Exit(LForms[LFor].DfmPath);
end;

// ── Code Insight group (Epic 7/7 Demand 7/8, ADR-142/143) ────────────
// Source-text-only tools. Each method reads the unit body via the existing
// OTA path (open-editor first, then disk fallback) and delegates parsing to
// Aefos.MCP.PasParser (zero ToolsAPI dependency).

// Reads the source of a unit by name, trying open editors first then disk.
function _ReadUnitSourceByName(const AUnitName: string;
  out AFilePath: string; out ASource: string): Boolean;
var
  LModule: IOTAModule;
  LSource: IOTASourceEditor;
begin
  Result := False;
  AFilePath := '';
  ASource := '';
  if not _ResolveUnitModule(AUnitName, LModule) then
    Exit;
  AFilePath := LModule.FileName;
  LSource := _ModuleSourceEditor(LModule);
  if Assigned(LSource) then
  begin
    ASource := _ReadEditorBody(LSource);
    if ASource <> '' then
      Exit(True);
  end;
  if (AFilePath <> '') and TFile.Exists(AFilePath) then
  begin
    try
      ASource := TFile.ReadAllText(AFilePath, TEncoding.UTF8);
      Result := ASource <> '';
    except
      ASource := '';
      Result := False;
    end;
  end;
end;

// Enumerates every `.pas` path in the active project (by IOTAProject scan).
function _EnumerateProjectUnitPaths: TArray<string>;
var
  LServices: IOTAModuleServices;
  LProject: IOTAProject;
  LFor: Integer;
  LModuleInfo: IOTAModuleInfo;
  LList: TList<string>;
begin
  SetLength(Result, 0);
  LList := TList<string>.Create;
  try
    if not _TryGetModuleServices(LServices) then
      Exit;
    LProject := LServices.GetActiveProject;
    if not Assigned(LProject) then
      Exit;
    for LFor := 0 to LProject.GetModuleCount - 1 do
    begin
      LModuleInfo := LProject.GetModule(LFor);
      if not Assigned(LModuleInfo) then
        Continue;
      if SameText(ExtractFileExt(LModuleInfo.FileName), '.pas') then
        LList.Add(LModuleInfo.FileName);
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

// Returns the signature with `ClassName.` injected after the routine keyword,
// or ASignature unchanged when no class qualifier applies / is already there.
function _QualifyMethodSignature(const AClassName, ASignature: string): string;
const
  CKeywords: array[0..3] of string = (
    'procedure ', 'function ', 'constructor ', 'destructor ');
var
  LLower: string;
  LFor: Integer;
begin
  Result := ASignature;
  if (AClassName = '') or (Pos('.', ASignature) > 0) then
    Exit;
  LLower := LowerCase(ASignature);
  for LFor := 0 to High(CKeywords) do
    if Pos(CKeywords[LFor], LLower) = 1 then
    begin
      Result := CKeywords[LFor] + AClassName + '.'
        + Copy(ASignature, Length(CKeywords[LFor]) + 1, MaxInt);
      Exit;
    end;
end;

// Builds the implementation-side method skeleton.
function _BuildImplementationBlock(const AClassName, ASignature,
  ABody: string): string;
var
  LSig, LBody: string;
begin
  LSig := Trim(ASignature);
  if (LSig <> '') and (LSig[Length(LSig)] = ';') then
    SetLength(LSig, Length(LSig) - 1);
  LSig := _QualifyMethodSignature(AClassName, LSig);
  LBody := Trim(ABody);
  if LBody = '' then
    Result := LSig + ';' + sLineBreak + 'begin' + sLineBreak + 'end;'
  else
    Result := LSig + ';' + sLineBreak + LBody;
end;

// Locates the offset of the implementation section's final `end.` past
// AImplPos. Returns 0 when not found.
function _FindUnitFinalEnd(const ASource, ALowerSrc: string;
  const AImplPos: Integer): Integer;
begin
  Result := AImplPos;
  repeat
    Result := PosEx('end', ALowerSrc, Result + 1);
  until (Result = 0)
    or ((Result + 3 <= Length(ASource)) and (ASource[Result + 3] = '.'));
end;

// Trims a trailing ';' from a signature in place. No-op when absent.
function _StripTrailingSemicolon(const ASig: string): string;
begin
  Result := ASig;
  if (Result <> '') and (Result[Length(Result)] = ';') then
    SetLength(Result, Length(Result) - 1);
end;

// Computes the anchor offsets used by InsertMethod. Returns False with
// AReason set when either anchor cannot be located.
function _ComputeInsertMethodAnchors(const ASource: string;
  out AImplAnchor: Integer; out AReason: string): Boolean;
var
  LLowerSrc: string;
  LImplPos, LFinalEnd: Integer;
begin
  Result := False;
  AImplAnchor := 0;
  LLowerSrc := LowerCase(ASource);
  LImplPos := Pos('implementation', LLowerSrc);
  if LImplPos = 0 then
  begin
    AReason := 'anchor-mismatch';
    Exit;
  end;
  LFinalEnd := _FindUnitFinalEnd(ASource, LLowerSrc, LImplPos);
  if LFinalEnd = 0 then
  begin
    AReason := 'anchor-mismatch';
    Exit;
  end;
  AImplAnchor := LFinalEnd;
  Result := True;
end;

// Reads the .pas file text; returns False on any IO/encoding error.
function _TryReadUnitText(const APath: string; out AText: string): Boolean;
begin
  Result := False;
  try
    AText := TFile.ReadAllText(APath, TEncoding.UTF8);
    Result := True;
  except
    AText := '';
  end;
end;

// Scans the project unit paths and returns the parent class declared for
// AClassName, or '' when none was found in the corpus.
function _LookupParentClassAcrossUnits(const APaths: TArray<string>;
  const AClassName: string): string;
var
  LFor: Integer;
  LSource: string;
  LTokens: TArray<TPasToken>;
begin
  Result := '';
  for LFor := 0 to High(APaths) do
  begin
    if not _TryReadUnitText(APaths[LFor], LSource) then
      Continue;
    LTokens := TPasParser.Tokenize(LSource);
    Result := TPasParser.FindParentClassName(LTokens, AClassName);
    if Result <> '' then
      Exit;
  end;
end;

// ── Project Group group (Epic 7/7 Demand 7/8, ADR-142/144) ────────────

function _TryGetProjectGroup(out AGroup: IOTAProjectGroup): Boolean;
var
  LServices: IOTAModuleServices;
  LFor: Integer;
  LModule: IOTAModule;
begin
  AGroup := nil;
  Result := False;
  if not _TryGetModuleServices(LServices) then
    Exit;
  for LFor := 0 to LServices.ModuleCount - 1 do
  begin
    LModule := LServices.Modules[LFor];
    if Supports(LModule, IOTAProjectGroup, AGroup) then
      Exit(True);
  end;
end;

// Returns True when ANode is a `<Projects Include="ARelPath" />` element.
function _IsProjectsNodeForPath(const ANode: IXMLNode;
  const ARelPath: string): Boolean;
begin
  Result := SameText(ANode.NodeName, 'Projects')
    and SameText(ANode.Attributes['Include'], ARelPath);
end;

// Adds a `<Projects Include="ARelPath" />` child to AItemGroup. No-op when
// already present (idempotent). Returns True when the node already existed.
function _AddProjectNode(const AItemGroup: IXMLNode; const ARelPath: string;
  out AChanged: Boolean): Boolean;
var
  LChildIdx: Integer;
  LChild, LNew: IXMLNode;
begin
  AChanged := False;
  for LChildIdx := 0 to AItemGroup.ChildNodes.Count - 1 do
  begin
    LChild := AItemGroup.ChildNodes[LChildIdx];
    if _IsProjectsNodeForPath(LChild, ARelPath) then
      Exit(True);
  end;
  LNew := AItemGroup.AddChild('Projects');
  LNew.Attributes['Include'] := ARelPath;
  AChanged := True;
  Result := False;
end;

// Removes every `<Projects Include="ARelPath" />` child from AItemGroup.
// Sets AChanged when at least one was removed.
procedure _RemoveProjectNode(const AItemGroup: IXMLNode;
  const ARelPath: string; var AChanged: Boolean);
var
  LChildIdx: Integer;
  LChild: IXMLNode;
begin
  for LChildIdx := AItemGroup.ChildNodes.Count - 1 downto 0 do
  begin
    LChild := AItemGroup.ChildNodes[LChildIdx];
    if _IsProjectsNodeForPath(LChild, ARelPath) then
    begin
      AItemGroup.ChildNodes.Delete(LChildIdx);
      AChanged := True;
    end;
  end;
end;

// Rewrites the .groupproj XML, mutating the <Projects> children via
// IXMLDocument (ADR-141 atomic pattern). AKind ∈ {'add','remove'}.
function _MutateGroupProjFile(const AGroupProjPath, AProjectPath,
  AKind: string; out AChanged: Boolean): Boolean;
var
  LXml: IXMLDocument;
  LRoot, LItemGroup: IXMLNode;
  LFor: Integer;
  LRelPath: string;
  LAlreadyPresent: Boolean;
begin
  Result := False;
  AChanged := False;
  LXml := TXMLDocument.Create(nil);
  try
    LXml.LoadFromFile(AGroupProjPath);
    LRoot := LXml.DocumentElement;
    if not Assigned(LRoot) then
      Exit;
    LRelPath := ExtractRelativePath(ExtractFilePath(AGroupProjPath),
      AProjectPath);
    if LRelPath = '' then
      LRelPath := AProjectPath;
    // Locate every <ItemGroup> that holds <Projects> children.
    for LFor := 0 to LRoot.ChildNodes.Count - 1 do
    begin
      LItemGroup := LRoot.ChildNodes[LFor];
      if not SameText(LItemGroup.NodeName, 'ItemGroup') then
        Continue;
      if SameText(AKind, 'add') then
      begin
        LAlreadyPresent := _AddProjectNode(LItemGroup, LRelPath, AChanged);
        if LAlreadyPresent then
          Exit(True);  // idempotent
      end
      else if SameText(AKind, 'remove') then
        _RemoveProjectNode(LItemGroup, LRelPath, AChanged);
    end;
    LXml.SaveToFile(AGroupProjPath);
    Result := True;
  finally
    LXml := nil;
  end;
end;

function _ActiveGroupProjPath: string;
var
  LGroup: IOTAProjectGroup;
begin
  Result := '';
  if _TryGetProjectGroup(LGroup) then
    Result := LGroup.FileName;
end;

// ── Packages + IDE + Resources (Epic 7/7 Demand 8/8, ADR-145..ADR-147) ──
// Reads return sentinels (`[]`, `''`) when no active project or option is
// available; mutations return False with AReason set. Exceptions never
// cross the MCP boundary (BR-3). XML mutation of `.dproj` for package
// references uses the ADR-141 snapshot-and-revert pattern.

// Snapshot-and-revert pattern (ADR-141): mutate the `.dproj` via XML; if
// anything fails after the load, restore the original file content.
function _MutateDProjPackage(const ADProjPath, APackageRef: string;
  const ARuntime: Boolean; const AOperation: string;
  out AChanged: Boolean): Boolean;
var
  LDoc: IXMLDocument;
  LRoot, LGroup, LNode, LTarget: IXMLNode;
  LGroupIdx, LNodeIdx: Integer;
  LSnapshot: string;
  LTagName: string;
  LText, LJoined: string;
  LTokens: TArray<string>;
  LBuilder: TStringBuilder;
  LFor: Integer;
  LFound: Boolean;
begin
  Result := False;
  AChanged := False;
  if not TFile.Exists(ADProjPath) then
    Exit;
  LSnapshot := TFile.ReadAllText(ADProjPath, TEncoding.UTF8);
  try
    LDoc := TXMLDocument.Create(nil);
    LDoc.LoadFromFile(ADProjPath);
    LRoot := LDoc.DocumentElement;
    if not Assigned(LRoot) then
      Exit;
    if ARuntime then
      LTagName := 'RuntimePackages'
    else
      LTagName := 'DCC_UsePackage';
    LTarget := nil;
    for LGroupIdx := 0 to LRoot.ChildNodes.Count - 1 do
    begin
      LGroup := LRoot.ChildNodes[LGroupIdx];
      for LNodeIdx := 0 to LGroup.ChildNodes.Count - 1 do
      begin
        LNode := LGroup.ChildNodes[LNodeIdx];
        if SameText(LNode.NodeName, LTagName) then
        begin
          LTarget := LNode;
          Break;
        end;
      end;
      if Assigned(LTarget) then
        Break;
    end;
    if not Assigned(LTarget) then
    begin
      // Add operation creates a new node under the first PropertyGroup.
      if SameText(AOperation, 'remove') then
        Exit(True);
      if LRoot.ChildNodes.Count = 0 then
        Exit;
      LGroup := LRoot.ChildNodes[0];
      LTarget := LGroup.AddChild(LTagName);
      LTarget.Text := APackageRef;
      AChanged := True;
      LDoc.SaveToFile(ADProjPath);
      Exit(True);
    end;
    LText := LTarget.Text;
    LTokens := LText.Split([';']);
    LFound := False;
    for LFor := 0 to High(LTokens) do
      if SameText(Trim(LTokens[LFor]), APackageRef) then
      begin
        LFound := True;
        Break;
      end;
    if SameText(AOperation, 'add') then
    begin
      if LFound then
        Exit(True);  // idempotent (BR-3)
      if Trim(LText) = '' then
        LJoined := APackageRef
      else
        LJoined := LText + ';' + APackageRef;
      LTarget.Text := LJoined;
      AChanged := True;
    end
    else if SameText(AOperation, 'remove') then
    begin
      if not LFound then
        Exit(True);  // idempotent on absent (BR-3)
      LBuilder := TStringBuilder.Create;
      try
        for LFor := 0 to High(LTokens) do
        begin
          if Trim(LTokens[LFor]) = '' then
            Continue;
          if SameText(Trim(LTokens[LFor]), APackageRef) then
            Continue;
          if LBuilder.Length > 0 then
            LBuilder.Append(';');
          LBuilder.Append(Trim(LTokens[LFor]));
        end;
        LTarget.Text := LBuilder.ToString;
      finally
        LBuilder.Free;
      end;
      AChanged := True;
    end;
    LDoc.SaveToFile(ADProjPath);
    Result := True;
  except
    // Snapshot-and-revert per ADR-141.
    try
      TFile.WriteAllText(ADProjPath, LSnapshot, TEncoding.UTF8);
    except
    end;
    Result := False;
    AChanged := False;
  end;
end;

// Reads the IDE LibraryPath option for the active platform. The option key
// is `LibraryPath` on IOTAServices.GetEnvironmentOptions; semicolon-split
// into a string array.
function _ReadIDELibraryPathRaw: string;
var
  LServices: IOTAServices;
  LOptions: IOTAEnvironmentOptions;
begin
  Result := '';
  if not Assigned(BorlandIDEServices) then
    Exit;
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then
    Exit;
  try
    LOptions := LServices.GetEnvironmentOptions;
    if not Assigned(LOptions) then
      Exit;
    Result := VarToStr(LOptions.Values['LibraryPath']);
  except
    Result := '';
  end;
end;

function _BuildModuleNode(const AModule: IOTAModule;
  const ADepth: Integer): TMCPRecordProjectManagerNode;
begin
  Result := Default(TMCPRecordProjectManagerNode);
  if not Assigned(AModule) then
    Exit;
  Result.Name := TPath.GetFileName(AModule.FileName);
  Result.Kind := 'module';
  SetLength(Result.Children, 0);
end;

function _BuildProjectNode(const AProject: IOTAProject;
  const ADepth: Integer): TMCPRecordProjectManagerNode;
var
  LFor, LCount: Integer;
  LModule: IOTAModuleInfo;
  LModuleServices: IOTAModuleServices;
  LRealModule: IOTAModule;
  LList: TList<TMCPRecordProjectManagerNode>;
  LTruncated: TMCPRecordProjectManagerNode;
begin
  Result := Default(TMCPRecordProjectManagerNode);
  if not Assigned(AProject) then
    Exit;
  Result.Name := TPath.GetFileNameWithoutExtension(AProject.FileName);
  Result.Kind := 'project';
  if ADepth >= 8 then
  begin
    LTruncated := Default(TMCPRecordProjectManagerNode);
    LTruncated.Name := '...';
    LTruncated.Kind := 'truncated';
    SetLength(Result.Children, 1);
    Result.Children[0] := LTruncated;
    Exit;
  end;
  LList := TList<TMCPRecordProjectManagerNode>.Create;
  try
    if not _TryGetModuleServices(LModuleServices) then
      Exit;
    LCount := AProject.GetModuleCount;
    for LFor := 0 to LCount - 1 do
    begin
      LModule := AProject.GetModule(LFor);
      if not Assigned(LModule) then
        Continue;
      LRealModule := LModuleServices.FindModule(LModule.FileName);
      if Assigned(LRealModule) then
        LList.Add(_BuildModuleNode(LRealModule, ADepth + 1));
    end;
    Result.Children := LList.ToArray;
  finally
    LList.Free;
  end;
end;

function _BuildCmdLine(const AArgv: TArray<string>): string;
var
  LBuilder: TStringBuilder;
  LFor: Integer;
  LToken: string;
begin
  // BR-5: argv passed as `string[]`; we wrap each token in double quotes
  // (escaping internal quotes) so shell metacharacters in arguments do not
  // invoke a shell. CreateProcessW parses argv internally.
  LBuilder := TStringBuilder.Create;
  try
    for LFor := 0 to High(AArgv) do
    begin
      if LFor > 0 then
        LBuilder.Append(' ');
      LToken := StringReplace(AArgv[LFor], '"', '\"', [rfReplaceAll]);
      LBuilder.Append('"');
      LBuilder.Append(LToken);
      LBuilder.Append('"');
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

// Returns the active project's `.dproj` path ('' when none). Used by the
// rename/move cascade to fix `<DCCReference>`/`<MainSource>` references.
function _ActiveDProjPath: string;
var
  LProject: IOTAProject;
begin
  Result := '';
  if not _TryGetActiveProject(LProject) then
    Exit;
  if SameText(ExtractFileExt(LProject.FileName), '.dproj') then
    Result := LProject.FileName
  else
    Result := ChangeFileExt(LProject.FileName, '.dproj');
  if not TFile.Exists(Result) then
    Result := '';
end;


const
  REANCHOR_DEBOUNCE_MS = 400;

{ TMCPModuleSaveNotifier }

constructor TMCPModuleSaveNotifier.Create(const AOnSaved: TMCPSaveCallback);
begin
  inherited Create;
  FOnSaved := AOnSaved;
end;

procedure TMCPModuleSaveNotifier.AfterSave;
begin
  if Assigned(FOnSaved) then
    FOnSaved();
end;

function TMCPModuleSaveNotifier.CheckOverwrite: Boolean;
begin
  Result := True;
end;

procedure TMCPModuleSaveNotifier.ModuleRenamed(const NewName: string);
begin
end;

{ TMCPReAnchorObserver }

constructor TMCPReAnchorObserver.Create(const ANotifier: IMCPReAnchorNotifier);
begin
  inherited Create;
  FNotifier := ANotifier;
  FEditIndex := -1;
  FSaveIndex := -1;
  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False;
  FTimer.Interval := REANCHOR_DEBOUNCE_MS;
  FTimer.OnTimer := _OnDebounceTimer;
end;

destructor TMCPReAnchorObserver.Destroy;
begin
  FTimer.Free;
  inherited;
end;

procedure TMCPReAnchorObserver.Activate;
begin
  // Registered after the observer is held by a strong interface reference
  // so passing Self as IOTAEditorServicesNotifier is lifetime-safe.
  if not Assigned(BorlandIDEServices) then
    Exit;
  FEditIndex := (BorlandIDEServices as IOTAEditorServices).AddNotifier(Self);
end;

procedure TMCPReAnchorObserver.Shutdown;
begin
  if Assigned(FTimer) then
    FTimer.Enabled := False;
  _DetachSaveNotifier;
  if Assigned(BorlandIDEServices) then
  begin
    if FEditIndex >= 0 then
      (BorlandIDEServices as IOTAEditorServices).RemoveNotifier(FEditIndex);
  end;
  FEditIndex := -1;
  FNotifier := nil;
end;

procedure TMCPReAnchorObserver._Fire(const AEvent: TMCPReAnchorEvent);
begin
  // An observer must never destabilise the IDE — swallow any failure.
  try
    if Assigned(FNotifier) then
      FNotifier.NotifyEvent(AEvent);
  except
  end;
end;

procedure TMCPReAnchorObserver._ArmCursorDebounce;
begin
  _Fire(raCursorMoved);
  if Assigned(FTimer) then
  begin
    FTimer.Enabled := False;
    FTimer.Enabled := True;
  end;
end;

procedure TMCPReAnchorObserver._OnDebounceTimer(Sender: TObject);
begin
  if Assigned(FTimer) then
    FTimer.Enabled := False;
  try
    if Assigned(FNotifier) then
      FNotifier.Flush;
  except
  end;
end;

procedure TMCPReAnchorObserver._DetachSaveNotifier;
begin
  if Assigned(FSaveModule) and (FSaveIndex >= 0) then
  try
    FSaveModule.RemoveNotifier(FSaveIndex);
  except
  end;
  FSaveModule := nil;
  FSaveIndex := -1;
end;

procedure TMCPReAnchorObserver._TrackModuleForSave(const AFileName: string);
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
begin
  // Keep exactly one module save-notifier, re-pointed at the active unit.
  if AFileName = '' then
    Exit;
  if not _TryGetModuleServices(LModuleServices) then
    Exit;
  LModule := LModuleServices.FindModule(AFileName);
  if not Assigned(LModule) then
    Exit;
  _DetachSaveNotifier;
  FSaveIndex := LModule.AddNotifier(TMCPModuleSaveNotifier.Create(
    procedure
    begin
      _Fire(raFileSaved);
    end));
  FSaveModule := LModule;
end;



procedure TMCPReAnchorObserver.EditorViewActivated(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
var
  LCurrentRoot: string;
begin
  _Fire(raActiveEditorChanged);
  if Assigned(EditView) and Assigned(EditView.Buffer) then
    _TrackModuleForSave(EditView.Buffer.FileName);

  LCurrentRoot := _ResolveActiveProjectRoot;
  if (LCurrentRoot <> '') and (LCurrentRoot <> GLastResolvedProjectRoot) then
  begin
    _Fire(raProjectSwitched);
    _ResolveExecutorGraph;
  end;
end;

procedure TMCPReAnchorObserver.EditorViewModified(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
  // No OTA cursor-move event exists; a buffer edit is the cursor-activity
  // proxy. The debounce timer coalesces a burst into one cursor re-anchor.
  _ArmCursorDebounce;
end;

procedure TMCPReAnchorObserver.WindowShow(const EditWindow: INTAEditWindow;
  Show, LoadedFromDesktop: Boolean);
begin
end;

procedure TMCPReAnchorObserver.WindowNotification(
  const EditWindow: INTAEditWindow; Operation: TOperation);
begin
end;

procedure TMCPReAnchorObserver.WindowActivated(
  const EditWindow: INTAEditWindow);
begin
end;

procedure TMCPReAnchorObserver.WindowCommand(const EditWindow: INTAEditWindow;
  Command, Param: Integer; var Handled: Boolean);
begin
end;

procedure TMCPReAnchorObserver.DockFormVisibleChanged(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure TMCPReAnchorObserver.DockFormUpdated(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure TMCPReAnchorObserver.DockFormRefresh(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

var
  GWorkspaceFacade: IMCPWorkspaceFacade;
  { Visual Scanner. One reporter for the BPL, because it keys its sessions by the
    window being driven -- two MCP servers in this process (the chat's and the
    terminal's) driving the same window are still one thing happening to it, and
    two reporters would draw two cards for it. Freed at teardown: it holds a
    closure the server calls, and an IDE-held pointer into an unmapped BPL is the
    crash class the IDE-UNLOAD rules exist to prevent. }
  GVisualReporter: TAefosVisualReporter = nil;
  GGitFacade: IMCPGitFacade;
  GReAnchorObserver: IMCPReAnchorObserver;

// Formats the active-project facade record as the project/active resource.
function _FormatActiveProject(const AInfo: TMCPActiveProjectInfo): string;
begin
  if not AInfo.Available then
    Exit('');
  Result := Format('name: %s'#10'path: %s'#10'platform: %s',
    [AInfo.Name, AInfo.Path, AInfo.TargetPlatform]);
end;

// Formats the cursor + selection facade reads as the cursor resource.
function _FormatCursor(const ACursor: TMCPCursorInfo;
  const ASelection: TMCPSelectionInfo): string;
begin
  if not ACursor.Available then
    Exit('');
  Result := Format('unit: %s'#10'line: %d'#10'column: %d',
    [ACursor.UnitPath, ACursor.Line, ACursor.Column]);
  if ASelection.Available then
    Result := Result + #10 + 'selection: ' + ASelection.Text;
end;

// Builds a resource descriptor whose provider marshals a facade read to the
// IDE main thread (BR-13, ADR-057).
function _MakeResource(const AUri, AName, AMimeType: string;
  const AProvider: TMCPResourceProvider): TMCPResourceDescriptor;
begin
  Result := Default(TMCPResourceDescriptor);
  Result.Uri := AUri;
  Result.Name := AName;
  Result.MimeType := AMimeType;
  Result.Provider := AProvider;
end;

procedure _ShutdownReAnchorObserver;
begin
  if Assigned(GReAnchorObserver) then
  begin
    GReAnchorObserver.Shutdown;
    GReAnchorObserver := nil;
  end;
end;

// Registers the three OTA-context resources on ARegistry. Each provider
// marshals its facade read to the IDE main thread.
procedure _RegisterContextResources(const ARegistry: IMCPResourceRegistry);
begin
  ARegistry.Register(_MakeResource(MCP_RES_ACTIVE_PROJECT,
    'Active project', 'text/plain',
    function: string
    var
      LText: string;
    begin
      LText := '';
      TThread.Synchronize(nil, TThreadProcedure(procedure
        begin
          LText := _FormatActiveProject(GWorkspaceFacade.GetActiveProject);
        end));
      Result := LText;
    end));
  ARegistry.Register(_MakeResource(MCP_RES_ACTIVE_UNIT,
    'Active unit', 'text/x-pascal',
    function: string
    var
      LText: string;
    begin
      LText := '';
      TThread.Synchronize(nil, TThreadProcedure(procedure
        begin
          LText := GWorkspaceFacade.GetActiveUnit;
        end));
      Result := LText;
    end));
  ARegistry.Register(_MakeResource(MCP_RES_CURSOR,
    'Cursor position', 'text/plain',
    function: string
    var
      LText: string;
    begin
      LText := '';
      TThread.Synchronize(nil, TThreadProcedure(procedure
        begin
          LText := _FormatCursor(GWorkspaceFacade.GetCursorPosition,
            GWorkspaceFacade.GetSelection);
        end));
      Result := LText;
    end));
end;

// Epic 2/3 Demand 1/5 — WebView2 chat-inspector facade (ADR-215). The surface
// resolver returns the LIVE panel surface (ChatPanelSurface), NOT GOutputPanel:
// the proxy behind GOutputPanel implements only IOutputPanelSurface, so the
// facade's IOutputPanelInspector probe on it failed unconditionally —
// GetChatPanelHTML/EvalChatPanelScript reported no-panel even with a live chat.
// ChatPanelSurface is nil until the panel exists (correctly no-panel) and never
// force-creates it. The consent resolver shows the destructive-action modal on
// the IDE main thread, identical to TOTAFacade.RequestConsent. The async->sync
// WebView2 bridge lives in the facade itself (ADR-216).
function _BuildChatInspectorFacade: IMCPChatInspectorFacade;
begin
  Result := TChatInspectorFacade.Create(
    function: IOutputPanelSurface
    begin
      Result := TChatPanelHost.ChatPanelSurface;
    end,
    function(AToolName, ASummary, ADetail: string): TMCPConsentDecision
    begin
      Result := TMCPConsentDialog.Execute(AToolName, ASummary, ADetail);
    end);
end;

// Root scanned for drop-a-folder Python tools (pytools\<tool>\tool.json): a fixed
// per-user dir next to the other Aefos user data (%AppData%\Aefos\
// pytools). Empty/missing registers nothing.
function _PyToolsRoot: string;
begin
  Result := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'), 'pytools');
end;

// Root of the file-based project-template library (templates\<id>\template.json),
// next to the other Aefos user data. Empty/missing registers no templates.
function _TemplatesRoot: string;
begin
  Result := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'), 'templates');
end;

// Resolves the shipped Agent CLI (AefosAgent.exe) that drives local models
// (Phase D). Candidate order: the per-user provisioned/installed bin, then
// next to the loaded design-time BPL, then PATH (dev convenience). '' when
// none exists -> the standard CLI-not-found guard fires with the profile hint.
function _ResolveAgentCliPath: string;
var
  LCand: string;
begin
  LCand := TPath.Combine(TPath.Combine(TPath.Combine(
    GetEnvironmentVariable('APPDATA'), 'Aefos'), 'bin'), 'AefosAgent.exe');
  if TFile.Exists(LCand) then
    Exit(LCand);
  LCand := TPath.Combine(ExtractFilePath(GetModuleName(HInstance)),
    'AefosAgent.exe');
  if TFile.Exists(LCand) then
    Exit(LCand);
  Result := ResolveCLIBinary('', 'AefosAgent.exe');
end;

procedure _InitCommandExecutor;
var
  LDispatcher: ICLIDispatcher;
begin
  // Every executor - including ekOllama - now dispatches through the process
  // CLI dispatcher (Phase D): local models are driven by the shipped
  // AefosAgent.exe, so the old in-process HTTP dispatcher is gone. The executor
  // itself is dispatcher-agnostic.
  LDispatcher := GCLIDispatcher;
  GCommandExecutor := TCommandExecutor.Create(
    GCommandRegistry, GContextBuilder, LDispatcher, GOutputPanel,
    function: string
    var
      LExecutorPath: string;
    begin
      LExecutorPath := '';
      if Assigned(GConfig) then
        LExecutorPath := Trim(GConfig.Snapshot.ExecutorPath);
      // Local models run our shipped AefosAgent.exe. The path field is an
      // OPTIONAL override (a custom/dev build): honour it ONLY when it actually
      // points at an Aefos agent binary. The ExecutorPath config field is
      // SHARED across executor kinds, so after switching (Claude -> Ollama) it
      // can still hold a foreign CLI - honouring that verbatim spawned
      // claude.exe with the Ollama arg grammar (field report 2026-07-10:
      // "--permission-mode auto-edits is invalid ... acceptEdits, ...").
      // A stale/foreign path falls through to the bundled/provisioned CLI.
      if GExecutorProfile.Kind = ekOllama then
      begin
        if (LExecutorPath <> '') and
          SameText(Copy(ExtractFileName(LExecutorPath), 1,
            Length('AefosAgent')), 'AefosAgent') then
          Exit(LExecutorPath);
        Exit(_ResolveAgentCliPath);
      end;
      Result := ResolveCLIBinary(LExecutorPath, GExecutorProfile.BinaryName);
    end,
    GExecutorProfile,
    function: TConfig
    begin
      if Assigned(GConfig) then
        Result := GConfig.Snapshot
      else
        Result := DefaultConfig;
    end,
    function: string
    begin
      // Working-dir resolver: run the chat's CLI in the active project's folder
      // so it auto-loads the project .mcp.json and reaches the MCP server.
      Result := _ResolveActiveProjectRoot;
    end);
end;

procedure _ShutdownCommandExecutor;
begin
  // Tear down the re-anchoring observer first so it never feeds a dead
  // publisher once the server is released (ADR-056, ESP R-7).
  _ShutdownReAnchorObserver;
  GCommandExecutor := nil;
  GWorkspaceFacade := nil;
  GGitFacade := nil;
end;

procedure _InitCommandPalette;
var
  LActions: IActionCatalog;
  LPaletteState: IPaletteState;
begin
  LActions := TActionCatalog.Create;
  LPaletteState := TPaletteStateService.Create(
    function: string
    begin
      Result := _ResolveActiveProjectRoot;
    end);
  GCommandPalette := TCommandPalette.Create(GCommandRegistry, LActions,
    LPaletteState);
end;

procedure _ShutdownCommandPalette;
begin
  GCommandPalette := nil;
end;

// ADR-117/119 (Epic 7/7 Demand 1/8): Inspector composition root helpers.
// The Inspector is dev-only — built lazily on first menu click and torn
// down in plugin finalization. A dedicated standalone MCP server is used
// (no re-anchor observer, no live named-pipe transport) so it does not
// interfere with the executor's per-dispatch server instances.

{ Builds the reporter on first need, wired to the live panel.

  The push is deliberately tolerant: the panel may not exist yet, may be mid
  reload, or may be gone. A visual card is never worth an exception on a path
  the MCP server calls, so a missing panel simply drops the frame -- the
  broadcaster still holds the session, so the next real move repaints a card
  that is up to date rather than one that replays a stale step. }
procedure _EnsureVisualReporter;
begin
  if Assigned(GVisualReporter) then
    Exit;
  GVisualReporter := TAefosVisualReporter.Create(
    TAefosVisualBroadcast.Create(
      procedure(const APayloadJson: string)
      begin
        try
          if Assigned(GChatPanel) and not GChatPanelShuttingDown then
            GChatPanel.EnqueueScannerPayload(APayloadJson);
        except
          // A drawing concern must not surface on the tool path.
        end;
      end),
    True); // owns the broadcaster: they live and die together
  GVisualReporter.ImagePush :=
    procedure(const AImageId, ADataUri: string)
    begin
      try
        if Assigned(GChatPanel) and not GChatPanelShuttingDown then
          GChatPanel.EnqueueScannerImage(AImageId, ADataUri);
      except
        // Same tolerance as the payload push: never on the tool path.
      end;
    end;
end;

function _BuildInspectorMcpServer: IMCPServer;
var
  LServer: IMCPServer;
  LBuildManager: IMCPBuildManager;
  LRegistry: IMCPResourceRegistry;
  LAuditLog: IMCPAuditLog;
  LFacade: IMCPWorkspaceFacade;
begin
  // Mirrors _BuildMcpServer minus the re-anchor observer wiring: the
  // Inspector has no subscribing MCP client to notify, so the observer is
  // unnecessary and would otherwise contend with the executor's observer
  // lifecycle.
  LBuildManager := TMCPBuildManager.Create;
  if not Assigned(GWorkspaceFacade) then
    // Facade unification (Passo 3): single shared facade from Tools.OTA.
    // (0, '') = indefinite consent wait + default audit path — matches the
    // legacy TOTAFacade's blocking-modal consent behaviour exactly.
    GWorkspaceFacade := TMCPWorkspaceFacade.Create(0, '');
  // Capture a STABLE local ref for the view-provider closure. The closure must
  // NOT read the mutable unit-global GWorkspaceFacade: a later teardown nils
  // that global, and the next design/code command would then deref nil inside
  // the guard (AV in this closure — the RULE #1 regression). The interface
  // refcount on this local keeps the facade alive for the closure's whole life,
  // exactly how the tool handlers below capture it by value via RegisterTools.
  LFacade := GWorkspaceFacade;
  // One session id per Inspector server build too (ADR-263), so destructive
  // tools triggered through the dev Inspector carry a single correlation id.
  LAuditLog := TMCPAuditLog.Create(TMCPAuditLog.LogFilePath,
    TGUID.NewGuid.ToString);
  LRegistry := TMCPResourceRegistry.Create;
  _RegisterContextResources(LRegistry);
  LServer := TMCPServer.Create(
    function: IMCPTransport
    begin
      Result := TNamedPipeTransport.Create;
    end,
    procedure(const AProc: TThreadProcedure)
    begin
      TThread.Synchronize(nil, AProc);
    end,
    '0.6.0',
    LBuildManager as IMCPCancellationSink,
    LRegistry);
  // RULE #1: arm the intent guard so design/code commands are rejected when the
  // IDE is in the wrong view (each command is its own guardian, CLAUDE.md). Same
  // shared-facade read as the terminal host — one OTA implementation for both.
  LServer.SetViewProvider(
    function: TMCPToolIntent
    begin
      // Read the CAPTURED local (alive for the closure's life), never the
      // mutable unit-global — and guard nil so the guard degrades to tiNeutral
      // (allow) instead of AV'ing a design/code command.
      if Assigned(LFacade) then
        Result := LFacade.CurrentIdeViewIntent
      else
        Result := tiNeutral;
    end);
  // Addon-MCP gateway (ESP: `aefos install <mcp>` -> every agent). This same
  // server serves the live 'plugin' pipe the dispatched CLI connects to, so the
  // installed addons' tools reach EVERY executor (Claude, Codex, Gemini, Ollama,
  // ...) with no per-CLI wiring. nil-off by default elsewhere; here it is on.
  // True: THIS host draws the scanner card from these very calls, so its
  // children may be told a person is watching. The terminal hosts the same
  // gateway and draws nothing -- it passes nothing and claims nothing.
  LServer.SetToolGateway(TMCPAddonGateway.Create(True));
  // Watch those addon calls so the panel can show what the agent is doing to a
  // window. The gateway routes every desktop tool through THIS process, so the
  // report costs no new channel -- it is the call we were already making.
  _EnsureVisualReporter;
  LServer.SetVisualReport(
    procedure(const AToolName, AArgumentsJson, AResultJson: string;
      const AFailed: Boolean)
    begin
      if Assigned(GVisualReporter) then
        GVisualReporter.Report(AToolName, AArgumentsJson, AResultJson, AFailed);
    end);
  RegisterTools(LServer, GWorkspaceFacade, nil, LAuditLog, LBuildManager);
  // Inspector also surfaces the Project + Units + Editor + Build groups —
  // same registration order as _BuildMcpServer so the Inspector dropdown
  // matches live MCP. The shared session-stamped audit log flows in too.
  RegisterProjectTools(LServer, GWorkspaceFacade, nil, LAuditLog);
  RegisterUnitsTools(LServer, GWorkspaceFacade, nil, LAuditLog);
  RegisterEditorTools(LServer, GWorkspaceFacade, nil, LAuditLog);
  RegisterBuildTools(LServer, GWorkspaceFacade, nil, LAuditLog);
  // Agent debug family (breakpoints / state / step / continue / evaluate) -
  // this server serves the live 'plugin' pipe the dispatched CLI connects to,
  // so the tools reach the agent. OTA in Aefos.MCP.OTA.DebugService; guards in
  // the headless-tested DebugPolicy.
  RegisterDebugTools(LServer);
  // Epic 7/7 Demand 6/8 — Forms & DFM + DPR groups registered after the
  // Build group. tools/list returns 11 + 17 + 9 + 14 + 13 + 9 + 6 = 79.
  RegisterFormsDFMTools(LServer, GWorkspaceFacade);
  RegisterDPRTools(LServer, GWorkspaceFacade);
  // Epic 7/7 Demand 7/8 — Code Insight + Project Group. tools/list = 91.
  RegisterCodeInsightTools(LServer, GWorkspaceFacade);
  RegisterProjectGroupTools(LServer, GWorkspaceFacade);
  // Epic 7/7 Demand 8/8 — Packages + IDE + Resources. tools/list = 107.
  RegisterPackagesTools(LServer, GWorkspaceFacade);
  RegisterIDETools(LServer, GWorkspaceFacade);
  RegisterResourcesTools(LServer, GWorkspaceFacade);
  // Epic 1/3 Demand 1/5 — Git/VCS group. Inspector mirrors live MCP so the
  // dropdown shows the same 111 tools.
  if not Assigned(GGitFacade) then
    GGitFacade := TGitFacade.Create(
      function: string
      begin
        Result := _ResolveActiveProjectRoot;
      end);
  RegisterGitTools(LServer, GGitFacade);
  // IDE-ONLY VCS group (ShowDiffInIDE / GetFileHistory / GetDiffOfActiveFile):
  // the IDE's native diff viewer, its own file-history providers, and the DIRTY
  // buffer vs HEAD — the three things a terminal cannot reach. Shares the very
  // same git facade (no second one); OTA confined to DiffViewService.
  RegisterVCSTools(LServer, GGitFacade);
  // Epic 1/3 Demand 2/5 — Rename/Move cascade group. Inspector mirrors live
  // MCP so the dropdown shows the same 117 tools (+3 IDE-only VCS above).
  RegisterRenameTools(LServer, GWorkspaceFacade, nil, LAuditLog);
  // Epic 1/3 Demand 4/5 — Observability group (QueryAuditLog). Inspector
  // mirrors live MCP so the dropdown shows the same 118 tools.
  RegisterAuditQueryTools(LServer);
  // Epic 2/3 Demand 1/5 — WebView2 Inspection group (GetChatPanelHTML +
  // EvalChatPanelScript). Inspector mirrors live MCP → same 120 tools.
  RegisterChatInspectorTools(LServer, _BuildChatInspectorFacade, nil,
    LAuditLog);
  // Python tools (drop-a-folder): each pytools\<tool>\tool.json becomes a live
  // MCP tool, consent + audit gated. Empty/missing root registers nothing.
  RegisterPyTools(LServer, GWorkspaceFacade, nil, LAuditLog, _PyToolsRoot);
  // Project-wide text/encoding tools (ReplaceInProject / FixEncoding) wrapping
  // the rtl-pure Aefos.Tools engine; consent + audit gated.
  RegisterProjectTextTools(LServer, GWorkspaceFacade, nil, LAuditLog);
  // Project scaffolding (drop-a-folder templates): ListProjectTemplates +
  // CreateProjectFromTemplate, wrapping the rtl-pure engine; consent + audit.
  RegisterScaffoldTools(LServer, GWorkspaceFacade, nil, LAuditLog, _TemplatesRoot);
  // OTA-side tool: lets the agent fetch the user's gutter review annotations.
  // Must be registered HERE too (not only on the Terminal host) — the Chat-
  // launched CLI uses the 'plugin' session served by THIS server, so without
  // it /mcp shows 135 and GetReviewFeedback is uncallable from the chat flow.
  // The feedback queue (GReviewFeedback) is a process-global in the shared
  // GutterReview unit, so either host drains the same annotations.
  TGutterReview.RegisterReviewFeedbackTool(LServer);
  // Lets the agent see which of its edits are still pending in the review gutter
  // (applied to the buffer, not yet approved/rejected) — read-only, never blocks.
  TGutterReview.RegisterPendingReviewsTool(LServer);
  // OTA-side tool: the agent PROPOSES a bug/suggestion; a human-gated editable
  // dialog opens a pre-filled GitHub issue (it never files anything itself).
  RegisterProposeAefosIssueTool(LServer);
  Result := LServer;
end;

type
  // HTML consent presenter (Chat BPL). Implements the decoupled
  // IMCPConsentPresenter: shows the WebView2 modal and OWNS its own wait — pumps
  // the main-thread message loop until the user's 'perm:*' click resolves,
  // mirroring how a VCL ShowModal pumps. Declines (False) when not on the main
  // thread or the chat panel/WebView2 isn't ready, so the facade falls back to
  // the VCL modal. Each presentation thus owns its own thread model.
  THtmlConsentPresenter = class(TInterfacedObject, IMCPConsentPresenter)
    function TryRequestDecision(const AToolName, ASummary, ADetail: string;
      out ADecision: TMCPConsentDecision): Boolean;
  end;

function THtmlConsentPresenter.TryRequestDecision(const AToolName, ASummary,
  ADetail: string; out ADecision: TMCPConsentDecision): Boolean;
const
  CTimeoutMs = 300000; // 5 min cap; deny on timeout (safe default)
var
  LDecision: TMCPConsentDecision;
  LDone: Boolean;
  LStart: UInt64;
begin
  ADecision := cdDenied;
  Result := False;
  // Must be on the main thread (consent is marshalled there by the registrars).
  if TThread.CurrentThread.ThreadID <> MainThreadID then
    Exit;
  // No chat panel? Then render the SAME card in a borderless window of its own,
  // rather than declining to a VCL modal that merely resembles it. That is the
  // whole point: ONE renderer, so the prompt cannot drift depending on where it
  // happens to be shown.
  //
  // This route was reverted once (PR #390) because it pointed the window at the
  // panel's shell and loaded the ENTIRE chat page -- header, welcome screen,
  // composer -- so a consent request looked like a chat window opening by
  // itself. It is back now that the card has its OWN document
  // (TRenderProtocol.BuildConsentDocument): the card's CSS, its markup, its
  // script, and nothing else.
  //
  // A False from here still means "could not show", never "denied" -- the
  // facade then uses the VCL card, which stays as the floor for a machine with
  // no working WebView2.
  //
  // ON SCREEN, not merely existing. GChatPanel is set the first time a panel is
  // created and never returns to nil, so "Assigned" was true for a user who had
  // CLOSED the chat -- and the card then rendered into a hidden window and
  // reported success. The request was never seen and the five-minute timeout
  // denied it for them. IsWindowVisible rather than the VCL Visible property:
  // a panel the dock manager has hidden still reads Visible=True (the same trap
  // the dock reconciler ran into).
  if TAefosConsentModel.RoutesToOwnWindow(Assigned(GChatPanel),
       Assigned(GChatPanel) and GChatPanel.HandleAllocated and
       IsWindowVisible(GChatPanel.Handle)) then
    Exit(TAefosConsentWebForm.TryExecute(AToolName, ASummary, ADetail,
      CTimeoutMs, ADecision));
  LDecision := cdDenied;
  LDone := False;
  // Show the HTML modal; ShowPermission returns False if the WebView2 isn't
  // ready -> decline so the facade uses the VCL modal instead.
  if not GChatPanel.ShowPermission(AToolName, ASummary, ADetail,
       procedure(ADec: TMCPConsentDecision)
       begin
         LDecision := ADec;
         LDone := True;
       end) then
    Exit;
  // PUMP the loop until the click posts perm:* (sets LDone) or the cap elapses.
  // This presenter OWNS its threading; the shared facade stays UI-agnostic.
  LStart := GetTickCount64;
  while (not LDone) and (GetTickCount64 - LStart < CTimeoutMs) do
  begin
    CheckSynchronize;
    Application.ProcessMessages;
    Sleep(10);
  end;
  if not LDone then
    GChatPanel.CancelPermission; // timeout: hide modal + drop pending (deny)
  ADecision := LDecision;
  Result := True;
end;

procedure _InitDevSessionServer;
begin
  if Assigned(GDevSessionServer) then
    Exit;
  try
    GDevSessionServer := _BuildInspectorMcpServer;
    GDevSessionServer.Start(MCP_PIPE_PREFIX + 'plugin');
  except
    on E: Exception do
      OutputDebugString(PChar(
        'Aefos: dev session MCP start failed: ' + E.Message));
  end;
end;

// Build the inspector tool dropdown JSON ([{name, description}]) by dispatching
// a tools/list through the live server's IMCPInspectorHost surface.
function _InspectorToolsJson(const AHost: IMCPInspectorHost): string;
const
  CListFrame = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}';
var
  LVal: TJSONValue;
  LResult: TJSONObject;
  LTools, LOut: TJSONArray;
  LTool: TJSONValue;
  LToolObj, LOutObj: TJSONObject;
  LName: string;
begin
  Result := '[]';
  if not Assigned(AHost) then
    Exit;
  LVal := nil;
  try
    LVal := TJSONObject.ParseJSONValue(AHost.DispatchInspectorFrame(CListFrame));
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos: inspector tools/list failed: ' + E.Message));
  end;
  if not (LVal is TJSONObject) then
  begin
    LVal.Free;
    Exit;
  end;
  LOut := TJSONArray.Create;
  try
    if TJSONObject(LVal).TryGetValue<TJSONObject>('result', LResult)
      and LResult.TryGetValue<TJSONArray>('tools', LTools) then
      for LTool in LTools do
        if LTool is TJSONObject then
        begin
          LToolObj := TJSONObject(LTool);
          LName := LToolObj.GetValue<string>('name', '');
          if LName <> '' then
          begin
            LOutObj := TJSONObject.Create;
            LOutObj.AddPair('name', LName);
            LOutObj.AddPair('description', LToolObj.GetValue<string>('description', ''));
            LOut.AddElement(LOutObj);
          end;
        end;
    Result := LOut.ToJSON;
  finally
    LOut.Free;
    LVal.Free;
  end;
end;

// The SINGLE coupling point (ADR-117): wire the live dev-session server (as
// IMCPInspectorHost) + the audit path into the otherwise fully-decoupled bridge,
// then hand the bridge + the tools list to the WebView2 inspector window.
procedure OpenMcpInspector;
var
  LHost: IMCPInspectorHost;
  LBridge: IMCPInspectorBridge;
begin
  _InitDevSessionServer;
  if not (Assigned(GDevSessionServer)
    and Supports(GDevSessionServer, IMCPInspectorHost, LHost)) then
    Exit;
  LBridge := TMCPInspectorBridge.Create(LHost, TMCPAuditLog.LogFilePath);
  ShowMCPInspector(LBridge, _InspectorToolsJson(LHost));
end;

procedure _ShutdownDevSessionServer;
begin
  // Drop the global consent presenter first so its interface ref (which captures
  // GChatPanel) does not dangle past teardown ([[project_chat_bpl_unload]]).
  SetGlobalConsentPresenter(nil);
  if Assigned(GDevSessionServer) then
  begin
    GDevSessionServer.Stop;
    GDevSessionServer := nil;
  end;
end;

function _RunCommand(const ACommandName: string): Boolean;
var
  LEditorServices: IOTAEditorServices;
  LSelection: string;
  LCurrentRoot: string;
begin
  Result := False;
  LCurrentRoot := _ResolveActiveProjectRoot;
  // Build the executor graph on first use even with NO project open. The chat
  // menu registers at BPL load (Welcome page), so a user can open the chat and
  // send a message BEFORE opening any project. ADR-083 defers graph resolution
  // to the first project-open — which never fires here — leaving GCommandExecutor
  // nil and this proc silently Exiting: the user bubble was echoed, nothing
  // spawned, and the footer stayed on "ready" (empty assistant bubble). Execute()
  // already handles the no-project case (EProjectContextError -> "no project"
  // context). A later project-open still re-resolves for its context via the
  // root-change branch below.
  if (not Assigned(GCommandExecutor)) or
     ((LCurrentRoot <> '') and (LCurrentRoot <> GLastResolvedProjectRoot)) then
    _ResolveExecutorGraph;

  if not Assigned(GCommandExecutor) then
    Exit;
  LSelection := '';
  if Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
    if Assigned(LEditorServices.TopView) then
      LSelection := TAefosAgentSuggestAdapter.ReadSelectionText(
        LEditorServices.TopView);
  try
    GCommandExecutor.Execute(ACommandName, LSelection);
    Result := True;
  except
    on E: Exception do
    begin
      ShowMessage('Aefos command error: ' + E.Message);
      Result := False;
    end;
  end;
end;

procedure _InitMainMenu;
var
  LConfig: TMainMenuAdapterConfig;
begin
  LConfig.ReplicatorService := GCommandReplicator;
  LConfig.ReplicatorSurface := GOutputPanel;
  LConfig.ShowChat :=
    procedure
    begin
      TChatPanelHost.ShowChatPanel;
    end;
  TAefosMainMenuStaticAdapter.RegisterSelf(LConfig);
end;

procedure _ShutdownMainMenu;
begin
  TAefosMainMenuStaticAdapter.UnregisterSelf;
end;

// ── Top-level 'Aefos AI (Chat)' menu, built at BPL load (parity with the
// Terminal BPL's Wizard.CreateMenu) so Open Chat + About show on the Welcome
// page BEFORE any project is open — an explicit, repeated maintainer
// requirement: neither panel needs docking/projects to be useful. These are raw
// VCL items with lazy handlers; they never construct the executor-graph-coupled
// MainMenu adapter, so its non-nil-replicator contract is never exercised at
// load. The Ctrl+Alt+F11 replicate binding stays in the adapter (graph
// resolution). NOTE: the chronic rebuild AV was proven (map forensics
// 2026-06-11) to be keyboard bindings missing explicit removal — NOT this menu.
type
  // OnClick is a method pointer (`of object`); this carrier owns the two
  // load-time handlers (the composition root has no instance of its own, unlike
  // the Terminal Wizard). Lives for the BPL's lifetime; freed after the menu.
  TChatMenuHandlers = class
    procedure OpenClick(Sender: TObject);
    procedure AboutClick(Sender: TObject);
    procedure WebClick(Sender: TObject);
    procedure LicenseClick(Sender: TObject);
  end;

const
  // The product web page, opened by the "Aefos AI on the web" menu item. Kept
  // byte-identical to the Lazarus edition's cWebUrl (Aefos.Lazarus.Register)
  // so both editions link to the SAME page — menu parity, one product.
  ChatWebUrl     = 'https://www.pubpascal.dev';
  ChatWebCaption = 'Aefos AI on the web';

var
  GChatMenuItem: TMenuItem = nil;
  GChatMenuHandlers: TChatMenuHandlers = nil;

procedure TChatMenuHandlers.OpenClick(Sender: TObject);
begin
  TChatPanelHost.ShowChatPanel(True); // explicit user open -> force forward (recover a hidden dock)
end;

procedure TChatMenuHandlers.AboutClick(Sender: TObject);
begin
  ShowChatAboutDialog;
end;

procedure TChatMenuHandlers.WebClick(Sender: TObject);
begin
  // Open the product web page in the default browser (same shell-open idiom the
  // Options page uses for external links). Mirrors the Lazarus edition's
  // HandleWeb -> OpenURL so the "on the web" item behaves identically in both.
  ShellExecute(0, 'open', PChar(ChatWebUrl), nil, nil, SW_SHOWNORMAL);
end;


procedure TChatMenuHandlers.LicenseClick(Sender: TObject);
var
  LLabel: string;
begin
  // Opens the Aefos.License BPL's activation screen (passive runtime package).
  Aefos.License.Gate.TLicenseGate.ShowManager;
  // Refresh the menu caption so a just-activated/registered state shows without
  // restarting the IDE (Sender is the License menu item).
  if Sender is TMenuItem then
    try
      TMenuItem(Sender).Caption := Aefos.License.Gate.TLicenseGate.StatusText;
    except
    end;
  // Refresh the dock window title with the (possibly new) license type live.
  if Assigned(Aefos.OTA.Chat.UI.ChatPanel.GChatPanel) then
    try
      LLabel := Aefos.License.Gate.TLicenseGate.ShortLabel;
      if LLabel <> '' then
        Aefos.OTA.Chat.UI.ChatPanel.GChatPanel.Caption :=
          'Aefos Chat ' + #$2014 + ' ' + LLabel
      else
        Aefos.OTA.Chat.UI.ChatPanel.GChatPanel.Caption := 'Aefos Chat';
    except
    end;
end;

// The IDE 'View' menu (falls back to the menu-bar root), same host the adapter
// used before — no shared parent, unique caption, so this never touches the
// Terminal menu.
function _ChatMenuHost: TMenuItem;
var
  LServices: INTAServices;
  LMainMenu: TMainMenu;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, INTAServices, LServices) then
    Exit;
  LMainMenu := LServices.MainMenu;
  if not Assigned(LMainMenu) then
    Exit;
  Result := LMainMenu.Items.Find('View');
  if not Assigned(Result) then
    Result := LMainMenu.Items;
end;

// Stale-cleanup against a crashed unload that left the submenu behind.
procedure _RemoveChatMenu(const AParent: TMenuItem; const ACaption: string);
var
  LIndex: Integer;
begin
  if not Assigned(AParent) then
    Exit;
  for LIndex := AParent.Count - 1 downto 0 do
    if SameText(AParent.Items[LIndex].Caption, ACaption) then
      AParent.Items[LIndex].Free;
end;

procedure _InitChatMenuBar;
var
  LParent, LOpen, LSep, LLicense, LAbout, LWeb: TMenuItem;
begin
  LParent := _ChatMenuHost;
  if not Assigned(LParent) then
    Exit;
  _RemoveChatMenu(LParent, Aefos.OTA.Chat.Adapter.MainMenu.TopMenuCaption);

  GChatMenuHandlers := TChatMenuHandlers.Create;

  GChatMenuItem := TMenuItem.Create(LParent);
  GChatMenuItem.Caption := Aefos.OTA.Chat.Adapter.MainMenu.TopMenuCaption;

  LOpen := TMenuItem.Create(GChatMenuItem);
  LOpen.Caption := 'Open Chat';
  LOpen.OnClick := GChatMenuHandlers.OpenClick;
  GChatMenuItem.Add(LOpen);

  LSep := TMenuItem.Create(GChatMenuItem);
  LSep.Caption := '-';
  GChatMenuItem.Add(LSep);

  LLicense := TMenuItem.Create(GChatMenuItem);
  // Show the license state right in the menu, computed at LOAD so it is visible
  // from IDE startup (Trial/Free/Active...). Guarded — never break the menu.
  try
    LLicense.Caption := Aefos.License.Gate.TLicenseGate.StatusText;
  except
    LLicense.Caption := 'License' + #$2026;
  end;
  LLicense.OnClick := GChatMenuHandlers.LicenseClick;
  GChatMenuItem.Add(LLicense);

  LAbout := TMenuItem.Create(GChatMenuItem);
  LAbout.Caption := 'About Aefos AI' + #$2026;
  LAbout.OnClick := GChatMenuHandlers.AboutClick;
  GChatMenuItem.Add(LAbout);

  // Menu parity with the Lazarus edition: a link to the product web page, placed
  // right after About (same neighbour as Aefos.Lazarus.Register). Opens the SAME
  // URL both editions use.
  LWeb := TMenuItem.Create(GChatMenuItem);
  LWeb.Caption := ChatWebCaption;
  LWeb.OnClick := GChatMenuHandlers.WebClick;
  GChatMenuItem.Add(LWeb);

  LParent.Add(GChatMenuItem);
end;

procedure _ShutdownChatMenuBar;
var
  LParent: TMenuItem;
begin
  // Free the menu items first (they hold method pointers into GChatMenuHandlers),
  // then the handler carrier. Removing from the host never frees View itself.
  if Assigned(GChatMenuItem) then
  begin
    LParent := GChatMenuItem.Parent;
    if Assigned(LParent) then
      LParent.Remove(GChatMenuItem);
    FreeAndNil(GChatMenuItem);
  end;
  FreeAndNil(GChatMenuHandlers);
end;

procedure _InitAgentSuggestBinding;
begin
  TAefosAgentSuggestAdapter.RegisterSelf(GCommandExecutor, GOutputPanel);
  // Inline completion (ghost text). Wired here because it needs nothing from
  // the chat except to exist in the same design package; it owns its own
  // painter, keys and teardown. RegisterSelf never raises -- a completion
  // feature that cannot start must not stop the rest of Aefos loading.
  TAefosInlineGhost.RegisterSelf;
end;

procedure _ShutdownAgentSuggestBinding;
begin
  TAefosAgentSuggestAdapter.UnregisterSelf;
end;

// ADR-083/084/085: (re)resolves the config-and-executor graph. Guarded
// (BR-2) so a redundant event for an unchanged executor is a no-op;
// teardown-before-construct (BR-3) so the old executor's Destroy ->
// _CancelPrevious -> _StopMcpServer runs — cancelling any in-flight dispatch
// (BR-4) — before the new graph is built. Exception-safe (BR-7): a failure
// is logged, never raised into the IDE.
procedure _ResolveExecutorGraph;
var
  LDesiredKind: TExecutorKind;
  LCurrentKind: TExecutorKind;
  LHadProfile: Boolean;
  LCurrentRoot: string;
begin
  try
    LCurrentRoot := _ResolveActiveProjectRoot;
    if Assigned(GConfig) then
      GConfig.Load;
    LDesiredKind := ekClaude;
    if Assigned(GConfig) then
      LDesiredKind := GConfig.Snapshot.Executor;
    LHadProfile := Assigned(GExecutorProfile);
    LCurrentKind := ekClaude;
    if LHadProfile then
      LCurrentKind := GExecutorProfile.Kind;
    if not TProviderRegistry.ExecutorGraphNeedsReResolve(LHadProfile, LCurrentKind, LDesiredKind) and
       (LCurrentRoot = GLastResolvedProjectRoot) then
      Exit;
    // Teardown-before-construct (BR-3): release the old executor's holders
    // (AgentSuggest captures it by-value) so its interface refcount hits
    // zero and Destroy runs before the new graph is built.
    _ShutdownAgentSuggestBinding;
    _ShutdownCommandExecutor;
    _ShutdownCommandReplicator;
    _InitExecutorProfile;
    _InitCommandReplicator;
    _InitCommandExecutor;
    // Addon / global-command sync (2026-07-11): whenever the graph (re)resolves
    // — project open, first resolve, or an executor switch — mirror every
    // canonical command (project + the per-user global catalogue, which now
    // includes `aefos install`ed addons) to the active executor's replica dir.
    // So a freshly installed /command is usable immediately without a manual
    // save, AND a provider switch re-publishes the whole set to the new target
    // (fixes the "command doesn't follow me to the new executor" gap). Guarded:
    // no active project (no replication target) is benign — never abort the
    // graph setup on it.
    if Assigned(GCommandReplicator) then
      try
        GCommandReplicator.Replicate;
      except
        on E: Exception do
          OutputDebugString(PChar(
            'Aefos: command auto-replicate skipped: ' + E.Message));
      end;
    // The menu depends on the graph; it is built once on the first
    // resolution. A later switch keeps it — rebuilding the menu adapter from
    // its own dialog callback would free it mid-call.
    if not LHadProfile then
      _InitMainMenu;
    _InitAgentSuggestBinding;
    // BR-6: a runtime switch resets the panel to a fresh IDLE session so no
    // stale executor-labelled content survives into the next dispatch. RESET,
    // not Clear: the IOutputPanelSurface Clear begins a turn and shows the
    // pulsing "working..." indicator — with no dispatch behind it (the old
    // executor was just torn down above), that left the panel stuck pulsing
    // "working..." forever after switching the executor + Save (reported live
    // 2026-07-11). Guarded on GChatPanel so the dock form is never force-created
    // (matches TChatOutputProxy.Clear's no-force-create policy).
    if LHadProfile and Assigned(GChatPanel) then
      GChatPanel.ResetConversation;
    GLastResolvedProjectRoot := LCurrentRoot;
  except
    on E: Exception do
      OutputDebugString(PChar(
        'Aefos._ResolveExecutorGraph failed: ' + E.Message));
  end;
end;

type
  // Lightweight IOutputPanelSurface handed to output consumers (MainMenu command
  // replicate, AgentSuggest) at BPL load, BEFORE the heavy dock form exists.
  // Every call ensures the real chat panel is created + wired lazily, then
  // forwards. Keeps the dock form OUT of load so an unused session unloads
  // cleanly on rebuild (fixes the chronic 'Chat BPL gets uninstalled on rebuild'
  // — the dock-form teardown was the source; the Terminal's form is lazy too).
  TChatOutputProxy = class(TInterfacedObject, IOutputPanelSurface)
  public
    procedure Show;
    procedure Clear;
    procedure AppendChunk(const AText: string; const AStream: TStdStream);
    procedure ReportComplete(const AExitCode: Integer);
    procedure ReportError(const AException: Exception);
  end;

// ── New Project wizard data (native, /new-project) ───────────────────────────

function _JsonStrDef(const AObj: TJSONObject;
  const AName, ADefault: string): string;
var
  LValue: TJSONValue;
begin
  Result := ADefault;
  if AObj = nil then
    Exit;
  LValue := AObj.GetValue(AName);
  if (LValue <> nil) and (LValue is TJSONString) then
    Result := TJSONString(LValue).Value;
end;

function _JsonValStr(const AValue: TJSONValue): string;
begin
  if AValue is TJSONString then
    Result := TJSONString(AValue).Value
  else if AValue is TJSONNumber then
    Result := TJSONNumber(AValue).ToString
  else if AValue is TJSONTrue then
    Result := 'true'
  else if AValue is TJSONFalse then
    Result := 'false'
  else
    Result := '';
end;

// The template library as a [{id,name,category,description,vars}] JSON array,
// read from the templates root. Feeds the wizard's dropdown + fields.
function _ListProjectTemplatesJson: string;
var
  LDir, LManifest, LRaw: string;
  LArr: TJSONArray;
  LJson, LItem: TJSONObject;
  LVars: TJSONValue;
begin
  LArr := TJSONArray.Create;
  try
    if TDirectory.Exists(_TemplatesRoot) then
      for LDir in TDirectory.GetDirectories(_TemplatesRoot) do
      begin
        LManifest := TPath.Combine(LDir, 'template.json');
        if not TFile.Exists(LManifest) then
          Continue;
        LJson := nil;
        try
          try
            LRaw := TFile.ReadAllText(LManifest, TEncoding.UTF8);
            LJson := TJSONObject.ParseJSONValue(LRaw) as TJSONObject;
          except
            LJson := nil;
          end;
          if LJson = nil then
            Continue;
          LItem := TJSONObject.Create;
          LItem.AddPair('id', TPath.GetFileName(LDir));
          LItem.AddPair('name', _JsonStrDef(LJson, 'name', TPath.GetFileName(LDir)));
          LItem.AddPair('category', _JsonStrDef(LJson, 'category', 'Other'));
          LItem.AddPair('description', _JsonStrDef(LJson, 'description', ''));
          LVars := LJson.GetValue('vars');
          if LVars <> nil then
            LItem.AddPair('vars', LVars.Clone as TJSONValue);
          LArr.AddElement(LItem);
        finally
          LJson.Free;
        end;
      end;
    Result := LArr.ToJSON;
  finally
    LArr.Free;
  end;
end;

// Materialises the chosen template and (optionally) opens it. AFormJson =
// {template_id, target_dir, vars:{...}, open}. Returns {ok, project_path,
// files_written, opened} or {ok:false, error}.
function _CreateProjectFromForm(const AFormJson: string): string;
var
  LForm, LVarsObj, LResult: TJSONObject;
  LVal: TJSONValue;
  LPair: TJSONPair;
  LTemplateId, LTargetDir, LProjectPath: string;
  LOpen, LOpened: Boolean;
  LVars: TArray<TToolTemplateVar>;
  LRes: TToolScaffoldFolderResult;

  function Fail(const AMsg: string): string;
  begin
    LResult.AddPair('ok', TJSONBool.Create(False));
    LResult.AddPair('error', AMsg);
    Result := LResult.ToJSON;
  end;

begin
  LForm := nil;
  LResult := TJSONObject.Create;
  try
    try
      LForm := TJSONObject.ParseJSONValue(AFormJson) as TJSONObject;
    except
      LForm := nil;
    end;
    if LForm = nil then
      Exit(Fail('invalid form data'));

    LTemplateId := _JsonStrDef(LForm, 'template_id', '');
    LTargetDir := Trim(_JsonStrDef(LForm, 'target_dir', ''));
    LOpen := not (LForm.GetValue('open') is TJSONFalse);
    if (LTemplateId = '') or (LTargetDir = '') then
      Exit(Fail('template and target folder are required'));

    LVars := nil;
    LVal := LForm.GetValue('vars');
    if LVal is TJSONObject then
    begin
      LVarsObj := TJSONObject(LVal);
      for LPair in LVarsObj do
        LVars := LVars + [TToolTemplateVar.Make(LPair.JsonString.Value,
          _JsonValStr(LPair.JsonValue))];
    end;

    try
      LRes := TProjectOps.ScaffoldFolder(TPath.Combine(_TemplatesRoot, LTemplateId),
        LTargetDir, LVars, fbUtf8, False);
    except
      on E: Exception do
        Exit(Fail(E.Message));
    end;

    if LRes.TemplateMissing then
      Exit(Fail('template "' + LTemplateId + '" has no files'));
    if LRes.DestExists then
      Exit(Fail('the target folder is not empty'));
    if Length(LRes.Unresolved) > 0 then
      Exit(Fail('missing values: ' + string.Join(', ', LRes.Unresolved)));

    if LRes.MainFile <> '' then
      LProjectPath := TPath.Combine(LTargetDir, LRes.MainFile)
    else
      LProjectPath := LTargetDir;
    LOpened := False;
    if LOpen and (LRes.MainFile <> '') and Assigned(GWorkspaceFacade) then
      LOpened := GWorkspaceFacade.OpenFile(LProjectPath);

    LResult.AddPair('ok', TJSONBool.Create(True));
    LResult.AddPair('project_path', LProjectPath);
    LResult.AddPair('files_written', TJSONNumber.Create(LRes.FilesWritten));
    LResult.AddPair('opened', TJSONBool.Create(LOpened));
    Result := LResult.ToJSON;
  finally
    LForm.Free;
    LResult.Free;
  end;
end;

// Wires the chat panel's dependencies from the live globals. Guarded — a no-op
// until the panel exists. Called by _EnsureChatPanel right after it is created.
procedure _WireChatPanel;
begin
  if not Assigned(GChatPanel) then
    Exit;
  GChatPanel.OnCommand :=
    procedure(ACommandName: string)
    begin
      _RunCommand(ACommandName);
    end;
  GChatPanel.OnStop :=
    procedure
    begin
      if Assigned(GCommandExecutor) then
        GCommandExecutor.Cancel;
    end;
  GChatPanel.OnIsRunning :=
    function: Boolean
    begin
      Result := GCommandExecutor.IsRunning;
    end;
  GChatPanel.OnNewSession :=
    procedure
    begin
      GCommandExecutor.ResetSession;
    end;
  GChatPanel.OnGetSession :=
    function: string
    begin
      Result := GCommandExecutor.Session;
    end;
  GChatPanel.OnSetSession :=
    procedure(AId: string)
    begin
      GCommandExecutor.SetSession(AId);
    end;
  GChatPanel.OnGetExecutor :=
    function: string
    begin
      // The executor that OWNS the session the panel is about to store. Asked
      // for on every save instead of assumed, because the panel used to write
      // a literal 'claude' and so mislabelled every conversation -- including
      // the ones held with Codex, which is the factory default.
      Result := '';
      if Assigned(GCommandExecutor) then
        Result := TProviderRegistry.ExecutorKindToString(GCommandExecutor.Kind);
    end;
  GChatPanel.OnTurnEnded :=
    procedure
    begin
      // The turn is the only thing that can tell a visual card the story is
      // over. The card moves on reported tool FACTS, so an agent that stops
      // calling desktop tools and simply answers leaves it live for ever --
      // pending steps, scan line sweeping, under a finished conversation.
      if Assigned(GVisualReporter) and Assigned(GVisualReporter.Broadcast) then
        GVisualReporter.Broadcast.CloseLive;
    end;
  GChatPanel.OnMemoryLoad :=
    function: string
    begin
      Result := TChatGlobalSettings.LoadMemory;
    end;
  GChatPanel.OnMemorySave :=
    procedure(AText: string)
    begin
      TChatGlobalSettings.SaveMemory(AText);
    end;
  GChatPanel.OnMcpLoad :=
    function: string
    begin
      Result := TChatGlobalSettings.LoadMcpConfig;
    end;
  GChatPanel.OnMcpSave :=
    procedure(AJson: string)
    begin
      TChatGlobalSettings.SaveMcpConfig(AJson);
    end;
  GChatPanel.OnMcpAddons :=
    function: string
    begin
      // Installed addons' aggregate (`aefos install`) — read-only in the modal;
      // the same doc the dispatch merges (Aefos.MCP.Provision).
      Result := TMCPProvision.LoadAddonAggregate;
    end;
  GChatPanel.OnListTemplates :=
    function: string
    begin
      Result := _ListProjectTemplatesJson;
    end;
  GChatPanel.OnCreateProject :=
    function(AFormJson: string): string
    begin
      Result := _CreateProjectFromForm(AFormJson);
    end;
  GChatPanel.OnSetAgentMode :=
    procedure(AAgent: Boolean)
    begin
      // Welcome-page self-heal (same rationale as the send path): the chat
      // menu registers at BPL load, so the panel opens BEFORE any project and
      // the executor graph may be unresolved — a nil executor made this (and
      // the model pick below) a silent no-op (field report 2026-07-08: the
      // header showed the DEFAULT executor's models and a picked model "never
      // took" until the first send resolved the graph).
      if not Assigned(GCommandExecutor) then
        _ResolveExecutorGraph;
      GCommandExecutor.SetAgentMode(AAgent);
    end;
  GChatPanel.OnSetModel :=
    procedure(AModel: string)
    begin
      if not Assigned(GCommandExecutor) then
        _ResolveExecutorGraph; // Welcome-page self-heal — see OnSetAgentMode
      GCommandExecutor.SetModel(AModel);
      // Remember this pick PER EXECUTOR so it is recalled (and never leaks to
      // another provider) — same store the Options page uses.
      TExecutorModels.SetSelectedModelForKind(GCommandExecutor.Kind, AModel);
    end;
  GChatPanel.OnSetEffort :=
    procedure(AToken: string)
    begin
      if not Assigned(GCommandExecutor) then
        _ResolveExecutorGraph; // Welcome-page self-heal — see OnSetAgentMode
      // Canonicalise the posted token ('default'/unknown -> '') and remember it
      // per executor (same models.json store the model pick uses). The next
      // dispatch reads it fresh in _BuildArgsFromConfig.
      TExecutorModels.SetSelectedEffortForKind(GCommandExecutor.Kind,
        TReasoningEfforts.CliToken(TReasoningEfforts.FromCliToken(AToken)));
    end;
  GChatPanel.OnGetModels :=
    function: string
    var
      LKind: TExecutorKind;
      LModels: TArray<string>;
      LArr, M, LCurrent, LOverride: string;
      LInList: Boolean;
      LEffort, LSupStr: string;
      LSupported: Boolean;
    begin
      if not Assigned(GCommandExecutor) then
        _ResolveExecutorGraph; // Welcome-page self-heal — see OnSetAgentMode
      // File-backed, per-executor list (models.json), read from the FRESH config
      // each call so a focus re-feed reflects an executor/model change made in
      // Options. Model ids are alphanumeric/dash → safe in JSON unescaped.
      LKind := GCommandExecutor.Kind;
      LModels := TExecutorModels.ModelsForKind(LKind);
      // A picked override (FModel) only applies to its own executor; if the
      // executor changed it would be stale, so drop it when it's not in the
      // current list and fall back to the configured model.
      LOverride := GCommandExecutor.Model;
      if LOverride <> '' then
      begin
        LInList := False;
        for M in LModels do
          if M = LOverride then
          begin
            LInList := True;
            Break;
          end;
        if not LInList then
        begin
          GCommandExecutor.SetModel('');
          LOverride := '';
        end;
      end;
      if LOverride <> '' then
        LCurrent := LOverride
      else
      begin
        // Prefer the model remembered for THIS executor (per-kind store); fall
        // back to the configured single Model only when nothing is remembered.
        LCurrent := TExecutorModels.SelectedModelForKind(LKind);
        if LCurrent = '' then
          LCurrent := GCommandExecutor.GetConfigModel;
      end;
      LArr := '';
      for M in LModels do
      begin
        if LArr <> '' then
          LArr := LArr + ',';
        LArr := LArr + '"' + M + '"';
      end;
      // Reasoning-effort pill state: whether the active executor exposes the
      // control, and the remembered token (empty = Default). The page shows/hides
      // the pill on effortSupported and highlights the current level.
      LSupported := TExecutorCapabilities.SupportsReasoningEffort(LKind);
      LEffort := '';
      if LSupported then
        LEffort := TExecutorModels.SelectedEffortForKind(LKind);
      if LSupported then
        LSupStr := 'true'
      else
        LSupStr := 'false';
      Result := '{"models":[' + LArr + '],"current":"' + LCurrent +
        '","executor":"' + TProviderRegistry.ExecutorKindDisplayName(LKind) +
        '","effort":"' + LEffort + '","effortSupported":' + LSupStr + '}';
    end;
  GChatPanel.OnOpenSettings :=
    procedure
    begin
      OpenAefosOptions;
    end;
  GChatPanel.OnOpenInspector :=
    procedure
    begin
      OpenMcpInspector;
    end;
  GChatPanel.CommandPalette := GCommandPalette;
  GChatPanel.CommandRegistry := GCommandRegistry;
  GChatPanel.CommandReplicatorResolver :=
    function: ICommandReplicator begin Result := GCommandReplicator; end;
  GChatPanel.CliPathResolver :=
    function: string
    var
      LConfigPath: string;
    begin
      LConfigPath := '';
      if Assigned(GConfig) then
        LConfigPath := GConfig.Snapshot.ExecutorPath;
      Result := ResolveCLIBinary(LConfigPath, ONBOARDING_CLI_BINARY_NAME);
    end;
  GChatPanel.ConfigSnapshot :=
    function: TConfig
    begin
      if Assigned(GConfig) then
        Result := GConfig.Snapshot
      else
        Result := DefaultConfig;
    end;
end;

// Creates the dock form (lazy) and wires it. Idempotent. The output sink stays
// the proxy (GOutputPanel); consumers keep talking to the proxy, which forwards
// to this panel once it exists.
var
  // The panel instance whose backend callbacks are currently wired. Tracked by
  // INSTANCE (not a bool) so a desktop-RESTORED / IDE-recreated panel (a new
  // object in GChatPanel) is detected and re-wired. Stale value after a free is
  // harmless: it simply won't match the next instance.
  GWiredPanel: Pointer = nil;

procedure _EnsureChatPanel;
begin
  if not Assigned(GChatPanel) then
    TChatPanelHost.RegisterChatPanel;
  // Wire on first create AND whenever the live instance differs from the one we
  // last wired (the IDE restored/recreated the dock from a saved desktop).
  if Assigned(GChatPanel) and (GWiredPanel <> Pointer(GChatPanel)) then
  begin
    _WireChatPanel;
    GWiredPanel := Pointer(GChatPanel);
  end;
end;

procedure TChatOutputProxy.Show;
var
  LSurface: IOutputPanelSurface;
begin
  _EnsureChatPanel;
  LSurface := TChatPanelHost.ChatPanelSurface;
  if Assigned(LSurface) then
    LSurface.Show;
end;

procedure TChatOutputProxy.Clear;
var
  LSurface: IOutputPanelSurface;
begin
  // Housekeeping (e.g. clear-on-executor-switch, ChatPanel.pas) must NOT force
  // the dock form into existence — that would defeat the lazy load. No panel =>
  // nothing to clear.
  LSurface := TChatPanelHost.ChatPanelSurface;
  if Assigned(LSurface) then
    LSurface.Clear;
end;

procedure TChatOutputProxy.AppendChunk(const AText: string;
  const AStream: TStdStream);
var
  LSurface: IOutputPanelSurface;
begin
  _EnsureChatPanel;
  LSurface := TChatPanelHost.ChatPanelSurface;
  if Assigned(LSurface) then
    LSurface.AppendChunk(AText, AStream);
end;

procedure TChatOutputProxy.ReportComplete(const AExitCode: Integer);
var
  LSurface: IOutputPanelSurface;
begin
  // Completion footer only matters for an existing session — never force-create.
  LSurface := TChatPanelHost.ChatPanelSurface;
  if Assigned(LSurface) then
    LSurface.ReportComplete(AExitCode);
end;

procedure TChatOutputProxy.ReportError(const AException: Exception);
var
  LSurface: IOutputPanelSurface;
begin
  _EnsureChatPanel;
  LSurface := TChatPanelHost.ChatPanelSurface;
  if Assigned(LSurface) then
    LSurface.ReportError(AException);
end;

// Teardown breadcrumb trail. KEPT IN DEBUG BUILDS ONLY (design-time BPL unload is
// notoriously hard to diagnose — an AV/hang in finalization just deinstalls the
// package): appends to %APPDATA%\Aefos\aefos-teardown.log with an immediate flush
// (open/write/close), so the last '>>' with no matching '<< done' pinpoints the
// failing step, readable after a failed rebuild without any debugger. Release
// ships without it (the body compiles away).
procedure _TeardownLog(const AMsg: string);
{$IFDEF DEBUG}
var
  LDir, LPath: string;
{$ENDIF}
begin
{$IFDEF DEBUG}
  try
    LDir := TPath.Combine(GetEnvironmentVariable('APPDATA'), 'Aefos');
    if not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
    LPath := TPath.Combine(LDir, 'aefos-teardown.log');
    TFile.AppendAllText(LPath, AMsg + sLineBreak, TEncoding.UTF8);
  except
  end;
{$ENDIF}
end;

{$IFDEF DEBUG}
// Logs base/end/size of every Aefos module at load. With these, the address in
// an unload AV dialog resolves to module + RVA (addr - base), and the RVA
// resolves to an exact symbol in that module's .map — pinpointing WHICH object
// the IDE still references after the BPL unmaps.
procedure _LogAefosModuleBases;
const
  CModules: array[0..5] of string = (
    'Aefos.OTA.Chat.bpl', 'Aefos.Data.bpl', 'Aefos.Tools.bpl',
    'Aefos.MCP.Core.bpl', 'Aefos.MCP.Tools.OTA.bpl', 'Aefos.OTA.Terminal.bpl');
var
  LIdx:  Integer;
  LBase: HMODULE;
  LNt:   PImageNtHeaders;
  LSize: Cardinal;
begin
  _TeardownLog('=== LOAD (module bases) ===');
  for LIdx := Low(CModules) to High(CModules) do
  begin
    LBase := GetModuleHandle(PChar(CModules[LIdx]));
    if LBase = 0 then
      _TeardownLog('[load] ' + CModules[LIdx] + ' not loaded')
    else
    begin
      LNt := PImageNtHeaders(NativeUInt(LBase) +
        Cardinal(PImageDosHeader(LBase)^._lfanew));
      LSize := LNt^.OptionalHeader.SizeOfImage;
      _TeardownLog(Format('[load] %s base=%.8x end=%.8x size=%.8x',
        [CModules[LIdx], NativeUInt(LBase), NativeUInt(LBase) + LSize, LSize]));
    end;
  end;
end;
{$ENDIF}

procedure Register;
begin
  TAefosIDENotifierAdapter.RegisterSelf;
  // Path B (project-dock-layout-persistence): restore the chat dock after a
  // Run/Debug -> back-to-Default layout round-trip, which drops our
  // (intentionally non-desktop-persisted) dock. Inject the hooks BEFORE
  // registering so an immediate process event already has them. No
  // RegisterDesktopFormClass is added (THE LAW) — we watch the debugger and
  // re-show ourselves.
  TAefosDebuggerNotifierAdapter.RegisterChatReshowHandlers(
    function: Boolean
    begin
      Result := Assigned(Aefos.OTA.Chat.UI.ChatPanel.GChatPanel)
        and Aefos.OTA.Chat.UI.ChatPanel.GChatPanel.Visible;
    end,
    procedure
    begin
      Aefos.OTA.Chat.UI.ChatPanel.TChatPanelHost.ShowChatPanel;
    end);
  TAefosDebuggerNotifierAdapter.RegisterSelf;
  // ADR-099: register plugin form classes for IDE theming before any form
  // (chat panel or modal dialog) is created.
  _InitTheming;
  _InitDispatcher;
  _InitConfig;
  // ESP-002 Epic 4/4: register the Tools->Options Aefos node. Depends on
  // GConfig (just initialised); the pages resolve the active project lazily.
  _InitOptions;
  _InitCommandRegistry;
  _InitContextBuilder;
  // Lazy chat panel (composition-root fix for the chronic 'Chat BPL gets
  // uninstalled on rebuild'). A lightweight surface proxy is the output sink at
  // load so MainMenu/AgentSuggest get a non-nil IOutputPanelSurface; the heavy
  // dock form is created + wired by _EnsureChatPanel only on first open / first
  // real output (via the proxy or the ShowChatPanel hook). An unused session has
  // no form to tear down, so the BPL unmaps cleanly on rebuild.
  GOutputPanel := TChatOutputProxy.Create;
  Aefos.OTA.Chat.UI.ChatPanel.GChatPanelEnsureHook :=
    procedure
    begin
      _EnsureChatPanel;
    end;
  // Wire-only hook (used by a desktop-RESTORED dock on its first show): wires the
  // EXACT instance the IDE created, never creating a second panel. Syncs GChatPanel
  // to it, then wires once (tracked by instance via GWiredPanel).
  Aefos.OTA.Chat.UI.ChatPanel.GChatPanelWireHook :=
    procedure(APanel: TObject)
    begin
      if not Assigned(APanel) then
        Exit;
      if GChatPanel <> APanel then
        GChatPanel := TAefosChatPanel(APanel);
      if GWiredPanel <> Pointer(APanel) then
      begin
        _WireChatPanel;
        GWiredPanel := Pointer(APanel);
      end;
    end;
  // Desktop persistence: the dock-class registration moved to the ChatPanel unit's
  // INITIALIZATION (runs before the IDE restores a saved desktop, like the Terminal)
  // — the Register proc was too late, so the restored chat vanished. See ChatPanel.
  // Build the visible 'Aefos AI (Chat)' menu now, at load — like the Terminal
  // BPL — so Open Chat + About are available on the Welcome page before any
  // project is open (explicit maintainer requirement; neither panel needs a
  // project to be useful). The Ctrl+Alt+F11 binding is still wired when the
  // executor graph resolves.
  _InitChatMenuBar;
  // Single shared top-level "Aefos PyTools" item (refcounted across both hosts,
  // Pro-only/hidden for Free). No-op if the Terminal BPL already registered it.
  Aefos.OTA.MCP.PyToolsManager.RegisterPyToolsMenu;
  // Self-provision the MCP bridge to %APPDATA%\Aefos so the plugin works without
  // the installer (a dev may just install the BPLs). The per-project .mcp.json is
  // written on demand from the Options 'Test MCP' action.
  TMCPProvision.EnsureBridge;
  _InitCommandPalette;
  TAefosIDENotifierAdapter.RegisterExecutorReResolveHandler(
    procedure
    begin
      _ResolveExecutorGraph;
    end);
  // ADR-083: the config-and-executor graph — and the menu / AgentSuggest
  // bindings that depend on it — resolve eagerly only when a project is
  // already active; otherwise resolution is deferred to the first
  // ofnActiveProjectChanged.
  if _ResolveActiveProjectRoot <> '' then
    _ResolveExecutorGraph;
  // Start the persistent MCP server for this Claude Code terminal session.
  // Listens on \\.\pipe\aefos-mcp-plugin so mcp-bridge.ps1 -Session plugin
  // can connect without competing with the RADShell terminal pipe (terminal).
  // Register the decoupled HTML consent presenter GLOBALLY so destructive-action
  // consent triggered via the chat shows the WebView2 modal regardless of which
  // MCP server/facade instance answered (it declines to the VCL modal when the
  // chat panel isn't ready). Cleared on unload in _ShutdownDevSessionServer.
  SetGlobalConsentPresenter(THtmlConsentPresenter.Create);
  // (2026-06-11) Briefly gated off while diagnosing the chronic rebuild AV/F2039;
  // exonerated — the real culprit was keyboard bindings not being explicitly
  // removed at teardown (see TAefosAgentSuggestAdapter.UnregisterSelf). The pipe
  // listener thread exits cleanly via FCancelEvent on Stop.
  _InitDevSessionServer;
  // Editor change-review (red/green INTAEditViewNotifier + Tab/Esc binding).
  // MIGRATED to the shared Aefos.MCP.Tools.OTA BPL (2026-06-21) so a Terminal-only
  // install gets it too; registration is idempotent and Terminal's wizard calls it
  // as well. ESP 2026-06-10.
  TGutterReview.RegisterGutterReview;
{$IFDEF DEBUG}
  // Unload-AV forensics: record the Aefos module bases so a later AV address
  // resolves to module+RVA (see _LogAefosModuleBases).
  _LogAefosModuleBases;
{$ENDIF}
end;

// Diagnostic hook for EAbstractError. The default System.AbstractErrorProc
// shows the bare "Abstract Error" dialog with no context, which is what
// IDE shutdown surfaces when a virtual-abstract method on a docked OTA-
// derived form (or any class our BPL registers with the IDE) is called
// without an override. This hook logs the return-address chain via
// OutputDebugString BEFORE the default behaviour fires, so DebugView shows
// exactly which call site triggered it.
var
  GPriorAbstractErrorProc: Pointer = nil;
  GAbstractHookInstalled: Boolean = False;

procedure _AefosAbstractErrorHook;
var
  LCaller: Pointer;
begin
  LCaller := ReturnAddress;
  OutputDebugString(PChar(Format(
    '[Aefos] AbstractErrorProc fired — return address $%p',
    [LCaller])));
  if Assigned(GPriorAbstractErrorProc) and (GPriorAbstractErrorProc <> @_AefosAbstractErrorHook) then
    TProcedure(GPriorAbstractErrorProc)()
  else
    raise EAbstractError.Create('Abstract Error');
end;

procedure _InstallAbstractErrorHook;
begin
  if GAbstractHookInstalled then
    Exit;
  GPriorAbstractErrorProc := @System.AbstractErrorProc;
  System.AbstractErrorProc := _AefosAbstractErrorHook;
  GAbstractHookInstalled := True;
end;

procedure _UninstallAbstractErrorHook;
begin
  if not GAbstractHookInstalled then
    Exit;
  // Restore default by writing nil — System.pas falls back to the built-in
  // _AbstractError when AbstractErrorProc is nil (see System.@AbstractError).
  System.AbstractErrorProc := nil;
  GPriorAbstractErrorProc := nil;
  GAbstractHookInstalled := False;
end;

// Each finalization step is isolated: an exception escaping finalization
// aborts the IDE's package unload and leaves notifiers/forms registered
// against unmapped code (the crash pattern from RADShell issue #33).
// Failures are logged via OutputDebugString so teardown always runs to
// completion.
procedure _GuardedShutdown(const AName: string; const AStep: TProc);
begin
  // Per-step breadcrumbs (DEBUG only): the last '>>' with no matching '<< done'
  // (in the teardown log / DebugView) is the step that HANGS and keeps the BPL
  // mapped (a hang doesn't raise, so the except below never sees it).
{$IFDEF DEBUG}
  OutputDebugString(PChar('[Aefos] teardown >> ' + AName));
{$ENDIF}
  _TeardownLog('>> ' + AName);
  try
    AStep();
  except
    on E: Exception do
      // Teardown must never raise — log and swallow.
      OutputDebugString(PChar('Aefos teardown [' + AName + ']: '
        + E.ClassName + ' - ' + E.Message));
  end;
{$IFDEF DEBUG}
  OutputDebugString(PChar('[Aefos] teardown << ' + AName + ' done'));
{$ENDIF}
  _TeardownLog('<< ' + AName + ' done');
end;

initialization
  _InstallAbstractErrorHook;
  // Splash-screen bitmap + About-box entry for this BPL. Registered at load so
  // the Aefos logo shows on the Delphi splash even when only the Chat
  // plugin is installed (the Terminal BPL registers its own — they are
  // independent). Never raise into package init.
  try
    RegisterChatBranding;
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos.Register: branding failed: '
        + E.Message));
  end;

finalization
  // *** BEFORE CHANGING TEARDOWN ORDER/STEPS: read Aefos.OTA.Chat.UnloadContract. ***
  _TeardownLog('=== FINALIZATION START ===');
  // Zero out all interface references that might point to GChatPanel or GOutputPanel
  // using raw pointer casting. This prevents IntfClear from calling _Release
  // on already-freed objects during finalization.
  _TeardownLog('>> raw:ClearAgentSuggestSurface');
  try
    TAefosAgentSuggestAdapter.ClearAgentSuggestSurface;
  except
    on E: Exception do OutputDebugString(PChar('Aefos raw cleanup AgentSuggest: ' + E.Message));
  end;

  _TeardownLog('>> raw:ClearMainMenuSurface');
  try
    TAefosMainMenuStaticAdapter.ClearMainMenuSurface;
  except
    on E: Exception do OutputDebugString(PChar('Aefos raw cleanup MainMenu: ' + E.Message));
  end;

  _TeardownLog('>> raw:ClearCommandExecutorSurface');
  try
    ClearCommandExecutorSurface(GCommandExecutor);
  except
    on E: Exception do OutputDebugString(PChar('Aefos raw cleanup CommandExecutor: ' + E.Message));
  end;

  _TeardownLog('>> raw:NilOutputPanel');
  Pointer(GOutputPanel) := nil;
  _TeardownLog('<< raw cleanup done');

  // Shutdown order (ESP-002 AC-12 + Epic 7/7 Demand 1/8): Inspector first
  // (its form refs the workspace facade through the bridge), then Adapter
  // -> Executor -> Replicator -> ContextBuilder -> CommandRegistry -> Config
  // -> Dispatcher.
  // ADR-258/259 (AC-06): remove the registered IOTAIDENotifier via its stored
  // index before the graph it drives is torn down; idempotent and also nulls
  // the re-resolve handler. Runs first so no late ofnActiveProjectChanged can
  // queue a re-resolve against half-freed globals.
  _GuardedShutdown('IDENotifier', procedure begin
    TAefosIDENotifierAdapter.UnregisterNotifier;
  end);
  // THE LAW (UnloadContract Rule 2): remove our IDE-held debugger notifier by
  // its stored index, guarded — paired with TAefosDebuggerNotifierAdapter.RegisterSelf.
  // Early, so no late ProcessDestroyed can queue a re-show against half-freed
  // globals; UnregisterNotifier also nils the injected cross-BPL handlers.
  _GuardedShutdown('DebuggerNotifier', procedure begin
    TAefosDebuggerNotifierAdapter.UnregisterNotifier;
  end);
  _GuardedShutdown('DevSessionServer', procedure begin _ShutdownDevSessionServer; end);
  // ESP-002 Epic 4/4 (RN-007): unregister the Options pages on unload so a
  // load/unload cycle leaves no orphan Aefos nodes.
  _GuardedShutdown('Options',         procedure begin _ShutdownOptions; end);
  _GuardedShutdown('AgentSuggest',    procedure begin _ShutdownAgentSuggestBinding; end);
  _GuardedShutdown('MainMenu',        procedure begin _ShutdownMainMenu; end);
  _GuardedShutdown('ChatMenuBar',     procedure begin _ShutdownChatMenuBar; end);
  _GuardedShutdown('PyToolsMenu',     procedure begin Aefos.OTA.MCP.PyToolsManager.UnregisterPyToolsMenu; end);
  _GuardedShutdown('VisualReporter',  procedure begin FreeAndNil(GVisualReporter); end);
  _GuardedShutdown('CommandPalette',  procedure begin _ShutdownCommandPalette; end);
  _GuardedShutdown('CommandExecutor',   procedure begin _ShutdownCommandExecutor; end);
  _GuardedShutdown('CommandReplicator', procedure begin _ShutdownCommandReplicator; end);
  // (ChatDesktopClass unregister now lives in the ChatPanel unit finalization, to
  // pair its initialization-time RegisterFieldAddress.)
  _GuardedShutdown('OutputPanel',     procedure begin _ShutdownOutputPanel; end);
  _GuardedShutdown('ContextBuilder',  procedure begin _ShutdownContextBuilder; end);
  _GuardedShutdown('CommandRegistry',   procedure begin _ShutdownCommandRegistry; end);
  _GuardedShutdown('ExecutorProfile', procedure begin _ShutdownExecutorProfile; end);
  _GuardedShutdown('Config',          procedure begin _ShutdownConfig; end);
  _GuardedShutdown('Dispatcher',      procedure begin _ShutdownDispatcher; end);
  _GuardedShutdown('Theming',         procedure begin _ShutdownTheming; end);
  _GuardedShutdown('Branding', procedure begin UnregisterChatBranding; end);
  _GuardedShutdown('AbstractErrorHook', procedure begin _UninstallAbstractErrorHook; end);

end.
