unit Aefos.OTA.Chat.UI.ChatPanel;

{
  Dockable chat panel — primary output and command surface.

  TDockableForm subclass hosting a TRichEdit (output area, top) split from
  a TMemo + Send button row (input area, bottom). Implements
  IOutputPanelSurface; all IOutputPanelSurface calls coming from background
  threads are marshalled to the IDE main thread via TThread.Queue.

  Dock position and visibility state persist to the IDE profile through
  DeskSection / AutoSave / SaveStateNecessary (DockForm / DeskUtil pattern,
  same as Delphi-AI-Developer reference). IDE theme is applied on FormShow
  via IOTAIDEThemingServices.

  Commands typed in the input memo are dispatched via the OnCommand callback
  after stripping a leading '/'. Ctrl+Enter or plain Enter sends; Shift+Enter
  inserts a newline.

  Typing '/' as the first non-whitespace character of the input opens an
  inline, non-modal command list (a TListBox child) backed by the shared
  TCommandPalette registry, injected as ICommandPalette (ADR-087, BR-1). The
  list filters live, navigates with the keyboard, and on selection inserts
  '/<name> ' into the input without dispatching (BR-3).

  Registration: TChatPanelHost.RegisterChatPanel / .UnregisterChatPanel.
  Show: call TChatPanelHost.ShowChatPanel (ShowDockableForm + FocusWindow) or let
  the executor call IOutputPanelSurface.Show at command start.
}

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  System.IniFiles,
  DockForm,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.Graphics,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  Vcl.Buttons,
  Aefos.MCP.Types,
  Aefos.OTA.Chat.Core.CommandPalette.Types,
  Aefos.OTA.Chat.Core.BuiltInCommands,
  Aefos.OTA.Chat.Core.Config.Types,
  Aefos.OTA.Chat.Core.Onboarding,
  Aefos.OTA.Chat.Core.CommandRegistry.Types,
  Aefos.OTA.Chat.Core.CommandReplicator.Types,
  Aefos.OTA.Chat.UI.ChatPanel.FocusLifecycle,
  Aefos.OTA.Chat.UI.OutputPanel.Edge,
  Aefos.OTA.Chat.UI.OutputPanel.EdgeController,
  Aefos.OTA.Chat.Core.OutputPanel.RenderProtocol;

type
  TAefosChatPanel = class(TDockableForm, IOutputPanelSurface,
    IOutputPanelInspector)
    FOutput: TRichEdit;
    FSplitter: TSplitter;
    FInputPanel: TPanel;
    FInput: TMemo;
    FSendBtn: TButton;
    FCmdList: TListBox;
    FHeaderPanel: TPanel;
    FSessionPanel: TPanel;
    FClientContainer: TPanel;
    FWelcomePanel: TPanel;
    FWelcomePanelCenter: TPanel;
    FGridCommands: TGridPanel;
    FBottomContainer: TPanel;
    FStatusPanel: TPanel;
    FTipLabel: TLabel;
    FLabelSparkle: TLabel;
    FLabelGreetingSub: TLabel;
    FLabelSessionTime: TLabel;
    FLabelStatusText: TLabel;
    FAttachIcon: TLabel;
    FShortcutLabel: TLabel;
    FMicIcon: TLabel;
    FLabelAgentTab: TLabel;
    FLabelChatTab: TLabel;
    FNewTag: TPanel;
    LabelNewTagText: TLabel;
    ShapeSessionDot: TShape;
    LabelSessionInfoText: TLabel;
    PanelGreeting: TPanel;
    LabelGreetingLeft: TLabel;
    LabelGreetingRight: TLabel;
    ShapeInputBg: TShape;

    // Cards with TBitBtn Icons
    CardExplain: TPanel;
    ShapeExplainBg: TShape;
    BtnExplainIcon: TBitBtn;
    LabelExplainTitle: TLabel;
    LabelExplainDesc: TLabel;

    CardRefactor: TPanel;
    ShapeRefactorBg: TShape;
    BtnRefactorIcon: TBitBtn;
    LabelRefactorTitle: TLabel;
    LabelRefactorDesc: TLabel;

    CardTest: TPanel;
    ShapeTestBg: TShape;
    BtnTestIcon: TBitBtn;
    LabelTestTitle: TLabel;
    LabelTestDesc: TLabel;

    CardDocs: TPanel;
    ShapeDocsBg: TShape;
    BtnDocsIcon: TBitBtn;
    LabelDocsTitle: TLabel;
    LabelDocsDesc: TLabel;

    CardFind: TPanel;
    ShapeFindBg: TShape;
    BtnFindIcon: TBitBtn;
    LabelFindTitle: TLabel;
    LabelFindDesc: TLabel;

    CardOptimize: TPanel;
    ShapeOptimizeBg: TShape;
    BtnOptimizeIcon: TBitBtn;
    LabelOptimizeTitle: TLabel;
    LabelOptimizeDesc: TLabel;

    procedure _OnSendClick(Sender: TObject);
    procedure _OnInputChange(Sender: TObject);
    procedure _OnInputKeyDown(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure _OnCmdListDblClick(Sender: TObject);
    procedure _OnFormShow(Sender: TObject);
    procedure _OnFormResize(Sender: TObject);
    procedure CardMouseEnter(Sender: TObject);
    procedure CardMouseLeave(Sender: TObject);
    procedure _OnExplainClick(Sender: TObject);
    procedure _OnRefactorClick(Sender: TObject);
    procedure _OnTestClick(Sender: TObject);
    procedure _OnDocsClick(Sender: TObject);
    procedure _OnFindClick(Sender: TObject);
    procedure _OnOptimizeClick(Sender: TObject);
    // JS->Pascal bridge handler: maps an empty-state chip 'action:xxx' to a
    // slash-command prefill (mirrors the VCL welcome-card mapping).
    procedure _OnHostMessage(const AMessage: string);
    // Ctrl+V hook (see FAppEvents): injects the clipboard into the chat input
    // when the keystroke targets the WebView2 (the IDE would otherwise eat it).
    procedure _AppMessage(var Msg: TMsg; var Handled: Boolean);
    function _HwndInChat(AHwnd: HWND): Boolean;
    // True when the Win32 focus sits anywhere inside the panel — the WebView2's
    // Chrome child windows and VCL children (FInput fallback) alike.
    function _FocusInChat: Boolean;
    // Root-form OnShortCut hook (see _RootShortCut): reserves the editing keys
    // before the IDE's action lists run when the composer owns the focus.
    // Re-hooked on every SetParent because docking changes the root form.
    procedure _RootShortCut(var Msg: TWMKey; var Handled: Boolean);
    procedure _HookRootShortCut;
    procedure _UnhookRootShortCut;
    // HTML header (#ds-ctx) session feed helpers: push the live title/count to
    // the page (FController.SetSessionInfo) and reset on /new.
    procedure _PushSessionInfo;
    procedure _ResetSessionInfo;
    // Sessions/history. _SaveCurrentSession records the current conversation
    // (id+title+messages) via SessionStore; _OpenSessionsPanel lists them in the
    // HTML panel; _ResumeSession (id) replays a stored session + arms --resume.
    procedure _SaveCurrentSession;
    // Fires OnTurnEnded, swallowing anything a listener throws.
    procedure _NotifyTurnEnded;
    procedure _OpenSessionsPanel;
    procedure _ResumeSession(const AId: string);
    procedure _DeleteSessionFromPanel(const AId: string);
    // HTML command (command) editor bridge (ADR-250). _OpenCommandEditorNew opens
    // a blank modal; _SendCommandList feeds the "edit existing" dropdown;
    // _LoadCommandIntoEditor pre-populates from a command; _SaveCommandFromJson /
    // _DeleteCommand persist through FRegistry (the one canonical writer).
    procedure _OpenCommandEditorNew;
    // Opens the MCP Servers modal: the user's saved config (editable) plus the
    // installed addons' aggregate (read-only ADDON rows). Shared by the 🔌
    // button (mcp:open) and the /mcp built-in.
    procedure _OpenMcpModal;
    // Attach (paperclip): a file picker whose chosen path is inserted into the
    // composer (the agent reads it via its tools, running in the project dir).
    procedure _OpenAttachDialog;
    // A clipboard image (base64 PNG) pasted into the input: save it to a temp
    // file and insert the path (the CLI's Read tool can see images).
    procedure _SavePastedImage(const ABase64: string);
    procedure _SendCommandList;
    procedure _SendPickerCommands;
    procedure _OpenNewProjectWizard;
    procedure _BrowseProjectFolder;
    procedure _LoadCommandIntoEditor(const AName: string);
    procedure _SaveCommandFromJson(const AJson: string);
    procedure _DeleteCommand(const AName: string);
  protected
    procedure CreateWnd; override;
    procedure SetParent(AParent: TWinControl); override;
    // Drops the root-form hook bookkeeping when the hooked form dies first
    // (IDE shutdown order), so Destroy never touches a freed form.
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
    procedure WMSetFocus(var Message: TWMSetFocus); message WM_SETFOCUS;
    procedure WMMouseActivate(var Message: TWMMouseActivate); message WM_MOUSEACTIVATE;
    procedure CMActivate(var Message: TMessage); message CM_ACTIVATE;
  private
    FCmdEntries: TArray<TCommandEntry>;
    FPalette: ICommandPalette;
    FRegistry: ICommandRegistry;
    FReplicatorResolver: TFunc<ICommandReplicator>;
    // Plain-VCL focus/dock lifecycle seam (ADR-219). Owns the validity-invariant
    // guards that keep a deferred focus op from touching the panel after a
    // re-parent or teardown (ADR-220 / BR-1).
    FFocusLifecycle: TChatPanelFocusLifecycle;
    // Root form currently carrying our OnShortCut hook + the handler we
    // chained over (restored on unhook). Nil when no hook is installed.
    FHookedRoot: TCustomForm;
    FPrevRootShortCut: TShortCutEvent;
    FOnCommand: TProc<string>;
    // Composer Stop button (busy state): cancels the in-flight run. Wired to the
    // command executor's Cancel by the composition root.
    FOnStop: TProc;
    // Stale-busy probe ('busycheck:'): returns True while a CLI run is REALLY
    // in flight. The page's _dsBusy is only a mirror — a lost completion footer
    // left it stuck true and every send died silently in dsSubmit (proven live
    // 2026-07-07). Wired to CommandExecutorIsRunning by the composition root.
    FOnIsRunning: TFunc<Boolean>;
    // Send-during-run queue: messages sent while a run is in flight wait here
    // (FIFO, bubble echoed at once) and auto-dispatch as their own turns when
    // the current one completes/errors (--resume keeps the context). Survives
    // Stop by design: cancel ends the turn, the queue then drains normally.
    FQueuedMessages: TStringList;
    // /new | /reset: fired after the conversation is cleared so the composition
    // root can drop the CLI session (ResetCommandExecutorSession). No arg.
    FOnNewSession: TProc;
    // Sessions/history hooks. OnGetSession returns the executor's current
    // --session-id (used to key the on-disk session + mark the CURRENT row);
    // OnSetSession adopts an id to RESUME a stored session (--resume next turn).
    FGetSession: TFunc<string>;
    FSetSession: TProc<string>;
    // OnGetExecutor returns the token of the executor that OWNS the live session
    // ('claude' | 'codex' | ...), so a stored session records who actually ran it.
    // This was a hard-coded 'claude' and mislabelled every conversation held with
    // any other executor -- and Codex is the factory default. Unassigned returns
    // '' and the row simply shows no executor: an unknown label is better than a
    // confident wrong one, since the label is what stops a user resuming a
    // conversation into a CLI that never held it.
    FGetExecutor: TFunc<string>;
    // Fired once the turn is over, whether it completed or errored. The Visual
    // Scanner listens: its card only moves when a desktop tool reports a fact,
    // so when the agent stops calling tools and just answers, nothing tells the
    // card the story is finished. It sat there with pending steps and a sweeping
    // scan line under a conversation that had already printed 'completed.'.
    FOnTurnEnded: TProc;
    // Memory modal (🧠 / /memory): the composition root supplies the global
    // standing-instructions load/save (LoadGlobalMemory / SaveGlobalMemory) so
    // the panel can fill the modal and persist edits without touching the Core.
    FOnMemoryLoad: TFunc<string>;
    FOnMemorySave: TProc<string>;
    FOnMcpLoad: TFunc<string>;
    FOnMcpSave: TProc<string>;
    FOnMcpAddons: TFunc<string>;
    FOnListTemplates: TFunc<string>;
    FOnCreateProject: TFunc<string, string>;
    // Chat|Agent header toggle. The composition root forwards this to
    // SetCommandExecutorAgentMode. True = Agent (tools on), False = Chat (talk only).
    FOnSetAgentMode: TProc<Boolean>;
    // Last applied mode (default Agent). Switching Chat<->Agent starts a
    // fresh session, so we only reset on an ACTUAL change (the page may echo the
    // current mode on load — that must never wipe the conversation).
    FAgentMode: Boolean;
    // Header model selector: OnSetModel forwards the picked model to
    // SetCommandExecutorModel; OnGetModels returns the {models,current} JSON.
    FOnSetModel: TProc<string>;
    FOnGetModels: TFunc<string>;
    // Header reasoning-effort selector (Codex): the picked CLI token ('default'
    // or low|medium|high|xhigh). The composition root persists it per executor.
    FOnSetEffort: TProc<string>;
    // Pending consent resolve (HTML permission modal, ADR-216). Set when the
    // workspace facade asks for consent; called ONCE by _OnHostMessage when the
    // user picks allow/deny, then cleared. nil = no consent pending.
    FPendingConsentResolve: TProc<TMCPConsentDecision>;
    // ESP-002 Epic 4/4: settings deep-link. Built programmatically (not in the
    // DFM) so the header layout stays untouched; the click forwards to the
    // open-options helper wired by the composition root (ADR-211).
    FSettingsBtn: TButton;
    FOnOpenSettings: TProc;
    FOnOpenInspector: TProc;
    // HTML header (#ds-ctx) session feed. The legacy VCL session bar
    // (FSessionPanel) was static — no code ever updated it — so the title and
    // count are derived here from the live conversation: title = first user
    // message, count = number of user dispatches. Pushed to the page via
    // FController.SetSessionInfo. Reset on /new (hdr:newsession).
    FSessionTitle: string;
    FSessionCount: Integer;
    // ESP-002 Demand 1/2: WebView2 output controller (ADR-241/242/243).
    // Nil if creation fails; fallback routes output to FOutput (TRichEdit).
    FController: TOutputPanelEdgeController;
    // ESP-002 Epic 2/4 Demand 2/3: first-run onboarding (ADR-273/274/275).
    // Collaborators injected by the composition root; the empty-state surface
    // is built programmatically so the DFM stays untouched.
    FCliPathResolver: TFunc<string>;
    FConfigSnapshot: TFunc<TConfig>;
    FOnboardingPanel: TPanel;
    FOnboardingTitle: TLabel;
    FOnboardingChecklist: TLabel;
    FOnboardingHint: TLabel;
    FOnboardingSetExecutorBtn: TButton;
    procedure _CreateOnboardingPanel;
    function _CommandCount: Integer;
    function _BuildOnboardingInput: TOnboardingInput;
    function _StepMarker(const APlan: TOnboardingPlan;
      const AStepIndex: Integer): string;
    function _BuildChecklistText(const APlan: TOnboardingPlan): string;
    // Derives the onboarding plan from live state and shows the guided
    // checklist over the welcome cards only when the state is not osReady
    // (BR-1 / BR-5 / AC-07). Must run on the main thread.
    procedure _EvaluateAndRenderOnboarding;
    procedure _OnSettingsClick(Sender: TObject);
    procedure _CreateSettingsButton;
    procedure _RunOnMainThread(AProc: TProc);
    procedure _ApplyTheme;
    procedure _ApplyThemeTo(const AComponent: TComponent);
    procedure _ScrollToBottom;
    // AFromQueue = a drain re-entry from _DrainQueuedMessage: the bubble was
    // already echoed when the message was queued, so the echo is skipped and
    // the queue gate is bypassed (else the drain would just re-queue).
    { Opens a link the user clicked in a message, WITHOUT navigating this panel:
      a project file goes to the IDE editor (that is where a .md of this project
      belongs), a real URL goes to the system browser, and anything unresolvable
      says so in the chat instead of failing silently. }
    procedure _OpenLink(const AHref: string);
    procedure _DispatchCommand(const AText: string;
      const AFromQueue: Boolean = False);
    procedure _DrainQueuedMessage;
    procedure _ClearQueuedMessages;
    procedure _RecordRecent(const ACmd: string; const AIsBuiltin: Boolean;
      const ABuiltin: TBuiltInCommand);
    function _CommandListVisible: Boolean;
    procedure _FilterCommandList(const AQuery: string);
    procedure _RefreshCommandListIfOpen;
    procedure _PopulateCommandList(const AEntries: TArray<TCommandEntry>);
    procedure _ShowCommandList;
    procedure _HideCommandList;
    procedure _MoveCommandSelection(const ADelta: Integer);
    procedure _AcceptListSelection;
    function _HandleListKey(var AKey: Word): Boolean;
    // True when the WebView2 controller is active (not failed). Routes output
    // to the browser; FOutput acts as the fallback when this is False (BR-2).
    function _UseBrowser: Boolean;
    // Transitions the output area from the welcome panel to the browser or
    // FOutput fallback on the first output call. Must run on main thread.
    procedure _EnsureOutputVisible;
    // FOutput fallback path for AppendChunk; only called when _UseBrowser=False.
    procedure _AppendToFOutput(const AText: string; const AStream: TStdStream);
    // Converts a Windows TColor (COLORREF) to an HTML #rrggbb string.
    function _TColorToHex(const AColor: TColor): string;
    // Resolves the active IDE theme to a TPanelTheme palette (ADR-244).
    // Queries IOTAIDEThemingServices250; falls back to DefaultDark/LightTheme.
    function _BuildPanelTheme: TPanelTheme;

    // IOutputPanelSurface — method resolution avoids clash with TForm.Show
    procedure IOutputPanelSurface.Show = _PanelShow;
    procedure _PanelShow;
    procedure Clear;
    procedure AppendChunk(const AText: string; const AStream: TStdStream);
    procedure ReportComplete(const AExitCode: Integer);
    procedure ReportError(const AException: Exception);

    // IOutputPanelInspector — delegates to FController (ADR-243)
    function IOutputPanelInspector.IsBrowserReady = _IsBrowserReady;
    function IOutputPanelInspector.IsQueueReady = _IsQueueReady;
    function IOutputPanelInspector.BeginEvalScript = _BeginEvalScript;
    function _IsBrowserReady: Boolean;
    function _IsQueueReady: Boolean;
    function _BeginEvalScript(const AScript: string;
      const AOnDone: TInspectorEvalProc): Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Reserves the plain editing keys (Ctrl+V/C/X/A/Z) for the chat surface
    // when it owns the focus, instead of letting the inherited TDockableForm
    // pass hand them to the IDE's global Edit actions (Terminal OP1 pattern,
    // ESP-026/ESP-080). See the implementation comment for the Vcl.Edge
    // accelerator round-trip this hooks into. Public to match the base-class
    // visibility (H2269).
    function IsShortCut(var AMessage: TWMKey): Boolean; override;
    procedure PrefillInput(const AText: string);
    // Teardown hook: mark the focus seam shutting-down and drain any pending
    // queued focus op. Called by UnregisterChatPanel before ManualFloat so the
    // re-parent it triggers cannot queue a focus op against a dying panel.
    procedure BeginFocusShutdown;
    // TDockableForm declares LoadWindowState / SaveWindowState as
    // virtual abstract; the IDE calls them per desktop layout (default,
    // project, debug) when persisting docking on shutdown. Without these
    // overrides, a docked instance triggers 3 stacked "Abstract Error"
    // dialogs on IDE close.
    procedure LoadWindowState(Desktop: TCustomIniFile); override;
    procedure SaveWindowState(Desktop: TCustomIniFile;
      isProject: Boolean); override;
    // ESP-002 Demand 2/3: re-evaluate the onboarding empty-state in place after
    // a config save or command create, with no IDE restart (AC-08). Marshalled to
    // the main thread; safe to call from the composition-root callbacks.
    { Visual Scanner card. Marshalled to the main thread like every other panel
      write: the MCP server answers tool calls on its own thread, and touching a
      WebView from there is the class of bug the _RunOnMainThread seam exists to
      stop. }
    procedure EnqueueScannerPayload(const APayloadJson: string);
    procedure EnqueueScannerImage(const AImageId, ADataUri: string);
    procedure RefreshOnboarding;
    // Reset the panel to a fresh IDLE session (empty welcome, footer "ready.",
    // no typing indicator, Send button restored, turn state reconciled). Unlike
    // the IOutputPanelSurface Clear — which BEGINS a turn and shows the pulsing
    // "working..." indicator for an imminent dispatch — this is pure housekeeping
    // (e.g. an executor/provider switch, where the old CLI session was torn down
    // and there is NO run behind it). Marshalled to the main thread; safe from
    // the composition-root config-save callback.
    procedure ResetConversation;
    property OnCommand: TProc<string> read FOnCommand write FOnCommand;
    property OnStop: TProc read FOnStop write FOnStop;
    property OnIsRunning: TFunc<Boolean> read FOnIsRunning write FOnIsRunning;
    property OnNewSession: TProc read FOnNewSession write FOnNewSession;
    // Sessions/history hooks (see field comments above).
    property OnGetSession: TFunc<string> read FGetSession write FGetSession;
    property OnSetSession: TProc<string> read FSetSession write FSetSession;
    property OnGetExecutor: TFunc<string> read FGetExecutor write FGetExecutor;
    property OnTurnEnded: TProc read FOnTurnEnded write FOnTurnEnded;
    // Memory modal hooks (🧠 / /memory). OnMemoryLoad returns the current global
    // memory text to prefill; OnMemorySave persists the edited text.
    property OnMemoryLoad: TFunc<string> read FOnMemoryLoad write FOnMemoryLoad;
    property OnMemorySave: TProc<string> read FOnMemorySave write FOnMemorySave;
    // MCP Servers modal (🔌 / /mcp): Load returns the saved mcp-config JSON;
    // Save persists the edited config. Wired in Register to the CommandExecutor.
    // Addons returns the installed addons' aggregate (`aefos install`), shown
    // read-only in the modal — never saved back through OnMcpSave.
    property OnMcpLoad: TFunc<string> read FOnMcpLoad write FOnMcpLoad;
    property OnMcpSave: TProc<string> read FOnMcpSave write FOnMcpSave;
    property OnMcpAddons: TFunc<string> read FOnMcpAddons write FOnMcpAddons;
    // New Project wizard (/new-project): ListTemplates returns the template
    // library as JSON for the dropdown; CreateProject materialises the chosen
    // template (+ opens it) and returns a result JSON. Wired in Register.
    property OnListTemplates: TFunc<string>
      read FOnListTemplates write FOnListTemplates;
    property OnCreateProject: TFunc<string, string>
      read FOnCreateProject write FOnCreateProject;
    // Chat|Agent header toggle. True = Agent (IDE/MCP tools on, the model acts);
    // False = Chat (conversation only). Forwarded to SetCommandExecutorAgentMode.
    property OnSetAgentMode: TProc<Boolean>
      read FOnSetAgentMode write FOnSetAgentMode;
    // Header model selector. OnSetModel: the picked model id. OnGetModels: the
    // {"models":[...],"current":"..."} JSON fed to the dropdown. Wired in Register.
    property OnSetModel: TProc<string> read FOnSetModel write FOnSetModel;
    property OnGetModels: TFunc<string> read FOnGetModels write FOnGetModels;
    // Header reasoning-effort selector (executors that expose one). OnSetEffort:
    // the picked CLI token ('default'|low|medium|high|xhigh). The current value +
    // whether the control is shown ride in the OnGetModels JSON. Wired in Register.
    property OnSetEffort: TProc<string> read FOnSetEffort write FOnSetEffort;
    // Shows the destructive-action permission modal in the WebView2 and stores
    // AResolve, called (once) with the user's decision via the 'perm:*' host
    // message. Returns True if shown; False when the WebView2 isn't ready, so the
    // HTML presenter can fall back to the VCL modal. The presenter owns the wait.
    function ShowPermission(const AToolName, ASummary, ADetail: string;
      const AResolve: TProc<TMCPConsentDecision>): Boolean;
    // Cancels a pending consent (timeout/teardown): hides the modal + drops the
    // pending resolve so a late click is ignored.
    procedure CancelPermission;
    property OnOpenSettings: TProc read FOnOpenSettings write FOnOpenSettings;
    property OnOpenInspector: TProc read FOnOpenInspector write FOnOpenInspector;
    // ESP-002 Demand 2/3: CLI-path resolver (ResolveCLIBinary ladder, ADR-275)
    // and config-snapshot accessor injected by the composition root so the
    // panel can build a TOnboardingInput from live state without touching OTA.
    property CliPathResolver: TFunc<string>
      read FCliPathResolver write FCliPathResolver;
    property ConfigSnapshot: TFunc<TConfig>
      read FConfigSnapshot write FConfigSnapshot;
    property CommandPalette: ICommandPalette read FPalette write FPalette;
    property CommandRegistry: ICommandRegistry read FRegistry write FRegistry;
    property CommandReplicatorResolver: TFunc<ICommandReplicator>
      read FReplicatorResolver write FReplicatorResolver;
  end;

var
  GChatPanel: TAefosChatPanel;
  GChatPanelShuttingDown: Boolean = False;
  // Set by the composition root (Register) to its _EnsureChatPanel. ShowChatPanel
  // calls it first so the dock form is created + wired lazily on first open,
  // keeping the heavy form OUT of BPL load (an unused session then has no form to
  // tear down on unload -> clean in-place rebuild). Nil = no-op.
  GChatPanelEnsureHook: TProc = nil;
  // Set by the composition root to WIRE a specific panel instance (backend
  // callbacks) WITHOUT ever creating one. Called from _OnFormShow so a dock the
  // IDE RESTORED from a saved desktop (created bypassing the ensure hook) still
  // gets wired. Idempotent; no-op for an already-wired panel. Nil = no-op.
  GChatPanelWireHook: TProc<TObject> = nil;

type
  // Sealed static namespace owning the chat dock's BPL-lifecycle + show/surface
  // entry points (formerly loose interface routines nobody owned). Never
  // instantiated — the class IS the namespace. Method names are kept verbatim so
  // the IDE-unload-critical teardown call sites (Register._GuardedShutdown and
  // this unit's own finalization) change by NAME QUALIFICATION only, never by
  // body/order (UnloadContract — THE LAW).
  TChatPanelHost = class sealed
  public
    // Adopts a desktop-restored panel before creating one; binds GChatPanel.
    class procedure RegisterChatPanel; static;
    // Full panel teardown (focus drain -> undock -> FreeAndNil). IDE-unload
    // critical: body/order are byte-frozen (UnloadContract).
    class procedure UnregisterChatPanel; static;
    // Desktop-persistence class registration — call at BPL LOAD / teardown (NOT
    // per open) so the IDE can recreate the dock when restoring a saved desktop
    // at startup. Release-only inside (no-op in DEBUG). See impl for the AV
    // rationale.
    class procedure RegisterChatDesktopClass; static;
    class procedure UnregisterChatDesktopClass; static;
    // AFromUser=True (an explicit menu "Open Chat" click) ALWAYS forces the panel
    // forward — even if Visible reports True while the IDE hid the dock on a
    // layout switch. The dispatch calls it with the default (False) so the
    // per-submit anti-blink early-exit still applies.
    class procedure ShowChatPanel(AFromUser: Boolean = False); static;
    class function ChatPanelSurface: IOutputPanelSurface; static;

    /// <summary>
    ///   Pure routing predicate for the chat editing-key intercept (Terminal OP1
    ///   pattern, ESP-026/ESP-080). True only when a plain Ctrl+V/C/X/A/Z (Ctrl
    ///   down, Alt up) is pressed while the keystroke targets the chat surface —
    ///   the case where IsShortCut must answer "not a shortcut" so the WebView2
    ///   composer (or a focused VCL child) keeps its native editing behaviour
    ///   instead of losing the key to the IDE's global Edit action. Shift is
    ///   deliberately ignored so Ctrl+Shift+V/Z (paste-plain / redo) stay
    ///   reserved too, mirroring the _AppMessage hook. No VCL state —
    ///   headless-testable.
    /// </summary>
    class function ShouldReserveEditingKeyForChat(const ACharCode: Word;
      const ACtrlDown, AAltDown, AFocusInChat: Boolean): Boolean; static;
  end;

implementation

{$R *.dfm}

uses
  System.UITypes,
  Vcl.Clipbrd,
  System.JSON,
  Aefos.Compat.MainThread,
  System.DateUtils,
  System.IOUtils,
  System.NetEncoding,
  Vcl.Dialogs,
  Vcl.Themes,
  DeskUtil,
  Winapi.ShellAPI,
  ToolsAPI,
  Aefos.OTA.Chat.Core.ChatCommand,
  Aefos.OTA.Chat.Core.CommandAutoReplicate,
  Aefos.OTA.Chat.Core.SessionStore,
  Aefos.OTA.Chat.UI.AddonStoreForm,
  Aefos.Provider.Registry;

// Debug-only teardown/diagnostic breadcrumb. Unconditional OutputDebugString
// shipped in release builds was audit noise (a shipped IDE plugin); gate it so
// the breadcrumbs stay in DEBUG and release is silent. Behaviour-identical in DEBUG.
procedure _DbgLog(const AMsg: string);
begin
{$IFDEF DEBUG}
  OutputDebugString(PChar(AMsg));
{$ENDIF}
end;

// Saved Application.OnMessage that our editing-key hook (Ctrl+V/A/C/X/Z) prepends
// to and chains; the destructor restores it. (Vcl.AppEvnt/TApplicationEvents isn't
// linked in this IDE BPL, so we hook Application.OnMessage directly via Vcl.Forms.)
var
  GPrevAppOnMessage: TMessageEvent;
  // Unit-scope mirror of the per-instance root-form OnShortCut hook (FHookedRoot
  // / FPrevRootShortCut), so the BPL finalization safety net can force-restore
  // the hook even if the IDE-owned panel form was never destroyed (which would
  // otherwise leave a method pointer into this BPL on an IDE form — blocking the
  // unload and locking the .bpl, F2039).
  GHookedRoot: TCustomForm = nil;
  GPrevRootShortCut: TShortCutEvent;

const
  // '/' command-list popup geometry.
  CMDLIST_MAX_ROWS = 8;
  CMDLIST_ROW_HEIGHT = 18;

  // ESP-002 Demand 2/3: onboarding empty-state copy + step markers. Glyphs are
  // declared as char codes (encoding-safe, mirroring the gear/em-dash pattern).
  ONBOARDING_TITLE_TEXT =
    'Welcome to Aefos — let''s get you set up';
  ONBOARDING_HINT_TEXT =
    'Complete these steps to reach your first AI command. ' +
    'This guidance disappears once Aefos is configured.';
  ONBOARDING_GLYPH_DONE = #$2713;     // check mark — step done
  ONBOARDING_GLYPH_CURRENT = #$25B6;  // play triangle — current step
  ONBOARDING_GLYPH_PENDING = #$25CB;  // hollow circle — pending step
  ONBOARDING_STEP_GAP = '  ';

type
  // Exposes TWinControl.HandleNeeded so ReportError can force the output
  // window handle to allocate before the append (ADR-101).
  TWinControlAccess = class(TWinControl);
  // Exposes TCustomForm.OnShortCut (protected there; published only on TForm)
  // so the root-form hook can chain it without assuming a TForm descendant.
  TCustomFormAccess = class(TCustomForm);

class function TChatPanelHost.ShouldReserveEditingKeyForChat(const ACharCode: Word;
  const ACtrlDown, AAltDown, AFocusInChat: Boolean): Boolean;
begin
  Result := AFocusInChat and ACtrlDown and (not AAltDown) and
            ((ACharCode = Ord('V')) or (ACharCode = Ord('C')) or
             (ACharCode = Ord('X')) or (ACharCode = Ord('A')) or
             (ACharCode = Ord('Z')));
end;

procedure _DetachCnWizardsFromForm(AForm: TCustomForm);
var
  LIndex: Integer;
  LComp: TComponent;
  LControl: TControl;
  LClassName: string;
begin
  if not Assigned(AForm) then
    Exit;
  // Guarded teardown sweep: detach any CnPack/CnWizards components/controls left
  // on the form so the IDE cannot read a dead VMT after our BPL unmaps (see the
  // IDE-unload rules). Must never raise.
  try
    for LIndex := AForm.ComponentCount - 1 downto 0 do
    begin
      if LIndex < AForm.ComponentCount then
      begin
        LComp := AForm.Components[LIndex];
        if Assigned(LComp) then
        begin
          LClassName := LComp.ClassName.ToLower;
          if LClassName.StartsWith('tcn') or LClassName.Contains('cnpack') or LClassName.Contains('cnwizard') then
            AForm.RemoveComponent(LComp);
        end;
      end;
    end;
    for LIndex := AForm.ControlCount - 1 downto 0 do
    begin
      if LIndex < AForm.ControlCount then
      begin
        LControl := AForm.Controls[LIndex];
        if Assigned(LControl) then
        begin
          LClassName := LControl.ClassName.ToLower;
          if LClassName.StartsWith('tcn') or LClassName.Contains('cnpack') or LClassName.Contains('cnwizard') then
            LControl.Parent := nil;
        end;
      end;
    end;
  except
    // Teardown must never raise.
  end;
end;

{ TAefosChatPanel }

constructor TAefosChatPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Name := 'AefosChatPanel';
  Caption := 'Aefos Chat';
  // Default to Agent mode — matches the header toggle's default-active "Agent".
  FAgentMode := True;
  FQueuedMessages := TStringList.Create;
  Width := 420;
  Height := 600;
  OnShow := _OnFormShow;
  OnResize := _OnFormResize;
  ActiveControl := FInput;
  KeyPreview := True;
  
  // IDE desktop persistence (DeskSection/AutoSave + RegisterDesktopFormClass) is
  // DISABLED — in DEBUG *and* RELEASE. There is NO UnregisterDesktopFormClass, so
  // a Build-All-in-IDE leaves the registered class dangling and the AutoSave'd
  // .dst section makes the next desktop-layout load AV in DeskUtil.LoadWindow
  // (corrupted "Default" layout, crash on project open — 2026-06-16). No
  // DeskSection (stays '') so the form is never keyed into the desktop INI; Path B
  // (debugger-notifier re-show) covers the chat reappearing instead.
  SaveStateNecessary := False;
  AutoSave := False;

  // Delegate the focus/dock lifecycle to the plain-VCL seam (ADR-219). FInput
  // is streamed by `inherited Create`, so it is available here.
  FFocusLifecycle := TChatPanelFocusLifecycle.Create(Self);
  FFocusLifecycle.SetTarget(FInput);

  _CreateSettingsButton;

  // Embed the WebView2 controller into the client container (ADR-241/242).
  // Visible=False: FWelcomePanel is shown initially; the browser becomes
  // visible on the first AppendChunk call (_EnsureOutputVisible). AParent
  // owns the TEdgeBrowser component.
  if Assigned(FClientContainer) then
    FController := TOutputPanelEdgeController.Create(FClientContainer);
  // JS->Pascal bridge: empty-state chip clicks (action:xxx) prefill the input
  // with the matching slash command.
  if Assigned(FController) then
  begin
    FController.OnHostMessage := _OnHostMessage;
    // Hook the editing keys (Ctrl+V/A/C/X/Z) at the application level (see
    // _AppMessage): prepend to the existing Application.OnMessage and chain to it
    // for everything else; the destructor restores it.
    GPrevAppOnMessage := Application.OnMessage;
    Application.OnMessage := _AppMessage;
  end;

  // ESP-002 Demand 2/3: build the first-run onboarding overlay inside the
  // welcome surface (ADR-274). Hidden until _EvaluateAndRenderOnboarding shows
  // it for a not-ready state; the DFM is left untouched.
  _CreateOnboardingPanel;

  // Surface the modern WebView2 empty-state (#ds-empty in OutputPanel.Assets:
  // big Aefos logo + action chips) from the start, replacing the legacy
  // VCL welcome cards. Reuses the welcome->browser transition (deferred radIA
  // Navigate). Conditional on _UseBrowser so a WebView2-less host keeps the VCL
  // fallback. SAFE: the unload crash this once seemed to cause was actually the
  // AgentSuggest keyboard-binding use-after-free (now fixed) — navigating the
  // browser early no longer corrupts the heap on teardown.
  if _UseBrowser then
  begin
    _EnsureOutputVisible;
    // Input moved into the WebView2 (HTML composer in OutputPanel.Assets:
    // #ds-composer) — drop the VCL input strip so the browser fills the whole
    // body. REVERSIBLE: show these again to fall back to the VCL input/picker.
    if Assigned(FSplitter) then
      FSplitter.Visible := False;
    if Assigned(FBottomContainer) then
      FBottomContainer.Visible := False;
    // Header (CHAT/AGENT toggle + actions) and session bar moved into the
    // WebView2 (HTML #ds-header / #ds-ctx in OutputPanel.Assets) — drop the VCL
    // top strips so the browser fills the whole panel, same pattern as the
    // composer above. REVERSIBLE: show these again to fall back to the VCL top.
    if Assigned(FHeaderPanel) then
      FHeaderPanel.Visible := False;
    if Assigned(FSessionPanel) then
      FSessionPanel.Visible := False;
  end;
end;

procedure TAefosChatPanel._CreateSettingsButton;
begin
  // A discoverable gear-style settings link in the header, sitting just left of
  // the "New command" (+) button. Created here so the DFM stays untouched.
  if not Assigned(FHeaderPanel) then
    Exit;
  FSettingsBtn := TButton.Create(Self);
  FSettingsBtn.Parent := FHeaderPanel;
  FSettingsBtn.Cursor := crHandPoint;
  FSettingsBtn.Caption := #$2699; // gear glyph
  FSettingsBtn.Hint := 'Aefos settings (Tools > Options)';
  FSettingsBtn.ShowHint := True;
  FSettingsBtn.Width := 24;
  FSettingsBtn.Height := 24;
  FSettingsBtn.AlignWithMargins := True;
  FSettingsBtn.Margins.SetBounds(0, 6, 6, 6);
  FSettingsBtn.Align := alRight;
  FSettingsBtn.OnClick := _OnSettingsClick;
end;

procedure TAefosChatPanel._OnSettingsClick(Sender: TObject);
begin
  if Assigned(FOnOpenSettings) then
    FOnOpenSettings();
end;

procedure TAefosChatPanel._PushSessionInfo;
begin
  // Feed the HTML context line (#ds-ctx) from the locally tracked title/count.
  // Browser-only path; no-op until the page is live (controller guards FReady).
  if Assigned(FController) then
    FController.SetSessionInfo(FSessionTitle, FSessionCount, '');
end;

procedure TAefosChatPanel._ResetSessionInfo;
begin
  FSessionTitle := '';
  FSessionCount := 0;
  _PushSessionInfo;
end;

procedure TAefosChatPanel._SaveCurrentSession;
var
  LEntry: TSessionEntry;
  LId: string;
begin
  // Persist the live conversation (CLI-agnostic on-disk index). Keyed by the
  // executor's --session-id: with no id (or no controller) there is nothing
  // meaningful to record, so skip. The recorded messages come straight from the
  // controller's history (same array dsReplay consumes).
  if not Assigned(FGetSession) or not Assigned(FController) then
    Exit;
  LId := FGetSession();
  if LId = '' then
    Exit;
  LEntry := Default(TSessionEntry);
  LEntry.Id := LId;
  if Trim(FSessionTitle) <> '' then
    LEntry.Title := FSessionTitle
  else
    LEntry.Title := '(untitled)';
  // Whoever is actually running this conversation -- never a literal. '' when the
  // composition root did not wire the hook, so the row stays silent about it.
  if Assigned(FGetExecutor) then
    LEntry.Cli := Trim(FGetExecutor())
  else
    LEntry.Cli := '';
  LEntry.Project := '';
  LEntry.Updated := Now;
  LEntry.Count := FSessionCount;
  LEntry.MessagesJson := FController.GetHistoryJson;
  // Never clobber a stored conversation with an empty record: a positive count
  // with no messages means the history isn't loaded (the resume-then-save bug).
  // Skipping the save preserves what's on disk. (ReplayMessages now re-seeds the
  // controller's history on resume, so this is a belt-and-suspenders guard.)
  if SessionSaveWouldClobber(LEntry.MessagesJson, LEntry.Count) then
    Exit;
  SaveSession(LEntry);
end;

procedure TAefosChatPanel._OpenSessionsPanel;
var
  LList: TArray<TSessionEntry>;
  LArr: TJSONArray;
  LObj: TJSONObject;
  LEntry: TSessionEntry;
  LCurrentId: string;
begin
  if not Assigned(FController) then
    Exit;
  // Make sure the live conversation is on disk before we list, so the CURRENT row
  // reflects the latest title/count even if no response has completed yet.
  _SaveCurrentSession;
  LCurrentId := '';
  if Assigned(FGetSession) then
    LCurrentId := FGetSession();
  LList := LoadSessions;
  LArr := TJSONArray.Create;
  try
    for LEntry in LList do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', LEntry.Id);
      LObj.AddPair('title', LEntry.Title);
      // The row shows the DISPLAY name ('Codex'), not the config token ('codex').
      // TokenDisplayName returns '' for a session stored before the executor was
      // recorded -- deliberately, so an unlabelled row says nothing rather than
      // inheriting ParseExecutorKind's ekClaude default and lying again.
      LObj.AddPair('cli', TProviderRegistry.TokenDisplayName(LEntry.Cli));
      LObj.AddPair('when', FormatDateTime('dd/mm hh:nn:ss', LEntry.Updated));
      LObj.AddPair('count', TJSONNumber.Create(LEntry.Count));
      LObj.AddPair('current',
        TJSONBool.Create((LEntry.Id <> '') and (LEntry.Id = LCurrentId)));
      LArr.AddElement(LObj);
    end;
    FController.ShowSessions(LArr.ToJSON);
  finally
    LArr.Free;
  end;
end;

procedure TAefosChatPanel._ResumeSession(const AId: string);
var
  LEntry: TSessionEntry;
begin
  if (AId = '') or not Assigned(FController) then
    Exit;
  if not TryLoadSession(AId, LEntry) then
    Exit;
  // Adopting another conversation orphans the current send-during-run queue.
  _ClearQueuedMessages;
  // Put the stored conversation back on screen (dsReplay) and arm the executor
  // to --resume this id on the next dispatch (so the AI remembers it too).
  FController.ReplayMessages(LEntry.MessagesJson);
  if Assigned(FSetSession) then
    FSetSession(AId);
  FSessionTitle := LEntry.Title;
  FSessionCount := LEntry.Count;
  _PushSessionInfo;
end;

procedure TAefosChatPanel._DeleteSessionFromPanel(const AId: string);
begin
  if (AId = '') or not Assigned(FController) then
    Exit;
  // Deleting the LIVE session: clear the conversation and drop the CLI session
  // first, so the executor never tries to --resume the id we just removed.
  if Assigned(FGetSession) and (FGetSession() = AId) then
  begin
    FController.ResetConversation;
    _ResetSessionInfo;
    if Assigned(FOnNewSession) then
      FOnNewSession();
  end;
  DeleteSession(AId);
  // Re-list so the deleted row disappears (the panel stays open).
  _OpenSessionsPanel;
end;

procedure TAefosChatPanel._CreateOnboardingPanel;

  function _NewStackedLabel(const ABottomMargin: Integer): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := FOnboardingPanel;
    Result.Align := alTop;
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(0, 0, 0, ABottomMargin);
    Result.WordWrap := True;
  end;

  function _NewStepButton(const ACaption: string;
    const AOnClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := FOnboardingPanel;
    Result.Align := alTop;
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(0, 0, 0, 8);
    Result.Height := 32;
    Result.Cursor := crHandPoint;
    Result.Caption := ACaption;
    Result.OnClick := AOnClick;
  end;

begin
  // The overlay covers the welcome cards (ADR-274 / C-5: single surface) and is
  // shown only when the derived state is not osReady. Default theming (no color
  // overrides) keeps it legible under the IDE dark/light themes — and identical
  // whether or not WebView2 is present, which subsumes the TRichEdit-fallback
  // legibility requirement (R-4); the affordances must be native VCL buttons
  // because the WebView2 shell has no web-message -> Delphi callback channel.
  if not Assigned(FWelcomePanel) then
    Exit;
  FOnboardingPanel := TPanel.Create(Self);
  FOnboardingPanel.Parent := FWelcomePanel;
  FOnboardingPanel.Align := alClient;
  FOnboardingPanel.BevelOuter := bvNone;
  FOnboardingPanel.Padding.SetBounds(24, 24, 24, 24);
  FOnboardingPanel.Visible := False;

  FOnboardingTitle := _NewStackedLabel(12);
  FOnboardingTitle.Caption := ONBOARDING_TITLE_TEXT;
  FOnboardingTitle.Font.Style := [fsBold];
  FOnboardingTitle.Font.Size := 12;

  FOnboardingChecklist := _NewStackedLabel(12);
  FOnboardingChecklist.Font.Size := 10;

  FOnboardingSetExecutorBtn :=
    _NewStepButton(ONBOARDING_STEP_EXECUTOR, _OnSettingsClick);

  FOnboardingHint := _NewStackedLabel(0);
  FOnboardingHint.Caption := ONBOARDING_HINT_TEXT;
end;

function TAefosChatPanel._CommandCount: Integer;
begin
  // TCommandRegistry.List never raises — it returns an empty array when no
  // project is active or the commands folder is absent (ADR-011).
  Result := 0;
  if Assigned(FRegistry) then
    Result := Length(FRegistry.List);
end;

function TAefosChatPanel._BuildOnboardingInput: TOnboardingInput;
var
  LConfig: TConfig;
begin
  // Detection reuses the injected ResolveCLIBinary ladder (ADR-275); a config
  // path set but absent on disk already resolves to '' upstream (AC-06).
  Result.ResolvedCliPath := '';
  if Assigned(FCliPathResolver) then
    Result.ResolvedCliPath := FCliPathResolver();
  if Assigned(FConfigSnapshot) then
    LConfig := FConfigSnapshot()
  else
    LConfig := DefaultConfig;
  Result.Executor := LConfig.Executor;
  Result.CommandCount := _CommandCount;
end;

function TAefosChatPanel._StepMarker(const APlan: TOnboardingPlan;
  const AStepIndex: Integer): string;
begin
  if APlan.Steps[AStepIndex].Done then
    Result := ONBOARDING_GLYPH_DONE
  else if AStepIndex = APlan.CurrentStepIndex then
    Result := ONBOARDING_GLYPH_CURRENT
  else
    Result := ONBOARDING_GLYPH_PENDING;
end;

function TAefosChatPanel._BuildChecklistText(
  const APlan: TOnboardingPlan): string;
var
  LBuilder: TStringBuilder;
  LIndex: Integer;
begin
  LBuilder := TStringBuilder.Create;
  try
    for LIndex := Low(APlan.Steps) to High(APlan.Steps) do
    begin
      if LIndex > Low(APlan.Steps) then
        LBuilder.AppendLine;
      LBuilder.Append(_StepMarker(APlan, LIndex));
      LBuilder.Append(ONBOARDING_STEP_GAP);
      LBuilder.Append(APlan.Steps[LIndex].Caption);
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

procedure TAefosChatPanel._EvaluateAndRenderOnboarding;
var
  LPlan: TOnboardingPlan;
begin
  if not Assigned(FOnboardingPanel) then
    Exit;
  // BR-1: derive the state every call; nothing is persisted.
  LPlan := EvaluateOnboarding(_BuildOnboardingInput);
  if LPlan.State = osReady then
  begin
    // BR-5: a configured + commanded user keeps the unchanged welcome->output
    // behaviour — no guidance is ever shown.
    FOnboardingPanel.Visible := False;
    Exit;
  end;
  FOnboardingChecklist.Caption := _BuildChecklistText(LPlan);
  // Surface the checklist only while the welcome panel is showing; once the
  // output area takes over (first dispatch) the overlay hides with its parent.
  if FWelcomePanel.Visible then
  begin
    FOnboardingPanel.Visible := True;
    FOnboardingPanel.BringToFront;
  end;
end;

procedure TAefosChatPanel.RefreshOnboarding;
begin
  _RunOnMainThread(
    procedure
    begin
      _EvaluateAndRenderOnboarding;
    end);
end;

destructor TAefosChatPanel.Destroy;
var
  LParentForm: TCustomForm;
begin
  _DbgLog('[Aefos] TAefosChatPanel.Destroy started.');
  GChatPanelShuttingDown := True;
  FreeAndNil(FQueuedMessages);

  // Restore the Application.OnMessage we hooked for Ctrl+V — only if it's still
  // ours (guards against another handler having replaced it after us). Leaving a
  // method of this dying form wired would crash on the next message.
  if TMethod(Application.OnMessage).Data = Self then
    Application.OnMessage := GPrevAppOnMessage;

  // Release the root-form OnShortCut hook before any teardown re-parenting;
  // a dying form's method left wired there would crash the next keystroke.
  _UnhookRootShortCut;

  // 1. Shut down the focus seam: mark shutting-down and drain its single pending
  // queued event, then free it. Done before `inherited Destroy` so any SetParent
  // it triggers finds the seam gone (delegation is Assigned-guarded) and cannot
  // queue a focus op against the dying panel.
  if Assigned(FFocusLifecycle) then
  begin
    FFocusLifecycle.BeginShutdown;
    FreeAndNil(FFocusLifecycle);
  end;

  // 2. Clear active control to prevent the styling hooks from querying it during deactivation
  try
    _DbgLog('[Aefos] TAefosChatPanel.Destroy: Clearing active control.');
    ActiveControl := nil;
  except
    on E: Exception do
      _DbgLog('[Aefos] TAefosChatPanel.Destroy active control clear error: ' + E.Message);
  end;

  // 3. Detach CnWizards components/controls from ourselves and the parent host form wrapper
  // BEFORE shifting focus or executing RefocusTopWindow (which triggers deactivation).
  try
    _DetachCnWizardsFromForm(Self);
    LParentForm := GetParentForm(Self);
    if Assigned(LParentForm) and (LParentForm <> Self) then
      _DetachCnWizardsFromForm(LParentForm);
  except
    on E: Exception do
      _DbgLog('[Aefos] TAefosChatPanel.Destroy parent form detach error: ' + E.Message);
  end;

  // 4. Shift keyboard focus safely to the IDE main window
  try
    _DbgLog('[Aefos] TAefosChatPanel.Destroy: Shifting focus away via RefocusTopWindow.');
    RefocusTopWindow;
  except
    on E: Exception do
      _DbgLog('[Aefos] TAefosChatPanel.Destroy RefocusTopWindow error: ' + E.Message);
  end;

  // 5. Nullify the global reference so that finalization unregistering is a clean no-op
  if GChatPanel = Self then
  begin
    _DbgLog('[Aefos] TAefosChatPanel.Destroy: Nullifying global GChatPanel pointer.');
    GChatPanel := nil;
  end;

  // 6. Free the WebView2 controller before inherited destroys FClientContainer
  // (which owns the TEdgeBrowser component). The controller nils the
  // OnCreateWebViewCompleted callback in its destructor to prevent late-fire.
  FreeAndNil(FController);

  inherited Destroy;
  _DbgLog('[Aefos] TAefosChatPanel.Destroy completed successfully.');
end;

procedure TAefosChatPanel.CreateWnd;
begin
  inherited CreateWnd;
  _ApplyTheme;
  // An HWND RECREATE (re-dock / desktop-layout restore) blanks the embedded
  // WebView2. Re-navigate so the shell reloads + the conversation replays. The
  // controller self-guards (no-op before the first nav) and debounces the
  // _ApplyTheme/RecreateWnd re-entrancy, so calling it here every time is safe.
  if Assigned(FController) then
    FController.RenavigateAfterRecreate(_BuildPanelTheme);
end;

// Focus restoration now lives in the plain-VCL seam (FFocusLifecycle). These
// handlers only forward the activation/re-parent events; the seam applies the
// validity invariant (ADR-220) so a stale op cannot touch a re-parented or
// destroying panel.

procedure TAefosChatPanel.WMSetFocus(var Message: TWMSetFocus);
begin
  inherited;
  if Assigned(FFocusLifecycle) then
    FFocusLifecycle.ScheduleRestore;
end;

procedure TAefosChatPanel.WMMouseActivate(var Message: TWMMouseActivate);
begin
  inherited;
  Message.Result := MA_ACTIVATE;
  if Assigned(FFocusLifecycle) then
    FFocusLifecycle.ScheduleRestore;
end;

procedure TAefosChatPanel.CMActivate(var Message: TMessage);
begin
  inherited;
  if Assigned(FFocusLifecycle) then
    FFocusLifecycle.ScheduleRestore;
end;

procedure TAefosChatPanel.SetParent(AParent: TWinControl);
begin
  inherited SetParent(AParent);
  if AParent <> nil then
    Self.DoubleBuffered := False;
  if Assigned(FFocusLifecycle) then
    FFocusLifecycle.HandleSetParent(AParent);
  // Docking/undocking changes the root form Vcl.Edge consults for accelerator
  // keys — move the OnShortCut hook to the new root (no-op when unchanged).
  if not (csDestroying in ComponentState) then
    _HookRootShortCut;
end;

procedure TAefosChatPanel.BeginFocusShutdown;
begin
  if Assigned(FFocusLifecycle) then
    FFocusLifecycle.BeginShutdown;
end;

procedure TAefosChatPanel.EnqueueScannerPayload(const APayloadJson: string);
begin
  _RunOnMainThread(
    procedure
    begin
      if Assigned(FController) then
        FController.EnqueueScanner(APayloadJson);
    end);
end;

procedure TAefosChatPanel.EnqueueScannerImage(const AImageId,
  ADataUri: string);
begin
  _RunOnMainThread(
    procedure
    begin
      if Assigned(FController) then
        FController.EnqueueScannerImage(AImageId, ADataUri);
    end);
end;

procedure TAefosChatPanel._RunOnMainThread(AProc: TProc);
begin
  if TThread.Current.ThreadID = MainThreadID then
  begin
    if not GChatPanelShuttingDown and not (csDestroying in ComponentState) then
      AProc();
  end
  else
  begin
    TThread.Synchronize(nil, procedure
    begin
      if not GChatPanelShuttingDown and not (csDestroying in ComponentState) then
        AProc();
    end);
  end;
end;


// Reads a string field from AObj the way the rest of the codebase does it
// (non-generic GetValue + nil check), returning '' when absent or not a string.
function _JsonStr(const AObj: TJSONObject; const AKey: string): string;
var
  LField: TJSONValue;
begin
  Result := '';
  LField := AObj.GetValue(AKey);
  if LField is TJSONString then
    Result := TJSONString(LField).Value;
end;

procedure TAefosChatPanel._OpenMcpModal;
var
  LUser, LAddons: string;
begin
  // The user's saved config prefills the editable rows; the addon aggregate
  // (`aefos install`) renders as read-only ADDON rows so an installed MCP
  // addon is VISIBLE here too, not only merged silently into the dispatch.
  LUser := '';
  if Assigned(FOnMcpLoad) then
    LUser := FOnMcpLoad();
  LAddons := '';
  if Assigned(FOnMcpAddons) then
    LAddons := FOnMcpAddons();
  if Assigned(FController) then
    FController.ShowMcpServers(LUser, LAddons);
end;

procedure TAefosChatPanel._OpenCommandEditorNew;
var
  LObj: TJSONObject;
  LUpsell: string;
begin
  // /command path (ADR-250): open the HTML editor on a blank "new" form.
  if not (Assigned(FController) and Assigned(FRegistry)) then
  begin
    AppendChunk(sLineBreak + '--- command registry unavailable ---' +
      sLineBreak, stStderr);
    Exit;
  end;
  // Make sure the WebView2 page is live so the modal call lands.
  if _UseBrowser then
    _EnsureOutputVisible;
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('isNew', TJSONBool.Create(True));
    FController.ShowCommandEditor(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

procedure TAefosChatPanel._OpenAttachDialog;
var
  LDlg: TOpenDialog;
begin
  if not Assigned(FController) then
    Exit;
  LDlg := TOpenDialog.Create(nil);
  try
    LDlg.Title := 'Attach a file';
    LDlg.Options := LDlg.Options + [ofFileMustExist, ofPathMustExist];
    LDlg.Filter :=
      'All files (*.*)|*.*' +
      '|Source (*.pas;*.dpr;*.dpk;*.inc;*.dfm)|*.pas;*.dpr;*.dpk;*.inc;*.dfm' +
      '|Images (*.png;*.jpg;*.jpeg;*.gif;*.bmp)|*.png;*.jpg;*.jpeg;*.gif;*.bmp';
    if LDlg.Execute then
      // File picker → a file-icon chip (no thumbnail). The path rides along on
      // send so the agent reads it.
      FController.AddAttachment(LDlg.FileName, 'file', '');
  finally
    LDlg.Free;
  end;
end;

procedure TAefosChatPanel._SavePastedImage(const ABase64: string);
var
  LBytes: TBytes;
  LPath: string;
begin
  if not Assigned(FController) then
    Exit;
  try
    LBytes := TNetEncoding.Base64.DecodeStringToBytes(ABase64);
    if Length(LBytes) = 0 then
      Exit;
    LPath := TPath.Combine(TPath.GetTempPath,
      'ds_paste_' + GUIDToString(TGuid.NewGuid).Replace('{', '').Replace('}', '') + '.png');
    TFile.WriteAllBytes(LPath, LBytes);
    // Pasted image → a thumbnail chip (reuse the base64 we received as the data
    // URL). The temp path rides along on send so the agent's Read sees the image.
    FController.AddAttachment(LPath, 'image', 'data:image/png;base64,' + ABase64);
  except
    // A malformed clipboard payload must never break the chat.
  end;
end;

procedure TAefosChatPanel._SendCommandList;
var
  LList: TArray<TCommandMetadata>;
  LArr: TJSONArray;
  LObj: TJSONObject;
  LIndex: Integer;
begin
  if not (Assigned(FController) and Assigned(FRegistry)) then
    Exit;
  // List of editable commands (name + description) for the "edit existing"
  // dropdown. Registry.List is defensive (malformed entries skipped).
  LList := FRegistry.List;
  LArr := TJSONArray.Create;
  try
    for LIndex := 0 to High(LList) do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('name', LList[LIndex].Name);
      LObj.AddPair('description', LList[LIndex].Description);
      LArr.AddElement(LObj);
    end;
    FController.SetCommandList(LArr.ToJSON);
  finally
    LArr.Free;
  end;
end;

// Feeds the slash-command picker (HTML): the static built-ins (UI-modal +
// agentic from Core.BuiltInCommands) PLUS the user-registered commands. Single
// source — the registry for agentic built-ins, FRegistry for stored commands.
procedure TAefosChatPanel._SendPickerCommands;
var
  LArr: TJSONArray;
  LB: TBuiltInCommand;
  LList: TArray<TCommandMetadata>;
  LIndex: Integer;
  procedure AddCmd(const AName, ADesc, ABadge: string);
  var
    LItem: TJSONObject;
  begin
    LItem := TJSONObject.Create;
    LItem.AddPair('name', AName);
    LItem.AddPair('desc', ADesc);
    LItem.AddPair('badge', ABadge);
    LArr.AddElement(LItem);
  end;
begin
  if not Assigned(FController) then
    Exit;
  LArr := TJSONArray.Create;
  try
    // All built-ins (UI-modal + agentic) come from the single registry.
    for LB in BuiltInCommands do
      AddCmd(LB.Name, LB.Description, 'builtin');
    // User-registered (stored) commands.
    if Assigned(FRegistry) then
    begin
      LList := FRegistry.List;
      for LIndex := 0 to High(LList) do
        AddCmd(LList[LIndex].Name, LList[LIndex].Description, 'command');
    end;
    FController.SetPickerCommands(LArr.ToJSON);
  finally
    LArr.Free;
  end;
end;

procedure TAefosChatPanel._LoadCommandIntoEditor(const AName: string);
var
  LCommand: TCanonicalCommand;
  LScope: string;
  LObj: TJSONObject;
begin
  if not (Assigned(FController) and Assigned(FRegistry)) then
    Exit;
  try
    LCommand := FRegistry.LoadCommand(AName);
  except
    on E: ECommandRegistryError do
    begin
      AppendChunk(sLineBreak + Format('--- could not load command "%s": %s ---',
        [AName, E.Message]) + sLineBreak, stStderr);
      Exit;
    end;
  end;
  // Reflect the catalogue the command lives in so the modal's scope toggle
  // opens on the right side (LoadCommand carries no scope; Get does).
  LScope := 'project';
  try
    if FRegistry.Get(AName).Scope = csGlobal then
      LScope := 'global';
  except
    on E: ECommandRegistryError do
      LScope := 'project';
  end;
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('name', LCommand.Name);
    LObj.AddPair('description', LCommand.Description);
    LObj.AddPair('prompt', LCommand.Instructions);
    LObj.AddPair('scope', LScope);
    LObj.AddPair('isNew', TJSONBool.Create(False));
    // ICommandRegistry exposes no Delete: keep the Delete button hidden (the JS
    // gates it on canDelete). RELATED in the report.
    LObj.AddPair('canDelete', TJSONBool.Create(False));
    FController.ShowCommandEditor(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

procedure TAefosChatPanel._SaveCommandFromJson(const AJson: string);
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
  LCommand: TCanonicalCommand;
  LScope: TCommandScope;
  LRep: ICommandReplicator;
begin
  if not Assigned(FRegistry) then
  begin
    AppendChunk(sLineBreak + '--- command registry unavailable ---' +
      sLineBreak, stStderr);
    Exit;
  end;
  LRoot := TJSONObject.ParseJSONValue(AJson);
  if not (LRoot is TJSONObject) then
  begin
    LRoot.Free;
    AppendChunk(sLineBreak + '--- invalid command payload ---' +
      sLineBreak, stStderr);
    Exit;
  end;
  LScope := csProject;
  try
    LObj := TJSONObject(LRoot);
    LCommand := Default(TCanonicalCommand);
    LCommand.Name := _JsonStr(LObj, 'name');
    LCommand.Description := _JsonStr(LObj, 'description');
    LCommand.Instructions := _JsonStr(LObj, 'prompt');
    // scope defaults to project; only an explicit "global" retargets the write.
    if SameText(_JsonStr(LObj, 'scope'), 'global') then
      LScope := csGlobal;
  finally
    LRoot.Free;
  end;
  // ADR-250: the registry is the sole SaveCommand writer (REUSED here — the JS
  // modal replaces the VCL form, not the persistence path). SaveCommand validates
  // the name/description and raises ECommandMalformed on bad input.
  try
    FRegistry.SaveCommand(LCommand, LScope);
  except
    on E: ECommandRegistryError do
    begin
      AppendChunk(sLineBreak + Format('--- could not save command: %s ---',
        [E.Message]) + sLineBreak, stStderr);
      Exit;
    end;
  end;
  AppendChunk(sLineBreak + Format('--- command "%s" saved ---',
    [LCommand.Name]) + sLineBreak, stStdout);
  _RefreshCommandListIfOpen;
  _EvaluateAndRenderOnboarding;
  // Auto-replicate the saved command to the active executor target folder.
  if Assigned(FReplicatorResolver) then
  begin
    LRep := FReplicatorResolver();
    if Assigned(LRep) then
      AppendChunk(sLineBreak + FormatAutoReplicationSummary(
        TryAutoReplicate(LRep)) + sLineBreak, stStdout);
  end;
end;

procedure TAefosChatPanel._DeleteCommand(const AName: string);
begin
  // ICommandRegistry exposes no delete contract (RELATED in the report). The JS
  // keeps the Delete button hidden (canDelete=false), so this is only reached
  // defensively — surface a clear message rather than become a 2nd writer.
  AppendChunk(sLineBreak +
    Format('--- delete "%s": not yet supported by the registry ---', [AName]) +
    sLineBreak, stStderr);
end;

procedure TAefosChatPanel._ApplyThemeTo(const AComponent: TComponent);
{$IF Declared(IOTAIDEThemingServices)}
var
  LThemeServices: IOTAIDEThemingServices;
{$IFEND}
begin
  // Older IOTAIDEThemingServices (NOT the 250 variant). The 250 variant
  // triggers RecreateWnd inside ApplyTheme(Self), which re-enters CreateWnd
  // → _ApplyTheme → infinite loop on this form's layout. The older surface
  // applies theme in-place and is what the panel has shipped with.
  //
  // Neither surface exists on an IDE that had no themes (10 Seattle), so there
  // the component simply keeps its own colours.
  {$IF Declared(IOTAIDEThemingServices)}
  if Assigned(BorlandIDEServices) and
    Supports(BorlandIDEServices, IOTAIDEThemingServices, LThemeServices) then
  try
    LThemeServices.ApplyTheme(AComponent);
  except
    on E: Exception do
      _DbgLog('[Aefos] ApplyThemeTo: '
        + E.ClassName + ' - ' + E.Message);
  end;
  {$IFEND}
end;

{$IF Declared(IOTAIDEThemingServices)}
procedure TAefosChatPanel._ApplyTheme;
var
  LThemeServices: IOTAIDEThemingServices;
  LIsDark: Boolean;
  LCardBg, LCardBorder, LInputBg, LInputBorder, LHeaderBg, LTextGray: TColor;
  LOrangeColor: TColor;

  function ChooseColor(ACond: Boolean; ATrue, AFalse: TColor): TColor;
  begin
    if ACond then
      Result := ATrue
    else
      Result := AFalse;
  end;
begin
  if not (Assigned(BorlandIDEServices) and
    Supports(BorlandIDEServices, IOTAIDEThemingServices, LThemeServices)) then
    Exit;

  // 1. Apply native IDE theme via the older IOTAIDEThemingServices surface.
  //    The newer 250 variant triggers RecreateWnd internally → re-enters
  //    CreateWnd → _ApplyTheme → infinite loop. Kept inside try/except so
  //    any theming exception is logged instead of bubbling up.
  try
    LThemeServices.ApplyTheme(Self);
  except
    on E: Exception do
      _DbgLog('[Aefos] ApplyTheme(Self): '
        + E.ClassName + ' - ' + E.Message);
  end;

  // 2. Detect whether the applied theme is Dark based on the background color
  LIsDark := True;
  if Self.Color <> clNone then
  begin
    // Perceived luminance (YIQ)
    LIsDark := ( (0.299 * GetRValue(ColorToRGB(Self.Color))) +
                 (0.587 * GetGValue(ColorToRGB(Self.Color))) +
                 (0.114 * GetBValue(ColorToRGB(Self.Color))) ) < 128;
  end;

  // 3. Define the differentiated color palette for the Cards and Inputs based on the theme
  LOrangeColor := $00007AFF; // Premium orange (#FF7A00 in RGB)

  if LIsDark then
  begin
    // Dark theme - deep, contrasting colors
    LCardBg       := $00231F1F; // Elegant dark gray for the cards
    LCardBorder   := $00302A2A; // Medium gray for borders
    LInputBg      := $00231F1F; // Input background
    LInputBorder  := $00302A2A; // Input border
    LHeaderBg     := $0012120F; // Slightly darker top
    LTextGray     := $00A5A0A0; // Secondary text
  end
  else
  begin
    // Light theme - soft, modern contrast
    LCardBg       := $00F7F7F7; // Light cards
    LCardBorder   := $00E2E2E2; // Light gray borders
    LInputBg      := $00FFFFFF; // Fully white input
    LInputBorder  := $00D0D0D0; // Visible input border
    LHeaderBg     := $00EAEAEA; // Contrasting light gray top
    LTextGray     := $00606060; // Medium gray secondary text
  end;

  // 4. Apply the blacklist and the custom colors for visual depth

  // Header and Status
  if Assigned(FHeaderPanel) then
  begin
    FHeaderPanel.StyleElements := [seFont];
    FHeaderPanel.Color := LHeaderBg;
    FHeaderPanel.ParentBackground := False;
  end;
  if Assigned(FStatusPanel) then
  begin
    FStatusPanel.StyleElements := [seFont];
    FStatusPanel.Color := LHeaderBg;
    FStatusPanel.ParentBackground := False;
  end;

  // Orange accent elements (the blacklist that does NOT take the theme's gray color)
  if Assigned(FLabelSparkle) then
    FLabelSparkle.Font.Color := LOrangeColor;
    
  if Assigned(LabelGreetingRight) then
    LabelGreetingRight.Font.Color := LOrangeColor;

  if Assigned(FNewTag) then
  begin
    FNewTag.StyleElements := [seFont];
    FNewTag.Color := LOrangeColor;
    FNewTag.ParentBackground := False;
  end;
  if Assigned(LabelNewTagText) then
    LabelNewTagText.Font.Color := clWhite;

  // Session and Tip
  if Assigned(ShapeSessionDot) then
  begin
    ShapeSessionDot.Brush.Color := $0025D366; // WhatsApp green, always lit and alive!
  end;

  if Assigned(LabelSessionInfoText) then
    LabelSessionInfoText.Font.Color := LTextGray;

  if Assigned(FLabelSessionTime) then
    FLabelSessionTime.Font.Color := LTextGray;

  // Cards - backgrounds and borders (depth differentiation via TShape)
  if Assigned(CardExplain) then
  begin
    CardExplain.StyleElements := [seFont, seClient, seBorder];
    CardExplain.ParentBackground := True;
    CardExplain.BevelOuter := bvNone;
    CardExplain.BevelInner := bvNone;
  end;
  if Assigned(ShapeExplainBg) then
  begin
    ShapeExplainBg.StyleElements := [seFont];
    ShapeExplainBg.Pen.Color := LCardBorder;
    ShapeExplainBg.Brush.Color := LCardBg;
  end;

  if Assigned(CardRefactor) then
  begin
    CardRefactor.StyleElements := [seFont, seClient, seBorder];
    CardRefactor.ParentBackground := True;
    CardRefactor.BevelOuter := bvNone;
    CardRefactor.BevelInner := bvNone;
  end;
  if Assigned(ShapeRefactorBg) then
  begin
    ShapeRefactorBg.StyleElements := [seFont];
    ShapeRefactorBg.Pen.Color := LCardBorder;
    ShapeRefactorBg.Brush.Color := LCardBg;
  end;

  if Assigned(CardTest) then
  begin
    CardTest.StyleElements := [seFont, seClient, seBorder];
    CardTest.ParentBackground := True;
    CardTest.BevelOuter := bvNone;
    CardTest.BevelInner := bvNone;
  end;
  if Assigned(ShapeTestBg) then
  begin
    ShapeTestBg.StyleElements := [seFont];
    ShapeTestBg.Pen.Color := LCardBorder;
    ShapeTestBg.Brush.Color := LCardBg;
  end;

  if Assigned(CardDocs) then
  begin
    CardDocs.StyleElements := [seFont, seClient, seBorder];
    CardDocs.ParentBackground := True;
    CardDocs.BevelOuter := bvNone;
    CardDocs.BevelInner := bvNone;
  end;
  if Assigned(ShapeDocsBg) then
  begin
    ShapeDocsBg.StyleElements := [seFont];
    ShapeDocsBg.Pen.Color := LCardBorder;
    ShapeDocsBg.Brush.Color := LCardBg;
  end;

  if Assigned(CardFind) then
  begin
    CardFind.StyleElements := [seFont, seClient, seBorder];
    CardFind.ParentBackground := True;
    CardFind.BevelOuter := bvNone;
    CardFind.BevelInner := bvNone;
  end;
  if Assigned(ShapeFindBg) then
  begin
    ShapeFindBg.StyleElements := [seFont];
    ShapeFindBg.Pen.Color := LCardBorder;
    ShapeFindBg.Brush.Color := LCardBg;
  end;

  if Assigned(CardOptimize) then
  begin
    CardOptimize.StyleElements := [seFont, seClient, seBorder];
    CardOptimize.ParentBackground := True;
    CardOptimize.BevelOuter := bvNone;
    CardOptimize.BevelInner := bvNone;
  end;
  if Assigned(ShapeOptimizeBg) then
  begin
    ShapeOptimizeBg.StyleElements := [seFont];
    ShapeOptimizeBg.Pen.Color := LCardBorder;
    ShapeOptimizeBg.Brush.Color := LCardBg;
  end;

  // Card labels - restore legibility in case ApplyTheme messed them up
  if Assigned(LabelExplainTitle) then LabelExplainTitle.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(LabelRefactorTitle) then LabelRefactorTitle.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(LabelTestTitle) then LabelTestTitle.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(LabelDocsTitle) then LabelDocsTitle.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(LabelFindTitle) then LabelFindTitle.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(LabelOptimizeTitle) then LabelOptimizeTitle.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);

  if Assigned(LabelExplainDesc) then LabelExplainDesc.Font.Color := LTextGray;
  if Assigned(LabelRefactorDesc) then LabelRefactorDesc.Font.Color := LTextGray;
  if Assigned(LabelTestDesc) then LabelTestDesc.Font.Color := LTextGray;
  if Assigned(LabelDocsDesc) then LabelDocsDesc.Font.Color := LTextGray;
  if Assigned(LabelFindDesc) then LabelFindDesc.Font.Color := LTextGray;
  if Assigned(LabelOptimizeDesc) then LabelOptimizeDesc.Font.Color := LTextGray;

  // Card TBitBtns - ensure correct icon colors under the theme
  if Assigned(BtnExplainIcon) then BtnExplainIcon.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(BtnRefactorIcon) then BtnRefactorIcon.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(BtnTestIcon) then BtnTestIcon.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(BtnDocsIcon) then BtnDocsIcon.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(BtnFindIcon) then BtnFindIcon.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(BtnOptimizeIcon) then BtnOptimizeIcon.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);

  // Input box and border
  if Assigned(FInputPanel) then
  begin
    FInputPanel.StyleElements := [seFont, seClient, seBorder];
    FInputPanel.ParentBackground := True;
    FInputPanel.BevelOuter := bvNone;
    FInputPanel.BevelInner := bvNone;
  end;
  if Assigned(ShapeInputBg) then
  begin
    ShapeInputBg.StyleElements := [seFont];
    ShapeInputBg.Pen.Color := LInputBorder;
    ShapeInputBg.Brush.Color := LInputBg;
  end;
  if Assigned(FInput) then
  begin
    FInput.Color := LInputBg;
    FInput.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  end;

  // Send button and other input icons
  if Assigned(FAttachIcon) then FAttachIcon.Font.Color := LTextGray;
  if Assigned(FShortcutLabel) then FShortcutLabel.Font.Color := LTextGray;
  if Assigned(FMicIcon) then FMicIcon.Font.Color := LTextGray;

  // Restore the header tab colors
  if Assigned(FLabelChatTab) then FLabelChatTab.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  if Assigned(FLabelAgentTab) then FLabelAgentTab.Font.Color := LTextGray;

  // Restore the output RichEdit colors
  if Assigned(FOutput) then
  begin
    FOutput.Color := Self.Color; // Use the form's default color under the IDE theme
    FOutput.Font.Color := ChooseColor(LIsDark, clWhite, clBlack);
  end;
end;
{$ELSE}

// No IDE theming service on this ToolsAPI (10 Seattle had no IDE themes), so
// there is no theme to read and nothing to mirror: the panel keeps the colours
// it was designed with. Guarding the whole body rather than each use keeps the
// themed version readable - it is the one that actually does something.
procedure TAefosChatPanel._ApplyTheme;
begin
end;

{$IFEND}

procedure TAefosChatPanel._OnFormShow(Sender: TObject);
var
  LDbgN: Integer;
  LDbgI: Integer;
begin
  // TEMP restore diagnostic: count live chat panels (>1 = double-instance).
  LDbgN := 0;
  for LDbgI := 0 to Screen.CustomFormCount - 1 do
    if Screen.CustomForms[LDbgI] is TAefosChatPanel then
      Inc(LDbgN);
  _DbgLog('[Aefos] _OnFormShow: instances=' + IntToStr(LDbgN) +
    ' FController=' + BoolToStr(Assigned(FController), True) +
    ' isGChatPanel=' + BoolToStr(Self = GChatPanel, True));
  // A desktop-RESTORED dock is created by the IDE directly (constructor only) and
  // never runs the composition-root wiring -> wire THIS instance now (wire-only,
  // never creates a second panel; idempotent). No-op for a normally-wired panel.
  if Assigned(GChatPanelWireHook) then
    GChatPanelWireHook(Self);
  // ...and it never ran the open path that first NAVIGATES the WebView, so its
  // content stays blank (clicking the menu's Open Chat is what fixed it). Navigate
  // is idempotent (FNavigated guard), so kick it on every show -> the restored
  // WebView loads the shell HTML. No-op once already navigated.
  if Assigned(FController) then
    FController.Navigate(_BuildPanelTheme);
  _ApplyTheme;
  // ESP-002 Demand 2/3 (AC-07): decide the empty-state on every open so the
  // checklist reflects the live config + filesystem, never a persisted flag.
  _EvaluateAndRenderOnboarding;
end;

procedure TAefosChatPanel._OnFormResize(Sender: TObject);
begin
  if Assigned(FWelcomePanelCenter) and Assigned(FWelcomePanel) then
  begin
    FWelcomePanelCenter.Left := (FWelcomePanel.Width - FWelcomePanelCenter.Width) div 2;
    FWelcomePanelCenter.Top := (FWelcomePanel.Height - FWelcomePanelCenter.Height) div 2;
  end;
end;

procedure TAefosChatPanel.CardMouseEnter(Sender: TObject);
var
  LPanel: TPanel;
  I: Integer;
begin
  if Sender is TPanel then
    LPanel := TPanel(Sender)
  else if Sender is TControl then
  begin
    if TControl(Sender).Parent is TPanel then
      LPanel := TPanel(TControl(Sender).Parent)
    else
      Exit;
  end
  else
    Exit;

  for I := 0 to LPanel.ControlCount - 1 do
    if LPanel.Controls[I] is TShape then
    begin
      TShape(LPanel.Controls[I]).Pen.Color := $00007AFF; // Premium Orange border
      TShape(LPanel.Controls[I]).Brush.Color := $002E2E2A; // Lighter hover background
    end;
end;

procedure TAefosChatPanel.CardMouseLeave(Sender: TObject);
var
  LPanel: TPanel;
  I: Integer;
  LIsDark: Boolean;
begin
  if Sender is TPanel then
    LPanel := TPanel(Sender)
  else if Sender is TControl then
  begin
    if TControl(Sender).Parent is TPanel then
      LPanel := TPanel(TControl(Sender).Parent)
    else
      Exit;
  end
  else
    Exit;

  LIsDark := True;
  if Self.Color <> clNone then
    LIsDark := ( (0.299 * GetRValue(ColorToRGB(Self.Color))) +
                 (0.587 * GetGValue(ColorToRGB(Self.Color))) +
                 (0.114 * GetBValue(ColorToRGB(Self.Color))) ) < 128;

  for I := 0 to LPanel.ControlCount - 1 do
    if LPanel.Controls[I] is TShape then
    begin
      if LIsDark then
      begin
        TShape(LPanel.Controls[I]).Pen.Color := $00302A2A; // Theme dark border
        TShape(LPanel.Controls[I]).Brush.Color := $00231F1F; // Theme dark bg
      end
      else
      begin
        TShape(LPanel.Controls[I]).Pen.Color := $00E2E2E2; // Theme light border
        TShape(LPanel.Controls[I]).Brush.Color := $00F7F7F7; // Theme light bg
      end;
    end;
end;



procedure TAefosChatPanel._OnExplainClick(Sender: TObject);
begin
  PrefillInput('/explain ');
end;

procedure TAefosChatPanel._OnRefactorClick(Sender: TObject);
begin
  PrefillInput('/refactor ');
end;

procedure TAefosChatPanel._OnTestClick(Sender: TObject);
begin
  PrefillInput('/test ');
end;

procedure TAefosChatPanel._OnDocsClick(Sender: TObject);
begin
  PrefillInput('/docs ');
end;

procedure TAefosChatPanel._OnFindClick(Sender: TObject);
begin
  PrefillInput('/find ');
end;

procedure TAefosChatPanel._OnOptimizeClick(Sender: TObject);
begin
  PrefillInput('/optimize ');
end;

function TAefosChatPanel.ShowPermission(const AToolName, ASummary,
  ADetail: string; const AResolve: TProc<TMCPConsentDecision>): Boolean;
begin
  // A consent is already on screen? Then this slot is NOT ours to take.
  //
  // This used to resolve the pending one as DENIED and call that "safe". It is
  // the opposite: the user is looking at that dialog, and its answer had already
  // been thrown away before they could click. Proven from the audit log --
  // RunProject/RunProject/SaveAllFiles denied in a 4-minute cluster, then every
  // tool applied normally once the requests stopped overlapping.
  //
  // Overlap is not exotic: the MCP pipe accepts PIPE_MAX_INSTANCES (4) clients,
  // each dispatching on its OWN worker thread, so a chat panel and an external
  // CLI session genuinely can ask at the same moment.
  //
  // Declining (False) sends this second request to the facade's VCL modal, which
  // owns its own blocking wait. Two dialogs is the honest outcome: two tools
  // asked, so two answers are owed. What must never happen is one of them being
  // answered by nobody.
  if Assigned(FPendingConsentResolve) then
    Exit(False);
  FPendingConsentResolve := AResolve;
  // Delegate to the controller; if the WebView2 isn't ready it returns False and
  // we report that up so the HTML presenter falls back to the VCL modal.
  if Assigned(FController)
    and FController.ShowPermission(AToolName, ASummary, ADetail) then
    Result := True
  else
  begin
    FPendingConsentResolve := nil; // not shown -> drop; caller uses VCL
    Result := False;
  end;
end;

procedure TAefosChatPanel.CancelPermission;
begin
  FPendingConsentResolve := nil;
  if Assigned(FController) then
    FController.HidePermission;
end;

function TAefosChatPanel._HwndInChat(AHwnd: HWND): Boolean;
var
  LHandle, LBrowser, LAnchor: HWND;
begin
  Result := False;
  if not Assigned(FController) then
    Exit;
  LBrowser := FController.BrowserHandle;
  // Composition mode: MoveFocus routes the Win32 focus to a hidden anchor window
  // (the controller's parent), which is NOT in the control's window tree. Treat it
  // (and its children) as "in chat" too — otherwise the focus check fails when the
  // composer holds the focus (Ctrl+V leaks; 'composer:focus' loops).
  LAnchor := FController.BrowserAnchorHandle;
  if (LBrowser = 0) and (LAnchor = 0) then
    Exit;
  // Walk the focused window up to the WebView host / its focus anchor — true only
  // when the keystroke belongs to the chat WebView2 (the IDE editor stays untouched).
  LHandle := AHwnd;
  while LHandle <> 0 do
  begin
    if ((LBrowser <> 0) and (LHandle = LBrowser)) or
       ((LAnchor <> 0) and (LHandle = LAnchor)) then
      Exit(True);
    LHandle := GetParent(LHandle);
  end;
end;

function TAefosChatPanel._FocusInChat: Boolean;
var
  LHandle: HWND;
begin
  // Walk the Win32 focus chain up to the panel handle: when docked or floating
  // the panel is an ancestor of both the WebView2's Chrome child windows and
  // every VCL child, so one walk covers all input surfaces.
  Result := False;
  if not HandleAllocated then
    Exit;
  LHandle := GetFocus;
  while LHandle <> 0 do
  begin
    if LHandle = Handle then
      Exit(True);
    LHandle := GetParent(LHandle);
  end;
end;

procedure TAefosChatPanel._RootShortCut(var Msg: TWMKey; var Handled: Boolean);
begin
  // Vcl.Edge's AcceleratorKeyPressed handler consults GetParentForm(browser) —
  // with TopForm=True, the ROOT of the parent chain: the IDE main/edit window
  // when the panel is docked, NOT this panel (so the IsShortCut override below
  // never sees the key docked). Worse, the consult EXECUTES a claiming action:
  // the IDE's Edit>Paste fired into the code editor while the caret blinked in
  // the chat composer. OnShortCut is the FIRST thing TCustomForm.IsShortCut
  // asks — before menu and action lists — so reserve the editing keys here and
  // perform the operation in the composer ourselves. GetAsyncKeyState
  // (physical state) instead of GetKeyState: this runs from a COM callback,
  // not from a message this thread read, so the thread-synchronized state can
  // be stale. BrowserFocused (GotFocus/LostFocus-driven) instead of GetFocus:
  // the focused window may belong to the browser process.
  if (not Handled) and Assigned(FController) and
     (FController.BrowserFocused or _FocusInChat) and
     TChatPanelHost.ShouldReserveEditingKeyForChat(Msg.CharCode,
       (GetAsyncKeyState(VK_CONTROL) and $8000) <> 0,
       (GetAsyncKeyState(VK_MENU) and $8000) <> 0,
       True) then
  begin
    case Msg.CharCode of
      Ord('V'):
        if Clipboard.HasFormat(CF_UNICODETEXT) or Clipboard.HasFormat(CF_TEXT) then
          FController.InsertTextAtCursor(Clipboard.AsText);
      Ord('C'):
        FController.ExecEditingCommand('copy');
      Ord('X'):
        FController.ExecEditingCommand('cut');
      Ord('A'):
        FController.ExecEditingCommand('selectAll');
      Ord('Z'):
        FController.ExecEditingCommand('undo');
    end;
    Handled := True;
    Exit;
  end;
  // Chain to the handler we replaced (IDE or another plugin) for everything else.
  if Assigned(FPrevRootShortCut) then
    FPrevRootShortCut(Msg, Handled);
end;

procedure TAefosChatPanel._HookRootShortCut;
var
  LRoot: TCustomForm;
begin
  LRoot := GetParentForm(Self);
  if LRoot = FHookedRoot then
    Exit;
  _UnhookRootShortCut;
  // Un-parented (or self-rooted) panel: the IsShortCut override already covers
  // the consults that reach this form directly.
  if (LRoot = nil) or (LRoot = Self) then
    Exit;
  FHookedRoot := LRoot;
  FHookedRoot.FreeNotification(Self);
  FPrevRootShortCut := TCustomFormAccess(FHookedRoot).OnShortCut;
  TCustomFormAccess(FHookedRoot).OnShortCut := _RootShortCut;
  // Mirror to unit scope for the finalization safety net.
  GHookedRoot := FHookedRoot;
  GPrevRootShortCut := FPrevRootShortCut;
end;

procedure TAefosChatPanel._UnhookRootShortCut;
begin
  if FHookedRoot = nil then
    Exit;
  // Restore only if the slot still points at us — another hooker may have
  // chained after; popping their handler would orphan it.
  if TMethod(TCustomFormAccess(FHookedRoot).OnShortCut).Data = Self then
    TCustomFormAccess(FHookedRoot).OnShortCut := FPrevRootShortCut;
  FHookedRoot.RemoveFreeNotification(Self);
  FHookedRoot := nil;
  FPrevRootShortCut := nil;
  // Keep the finalization mirror in sync (the hook is no longer installed).
  GHookedRoot := nil;
end;

procedure TAefosChatPanel.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FHookedRoot) then
  begin
    FHookedRoot := nil;
    FPrevRootShortCut := nil;
  end;
end;

function TAefosChatPanel.IsShortCut(var AMessage: TWMKey): Boolean;
begin
  // Vcl.Edge routes every WebView2 accelerator through
  // GetParentForm(browser).IsShortCut and BLOCKS the browser's native handling
  // whenever it returns True (AcceleratorKeyPressed -> Args.Set_Handled). When
  // the panel is DOCKED, the inherited TDockableForm pass reaches the IDE's
  // global Edit actions, claims Ctrl+V/C/X/A/Z, and the composer's paste dies;
  // floating, the pass finds no action and the keys work — which is why the
  // bug only showed docked. The _AppMessage hook can't help here: the
  // keystroke lives in the browser process and never enters the IDE's message
  // queue. When the keystroke targets the chat, answer "not a shortcut"
  // WITHOUT consulting the IDE so the browser (or a focused VCL child)
  // handles the key natively (Terminal OP1 pattern, ESP-026/ESP-080; routing
  // decision in the pure ShouldReserveEditingKeyForChat predicate).
  if TChatPanelHost.ShouldReserveEditingKeyForChat(AMessage.CharCode,
       GetKeyState(VK_CONTROL) < 0, GetKeyState(VK_MENU) < 0, _FocusInChat) then
    Exit(False);
  Result := inherited IsShortCut(AMessage);
end;

procedure TAefosChatPanel._AppMessage(var Msg: TMsg; var Handled: Boolean);
begin
  // The IDE's Edit accelerators (Ctrl+V/A/C/X/Z = Paste/Select All/Copy/Cut/Undo)
  // fire before the WebView2 sees the key, killing those shortcuts in the chat
  // input. Application.OnMessage runs BEFORE that accelerator processing, so we
  // intercept the editing keys aimed at the chat browser and stop the IDE from
  // stealing them.
  if (not Handled) and (Msg.message = WM_KEYDOWN) and Assigned(FController) and
     ((GetKeyState(VK_CONTROL) and $8000) <> 0) and
     ((GetKeyState(VK_MENU) and $8000) = 0) and _HwndInChat(Msg.hwnd) then
  begin
    case Msg.wParam of
      Ord('V'):
        // Paste: the IDE never forwards the key, so inject the clipboard via JS
        // (the WebView2 keyboard-paste path is blocked by the IDE accelerator).
        if Clipboard.HasFormat(CF_UNICODETEXT) or Clipboard.HasFormat(CF_TEXT) then
        begin
          FController.InsertTextAtCursor(Clipboard.AsText);
          Handled := True;
        end;
      Ord('A'), Ord('C'), Ord('X'), Ord('Z'):
        begin
          // Select All / Copy / Cut / Undo: let the WebView2 handle them natively
          // (standard textarea behaviour). Dispatch the keystroke to its target
          // window ourselves, then mark it handled so the IDE accelerator that
          // would otherwise swallow it never runs.
          TranslateMessage(Msg);
          DispatchMessage(Msg);
          Handled := True;
        end;
    end;
  end;
  // Chain to the handler we replaced so the IDE's message processing keeps
  // working for everything we don't handle.
  if (not Handled) and Assigned(GPrevAppOnMessage) then
    GPrevAppOnMessage(Msg, Handled);
end;

procedure TAefosChatPanel._OnHostMessage(const AMessage: string);
var
  LAction: string;
  LText: string;
  LKind: string;
  LWasRunning: Boolean;
  LResolve: TProc<TMCPConsentDecision>;
begin
  // Bridge from the WebView2 (main thread, TEdgeBrowser event). The HTML composer
  // posts 'send:<text>' when the user presses Enter / Send; the empty-state chips
  // post 'action:<name>'. _DispatchCommand echoes the user bubble and dispatches.
  if AMessage.StartsWith('send:') then
  begin
    _DispatchCommand(Copy(AMessage, Length('send:') + 1, MaxInt));
    Exit;
  end;
  // A link the user clicked in a message. The page cancelled the navigation and
  // sent us the href, because this WebView is the conversation itself - see the
  // click handler in OutputPanel.Assets for what happens when it navigates.
  if AMessage.StartsWith('openlink:') then
  begin
    _OpenLink(Trim(Copy(AMessage, Length('openlink:') + 1, MaxInt)));
    Exit;
  end;
  // The shell page reports a broken JS runtime (e.g. window.marked missing
  // because the shell file loaded truncated). Reload the shell once — Navigate
  // rewrites the file and the nav-completed replay rebuilds the conversation,
  // recovering the responses the broken page swallowed. Without this the chat
  // looked dead (empty assistant bubbles, footer stuck on "ready") until the
  // panel was recreated by hand.
  if AMessage.StartsWith('shell-error:') then
  begin
    OutputDebugString(PChar('[Aefos] chat ' + AMessage));
    if Assigned(FController) then
      FController.ReloadShellOnce(_BuildPanelTheme);
    Exit;
  end;
  // Composer Stop button (posted while a run is in flight): cancel it. The JS
  // already flips the button back to Send optimistically; the executor's Cancel
  // terminates the CLI process and the normal completion path settles the UI.
  // GUARDIAN (like busycheck): the JS dsStop() only restores the Send button —
  // it leaves the "Thinking..." typing indicator + "Aefos — working..." footer
  // pulsing. When a run IS really in flight the executor's completion posts the
  // settling footer. But when the page is in a PHANTOM busy (a prior turn that
  // lost its completion footer, then the working state re-surfaced on a re-dock/
  // focus), FOnStop cancels nothing and no footer is ever posted, so the page
  // pulses forever (reported live 2026-07-11 after changing the provider). So if
  // no run was really active, settle the UI to idle right here.
  if AMessage = 'stop:' then
  begin
    LWasRunning := Assigned(FOnIsRunning) and FOnIsRunning();
    if Assigned(FOnStop) then
      FOnStop();
    if (not LWasRunning) and Assigned(FController) then
      FController.EnqueueFooter('ready.', False);
    Exit;
  end;
  // Stale-busy probe: the composer blocked a send because the page still thinks
  // a run is in flight (_dsBusy). The HOST is the truth — when no run is really
  // active the completion footer was lost, so re-post the idle footer
  // (dsFooter releases _dsBusy and restores the Send button); the user's text
  // is still in the composer and the next Enter goes through. When a run IS
  // active this is a no-op: the block was correct.
  if AMessage = 'busycheck:' then
  begin
    if (not (Assigned(FOnIsRunning) and FOnIsRunning())) and
       Assigned(FController) then
      FController.EnqueueFooter('ready.', False);
    Exit;
  end;
  // HTML header (#ds-header) actions. Mirror the legacy VCL header affordances.
  // newsession: same effect as /new (clear conversation + drop CLI session).
  if AMessage = 'hdr:newsession' then
  begin
    // Persist the current conversation BEFORE clearing so it stays in history.
    _SaveCurrentSession;
    _ClearQueuedMessages;
    if Assigned(FController) then
      FController.ResetConversation;
    _ResetSessionInfo;
    if Assigned(FOnNewSession) then
      FOnNewSession();
    Exit;
  end;
  // settings (gear): reuse the existing open-options hook (OnOpenSettings),
  // already wired by the composition root to OpenAefosOptions — the same
  // callback the VCL FSettingsBtn used. No separate OnSettings callback needed.
  if AMessage = 'hdr:settings' then
  begin
    if Assigned(FOnOpenSettings) then
      FOnOpenSettings();
    Exit;
  end;
  // sessions (clock): open the HTML sessions panel (records the live session,
  // lists the on-disk index, marks the CURRENT row). Resume comes back as
  // 'session:resume:<id>' (handled below).
  if AMessage = 'hdr:sessions' then
  begin
    _OpenSessionsPanel;
    Exit;
  end;
  // Resume a stored session (row click in the sessions panel): replay it on the
  // page + arm the executor to --resume its id on the next dispatch.
  if AMessage.StartsWith('session:resume:') then
  begin
    _ResumeSession(Copy(AMessage, Length('session:resume:') + 1, MaxInt));
    Exit;
  end;
  // Delete a stored session (trash icon in the sessions panel): drop it from the
  // store and refresh the open panel so the row disappears.
  if AMessage.StartsWith('session:delete:') then
  begin
    _DeleteSessionFromPanel(Copy(AMessage, Length('session:delete:') + 1, MaxInt));
    Exit;
  end;
  // mode toggle (Chat|Agent): the page sends 'hdr:mode:agent' / 'hdr:mode:chat'
  // on click. Forward the boolean to the executor (Agent = IDE/MCP tools on, the
  // model acts; Chat = conversation only). The visual highlight is handled in the
  // page; here we only flip the dispatch behavior.
  if AMessage.StartsWith('hdr:mode:') then
  begin
    if Assigned(FOnSetAgentMode) then
      FOnSetAgentMode(AMessage = 'hdr:mode:agent');
    // Switching Chat<->Agent must start a FRESH session: the mode frames the
    // whole conversation, so without a reset the model keeps acting in the prior
    // mode (e.g. still "in Chat mode" after clicking Agent) and the old messages
    // bleed across. Only on an ACTUAL change so the page's on-load mode echo
    // never wipes anything. Mirrors the hdr:newsession sequence above.
    if (AMessage = 'hdr:mode:agent') <> FAgentMode then
    begin
      FAgentMode := (AMessage = 'hdr:mode:agent');
      _SaveCurrentSession;
      _ClearQueuedMessages;
      if Assigned(FController) then
        FController.ResetConversation;
      _ResetSessionInfo;
      if Assigned(FOnNewSession) then
        FOnNewSession();
    end;
    Exit;
  end;
  // Header model selector: the page requests the list on load ('hdr:models'),
  // and posts 'hdr:model:<id>' when one is picked.
  if AMessage = 'hdr:models' then
  begin
    if Assigned(FOnGetModels) and Assigned(FController) then
      FController.SetModelsJson(FOnGetModels());
    Exit;
  end;
  if AMessage.StartsWith('hdr:model:') then
  begin
    if Assigned(FOnSetModel) then
      FOnSetModel(Copy(AMessage, Length('hdr:model:') + 1, MaxInt));
    Exit;
  end;
  // Header reasoning-effort selector: the page posts 'hdr:effort:<token>' when a
  // level is picked ('default' clears it back to the executor's own effort).
  if AMessage.StartsWith('hdr:effort:') then
  begin
    if Assigned(FOnSetEffort) then
      FOnSetEffort(Copy(AMessage, Length('hdr:effort:') + 1, MaxInt));
    Exit;
  end;
  // Permission modal decision (ADR-216): 'perm:once' / 'perm:session' /
  // 'perm:deny'. Resolve the pending consent EXACTLY ONCE and clear it; any
  // value other than once/session is treated as deny (safe default).
  if AMessage.StartsWith('perm:') then
  begin
    if Assigned(FPendingConsentResolve) then
    begin
      LResolve := FPendingConsentResolve;
      FPendingConsentResolve := nil;
      LKind := Copy(AMessage, Length('perm:') + 1, MaxInt);
      if SameText(LKind, 'once') then
        LResolve(cdAllowOnce)
      else if SameText(LKind, 'session') then
        LResolve(cdAllowSession)
      else
        LResolve(cdDenied);
    end;
    Exit;
  end;
  // Memory modal (🧠 click): load the global memory and open the modal prefilled.
  if AMessage = 'memory:open' then
  begin
    LText := '';
    if Assigned(FOnMemoryLoad) then
      LText := FOnMemoryLoad();
    if Assigned(FController) then
      FController.ShowMemory(LText);
    Exit;
  end;
  // Memory modal (Save): persist the edited text via the composition-root hook.
  if AMessage.StartsWith('memory:save:') then
  begin
    LText := Copy(AMessage, Length('memory:save:') + 1, MaxInt);
    if Assigned(FOnMemorySave) then
      FOnMemorySave(LText);
    Exit;
  end;
  // Docked-focus fix: the HTML composer was focused (caret shows) but, docked,
  // the WebView2 host may not hold the Win32 keyboard focus (the IDE code editor
  // keeps it), so Ctrl+V/typing leak to the editor. Grab it via TEdgeBrowser's
  // MoveFocus (FocusComposer) — but ONLY when we don't already hold it (GetFocus
  // not in the chat), so there is no focus loop and the on-load focus is left be.
  if AMessage = 'composer:focus' then
  begin
    if Assigned(FController) and not _HwndInChat(GetFocus) then
      FController.FocusComposer;
    Exit;
  end;
  // MCP Servers modal (🔌 click): load the saved mcp-config and open the modal.
  if AMessage = 'mcp:open' then
  begin
    _OpenMcpModal;
    Exit;
  end;
  // MCP Servers modal (Save): persist the edited mcp-config JSON.
  if AMessage.StartsWith('mcp:save:') then
  begin
    LText := Copy(AMessage, Length('mcp:save:') + 1, MaxInt);
    if Assigned(FOnMcpSave) then
      FOnMcpSave(LText);
    Exit;
  end;
  // New Project wizard: Browse opens a native folder picker; Create materialises
  // the chosen template (+ opens it) and reports the outcome back to the modal.
  if AMessage = 'newproj:browse' then
  begin
    _BrowseProjectFolder;
    Exit;
  end;
  if AMessage.StartsWith('newproj:create:') then
  begin
    LText := Copy(AMessage, Length('newproj:create:') + 1, MaxInt);
    if Assigned(FOnCreateProject) and Assigned(FController) then
      FController.NewProjResult(FOnCreateProject(LText));
    Exit;
  end;
  // Attach (paperclip): open a file picker; the chosen path is inserted into the
  // composer so the agent (running in the project dir) reads it via its tools.
  if AMessage = 'attach:open' then
  begin
    _OpenAttachDialog;
    Exit;
  end;
  // Pasted image: base64 PNG from the clipboard; save to a temp file and insert
  // its path (the CLI's Read tool can see images).
  if AMessage.StartsWith('paste:image:') then
  begin
    _SavePastedImage(Copy(AMessage, Length('paste:image:') + 1, MaxInt));
    Exit;
  end;
  // Command (command) editor modal bridge (ADR-250). list/load feed the modal;
  // save/delete go through the SAME registry the VCL editor uses (one writer).
  if AMessage = 'command:list' then
  begin
    _SendCommandList;
    Exit;
  end;
  if AMessage.StartsWith('command:load:') then
  begin
    _LoadCommandIntoEditor(Copy(AMessage, Length('command:load:') + 1, MaxInt));
    Exit;
  end;
  if AMessage.StartsWith('command:save:') then
  begin
    _SaveCommandFromJson(Copy(AMessage, Length('command:save:') + 1, MaxInt));
    Exit;
  end;
  if AMessage.StartsWith('command:delete:') then
  begin
    _DeleteCommand(Copy(AMessage, Length('command:delete:') + 1, MaxInt));
    Exit;
  end;
  if AMessage = 'cmd:picker' then
  begin
    // Feed the slash-picker: static built-ins + registered commands.
    _SendPickerCommands;
    Exit;
  end;
  if not AMessage.StartsWith('action:') then
    Exit;
  LAction := Copy(AMessage, Length('action:') + 1, MaxInt);
  if SameText(LAction, 'explain') then
    PrefillInput('/explain ')
  else if SameText(LAction, 'refactor') then
    PrefillInput('/refactor ')
  else if SameText(LAction, 'test') then
    PrefillInput('/test ')
  else if SameText(LAction, 'docs') then
    PrefillInput('/docs ')
  else if SameText(LAction, 'find') then
    PrefillInput('/find ')
  else if SameText(LAction, 'optimize') then
    PrefillInput('/optimize ');
end;

procedure TAefosChatPanel._ScrollToBottom;
begin
  if Assigned(FOutput) and FOutput.HandleAllocated then
    SendMessage(FOutput.Handle, WM_VSCROLL, SB_BOTTOM, 0);
end;

function TAefosChatPanel._UseBrowser: Boolean;
begin
  Result := Assigned(FController) and not FController.WebViewFailed;
end;

procedure TAefosChatPanel._EnsureOutputVisible;
var
  LController: TOutputPanelEdgeController;
  LTheme: TPanelTheme;
begin
  // Must be called on the main thread (inside _RunOnMainThread).
  // Transitions from the welcome panel to the browser output area on the
  // first output call. Also ensures navigation has started (idempotent).
  if not FController.Browser.Visible then
  begin
    // Show the browser BEFORE Navigate so TEdgeBrowser receives a window
    // handle and the WebView2 environment can initialise. Calling
    // NavigateToString on an invisible (handle-less) control causes
    // OnCreateWebViewCompleted to never fire, keeping FReady=False.
    FController.Browser.Visible := True;
    if Assigned(FWelcomePanel) then
      FWelcomePanel.Visible := False;
    // Defer Navigate to the NEXT message-loop turn: setting Visible:=True only
    // posts the window-handle creation; the handle is not fully established
    // until the loop processes it, and navigating synchronously here races that
    // and can leave WebView2 init stuck (OnCreateWebViewCompleted never firing).
    // Proven in tools/ChatTester (TChatView._EnsureOutputVisible, radIA pattern).
    // Navigate's FNavigated guard keeps the deferred call idempotent. Only the
    // controller is captured (not Self), and this fires on the very next turn
    // while output is actively flowing, so the panel cannot be freed in between.
    LController := FController;
    LTheme := _BuildPanelTheme;
    TAefosMainThread.ForceQueue(procedure
      begin
        LController.Navigate(LTheme);
      end);
  end;
end;

function TAefosChatPanel._IsBrowserReady: Boolean;
begin
  Result := Assigned(FController) and FController.IsBrowserReady;
end;

function TAefosChatPanel._IsQueueReady: Boolean;
begin
  Result := Assigned(FController) and FController.IsQueueReady;
end;

function TAefosChatPanel._BeginEvalScript(const AScript: string;
  const AOnDone: TInspectorEvalProc): Boolean;
begin
  Result := Assigned(FController) and
    FController.BeginEvalScript(AScript, AOnDone);
end;

// Opens the native New Project wizard, fed with the template library JSON.
procedure TAefosChatPanel._OpenNewProjectWizard;
var
  LJson: string;
begin
  if not Assigned(FController) then
    Exit;
  LJson := '';
  if Assigned(FOnListTemplates) then
    LJson := FOnListTemplates();
  FController.ShowNewProject(LJson);
end;

// Native folder picker for the wizard's "where to save" field.
procedure TAefosChatPanel._BrowseProjectFolder;
var
  LDlg: TFileOpenDialog;
begin
  if not Assigned(FController) then
    Exit;
  LDlg := TFileOpenDialog.Create(nil);
  try
    LDlg.Options := [fdoPickFolders, fdoPathMustExist];
    LDlg.Title := 'Select the folder to create the project in';
    if LDlg.Execute then
      FController.NewProjBrowse(LDlg.FileName);
  finally
    LDlg.Free;
  end;
end;

procedure TAefosChatPanel._OpenLink(const AHref: string);
var
  LHref, LPath, LRoot: string;
  LModule: IOTAModuleServices;

  // Says it in the chat, where the click happened. A link that does nothing and
  // explains nothing is the same silence that made the navigation bug hard to
  // read in the first place.
  procedure _Notify(const AText: string);
  begin
    if Assigned(FController) then
      FController.EnqueueFooter(AText, True);
  end;

begin
  LHref := Trim(AHref);
  if LHref = '' then
    Exit;
  // A real URL: hand it to the system, which is the only thing that should own
  // a browser window. Never this panel.
  if LHref.StartsWith('http://', True) or LHref.StartsWith('https://', True) or
     LHref.StartsWith('mailto:', True) then
  begin
    ShellExecute(0, 'open', PChar(LHref), nil, nil, SW_SHOWNORMAL);
    Exit;
  end;
  // Everything else is meant as a FILE. The agent writes project-relative paths
  // (`.project/analysis/project-overview.md`) because that is how it refers to
  // what it just wrote; a browser reads the same string as a URL and mangles the
  // backslashes. Resolve it the way the sentence meant it.
  LPath := LHref;
  if LPath.StartsWith('file:///', True) then
    LPath := Copy(LPath, Length('file:///') + 1, MaxInt);
  LPath := StringReplace(LPath, '/', PathDelim, [rfReplaceAll]);
  LPath := StringReplace(LPath, '%5C', PathDelim, [rfReplaceAll, rfIgnoreCase]);
  LPath := StringReplace(LPath, '%20', ' ', [rfReplaceAll]);
  LModule := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModule) then
    LModule := nil;
  if not TPath.IsPathRooted(LPath) then
  begin
    // Relative means relative to the PROJECT: that is what the agent meant when
    // it wrote the path, because that is the directory it ran in.
    LRoot := '';
    if Assigned(LModule) and Assigned(LModule.GetActiveProject) then
      LRoot := TPath.GetDirectoryName(LModule.GetActiveProject.FileName);
    if LRoot = '' then
    begin
      _Notify('Cannot open "' + LHref +
        '": it is a relative path and no project is open to resolve it against.');
      Exit;
    end;
    LPath := TPath.Combine(LRoot, LPath);
  end;
  if not TFile.Exists(LPath) then
  begin
    // Name the path that was tried. "File not found" on its own is the message
    // that sends someone hunting through three folders.
    _Notify('File not found: ' + LPath);
    Exit;
  end;
  // The IDE editor, not a browser: it is a file of the project the developer has
  // open, and the editor is where they can actually do something with it.
  if Assigned(LModule) then
    LModule.OpenModule(LPath)
  else
    ShellExecute(0, 'open', PChar(LPath), nil, nil, SW_SHOWNORMAL);
end;

procedure TAefosChatPanel._DispatchCommand(const AText: string;
  const AFromQueue: Boolean);
var
  LCmd: string;
  LText: string;
  LBuiltin: TBuiltInCommand;
  LBuiltinArgs: string;
  LIsBuiltin: Boolean;
begin
  // The leading '/' is optional in the chat input; strip it centrally
  // (Core.ChatCommand) so dispatch sees a bare command/command name.
  LCmd := StripLeadingSlash(AText);
  if (LCmd = '') or not Assigned(FOnCommand) then
    Exit;
  // Send-during-run: the composer posts sends even while a run is in flight
  // (the HOST is the gate). A message arriving mid-run is echoed at once and
  // queued; ReportComplete/ReportError drain it as its own turn (--resume keeps
  // the context). EVERYTHING queues — slash commands included — so nothing
  // mutates chat state under a streaming turn. AFromQueue bypasses the gate
  // (the drain's own dispatch) and skips the duplicate echo below.
  if (not AFromQueue) and Assigned(FOnIsRunning) and FOnIsRunning() then
  begin
    if _UseBrowser then
    begin
      _EnsureOutputVisible;
      FController.EnqueueUser(AText);
      FController.EnqueueQueuedNotice(FQueuedMessages.Count + 1);
    end;
    FQueuedMessages.Add(AText);
    Exit;
  end;
  // /new | /reset (| /nova): clear the conversation (display + Pascal history),
  // re-show the empty-state, and drop the CLI session via OnNewSession — never
  // echoed nor dispatched to the executor.
  if SameText(LCmd, 'new') or SameText(LCmd, 'reset') or SameText(LCmd, 'nova') then
  begin
    // Persist the current conversation BEFORE clearing so it stays in history.
    _SaveCurrentSession;
    _ClearQueuedMessages;
    if Assigned(FController) then
      FController.ResetConversation;
    _ResetSessionInfo;
    if Assigned(FOnNewSession) then
      FOnNewSession();
    Exit;
  end;
  // /memory: open the memory modal prefilled with the current global memory —
  // never echoed nor dispatched to the executor.
  if SameText(LCmd, 'memory') then
  begin
    LText := '';
    if Assigned(FOnMemoryLoad) then
      LText := FOnMemoryLoad();
    if Assigned(FController) then
      FController.ShowMemory(LText);
    Exit;
  end;
  if SameText(LCmd, 'command') or SameText(LCmd, 'prompt') then
  begin
    // /command (alias: /prompt): open the HTML command editor modal
    // (ADR-250) to create a custom command — a named slash-command backed by a
    // prompt template.
    _OpenCommandEditorNew;
    Exit;
  end;
  // /mcp: open the MCP Servers modal prefilled with the saved config — never
  // echoed nor dispatched to the executor.
  if SameText(LCmd, 'mcp') then
  begin
    _OpenMcpModal;
    Exit;
  end;
  // /install: open the addon store - the catalogue of every configured store,
  // with an Install button. Never echoed nor dispatched to the executor: it is
  // a window, not a prompt. /addons and /store answer too, because both are
  // what someone would try.
  if SameText(LCmd, 'install') or SameText(LCmd, 'addons') or
     SameText(LCmd, 'store') then
  begin
    TAefosAddonStoreForm.Execute;
    Exit;
  end;
  // /inspector: open the MCP Tool Inspector window (subscription/dev tool) -
  // never echoed nor dispatched to the executor.
  if SameText(LCmd, 'inspector') then
  begin
    if Assigned(FOnOpenInspector) then
      FOnOpenInspector();
    Exit;
  end;
  // /new-project (bare): open the native New Project wizard. WITH arguments
  // (/new-project a REST server called Foo) it falls through to the agentic
  // command, which drives the flow in chat instead.
  if SameText(LCmd, 'new-project') then
  begin
    _OpenNewProjectWizard;
    Exit;
  end;
  // Echo the raw submitted text as a user bubble (browser path only; ADR-245).
  // _EnsureOutputVisible triggers Navigate before EnqueueUser so the HTML
  // shell is loading while the bubble is queued — the queue drains only after
  // NavigationCompleted, guaranteeing addUserMessage() exists on the page.
  // A drained message was already echoed when it entered the queue.
  if (not AFromQueue) and _UseBrowser then
  begin
    _EnsureOutputVisible;
    FController.EnqueueUser(AText);
  end;
  // Feed the HTML session bar (#ds-ctx): the first user message becomes the
  // session title; every dispatch bumps the message count. Minimal + safe — no
  // time string (kept blank), since there is no existing source for it.
  Inc(FSessionCount);
  if FSessionTitle = '' then
    FSessionTitle := Trim(AText);
  _PushSessionInfo;
  // A built-in agentic command that ForcesAgent (e.g. /new-project) needs the
  // IDE tools — switch to Agent (functional + visual) before dispatch so the
  // tool calls are not refused in Chat mode. Registry-driven, no name hardcoded.
  LIsBuiltin := FindBuiltInCommand(LCmd, LBuiltin, LBuiltinArgs);
  if LIsBuiltin and LBuiltin.ForcesAgent then
  begin
    if Assigned(FOnSetAgentMode) then
      FOnSetAgentMode(True);
    if Assigned(FController) then
      FController.SetAgentToggle(True);
  end;
  // Recents (ADR-049/050/053): record this dispatch in the palette so the inline
  // '/' picker surfaces it first next time. Only KNOWN commands are recorded - a
  // builtin matched just above, or a stored command resolved by an exact name hit
  // - so a free-text prompt (LCmd = the whole prompt) never pollutes recents.
  _RecordRecent(LCmd, LIsBuiltin, LBuiltin);
  // Dispatch the text AS TYPED, slash and all. The executor needs that slash to
  // tell "/release these notes" (the command, plus what the developer wants)
  // from "release these notes" (a sentence that happens to start with the name
  // of an installed command). Stripping it here left both looking identical,
  // and the only safe reading of an identical pair is the literal one - which
  // is why a command with anything after it used to reach the model as raw
  // text, with its COMMAND.md never loaded.
  FOnCommand(AText);
end;

procedure TAefosChatPanel._DrainQueuedMessage;
var
  LText: string;
begin
  // Dispatch the NEXT queued send-during-run message as its own turn. Called
  // from ReportComplete/ReportError (main thread) — i.e. whenever a turn
  // settles, including after Stop (cancel drives the completion path), which
  // is the chosen semantic: Stop kills the current turn only, the queue lives.
  if (not Assigned(FQueuedMessages)) or (FQueuedMessages.Count = 0) then
    Exit;
  LText := FQueuedMessages[0];
  FQueuedMessages.Delete(0);
  if _UseBrowser then
    FController.EnqueueQueuedNotice(FQueuedMessages.Count);
  _DispatchCommand(LText, True);
  // A drained builtin that only opens a modal (/memory, /mcp, ...) starts no
  // CLI turn, so no completion would ever drain the messages behind it — keep
  // draining while nothing is running. Bounded by the queue length.
  if (FQueuedMessages.Count > 0) and
     (not (Assigned(FOnIsRunning) and FOnIsRunning())) then
    _DrainQueuedMessage;
end;

procedure TAefosChatPanel._ClearQueuedMessages;
begin
  // A conversation reset orphans the send-during-run queue: the queued texts
  // belonged to the conversation being dropped, and auto-firing them into a
  // fresh/blank session would be surprising. Drop them + hide the counter.
  if Assigned(FQueuedMessages) and (FQueuedMessages.Count > 0) then
  begin
    FQueuedMessages.Clear;
    if _UseBrowser then
      FController.EnqueueQueuedNotice(0);
  end;
end;

procedure TAefosChatPanel._RecordRecent(const ACmd: string;
  const AIsBuiltin: Boolean; const ABuiltin: TBuiltInCommand);
var
  LEntry: TCommandEntry;
  LMatches: TArray<TCommandEntry>;
  LMatch: TCommandEntry;
  LFound: Boolean;
begin
  if not Assigned(FPalette) then
    Exit;
  LEntry := Default(TCommandEntry);
  LFound := False;
  if AIsBuiltin then
  begin
    // Agentic/builtin command (e.g. /new-project with args) - build the entry
    // straight from the builtin table, the same shape the picker shows.
    LEntry.Name := ABuiltin.Name;
    LEntry.Description := ABuiltin.Description;
    LEntry.CommandName := ABuiltin.Name;
    LEntry.Kind := ckCommand;
    LFound := True;
  end
  else
  begin
    // Stored command - accept ONLY an exact name/command hit so a free-text
    // prompt (which never names a command) is not recorded as a recent.
    LMatches := FPalette.Search(ACmd);
    for LMatch in LMatches do
      if SameText(LMatch.Name, ACmd) or SameText(LMatch.CommandName, ACmd) then
      begin
        LEntry := LMatch;
        LFound := True;
        Break;
      end;
  end;
  if LFound then
    FPalette.AddRecent(LEntry);
end;

procedure TAefosChatPanel._OnSendClick(Sender: TObject);
var
  LText: string;
begin
  LText := Trim(FInput.Lines.Text);
  if LText = '' then
    Exit;
  FInput.Lines.Clear;
  _DispatchCommand(LText);
end;

procedure TAefosChatPanel._OnInputKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  // While the '/' list is open it owns Up/Down/Enter/Esc — intercept them
  // before the memo consumes the keystroke (R-3).
  if _CommandListVisible and _HandleListKey(Key) then
    Exit;
  if (Key = VK_RETURN) and not (ssShift in Shift) then
  begin
    _OnSendClick(Sender);
    Key := 0;
  end;
end;

procedure TAefosChatPanel._OnInputChange(Sender: TObject);
var
  LQuery: string;
begin
  // BR-2: open the list only when '/' is the first non-whitespace char.
  if IsSlashTrigger(FInput.Text, LQuery) then
    _FilterCommandList(LQuery)
  else
    _HideCommandList;
end;

procedure TAefosChatPanel._OnCmdListDblClick(Sender: TObject);
begin
  _AcceptListSelection;
end;

function TAefosChatPanel._CommandListVisible: Boolean;
begin
  Result := Assigned(FCmdList) and FCmdList.Visible;
end;

function TAefosChatPanel._HandleListKey(var AKey: Word): Boolean;
begin
  Result := True;
  case AKey of
    VK_DOWN:   _MoveCommandSelection(1);
    VK_UP:     _MoveCommandSelection(-1);
    VK_RETURN: _AcceptListSelection;
    VK_ESCAPE: _HideCommandList;
  else
    Result := False;
  end;
  if Result then
    AKey := 0;
end;

procedure TAefosChatPanel._FilterCommandList(const AQuery: string);
var
  LEntries: TArray<TCommandEntry>;
  LEntry: TCommandEntry;
  LBuiltin: TBuiltInCommand;
  LQ: string;
  LIdx: Integer;
begin
  // BR-1: the inline list reads the same registry as the modal palette.
  if not Assigned(FPalette) then
  begin
    _HideCommandList;
    Exit;
  end;
  LEntries := FPalette.ListForInline(AQuery);
  // Built-in agentic commands (Core.BuiltInCommands, e.g. /new-project) are not
  // stored commands, so the palette can't know them — surface the matching ones
  // in the picker, prepended (most discoverable). Registry-driven.
  LQ := LowerCase(Trim(AQuery));
  for LBuiltin in BuiltInCommands do
    if (LQ = '') or (Pos(LQ, LowerCase(LBuiltin.Name)) > 0) or
       (Pos(LQ, LowerCase(LBuiltin.Description)) > 0) then
    begin
      LEntry := Default(TCommandEntry);
      LEntry.Name := LBuiltin.Name;
      LEntry.Description := LBuiltin.Description;
      LEntry.CommandName := LBuiltin.Name;
      LEntry.Kind := ckCommand;
      SetLength(LEntries, Length(LEntries) + 1);
      for LIdx := High(LEntries) downto 1 do
        LEntries[LIdx] := LEntries[LIdx - 1];
      LEntries[0] := LEntry;
    end;
  _PopulateCommandList(LEntries);
  if Length(LEntries) = 0 then
    _HideCommandList
  else
    _ShowCommandList;
end;

procedure TAefosChatPanel._RefreshCommandListIfOpen;
var
  LQuery: string;
begin
  if not _CommandListVisible then
    Exit;
  if IsSlashTrigger(FInput.Text, LQuery) then
    _FilterCommandList(LQuery);
end;

procedure TAefosChatPanel._PopulateCommandList(
  const AEntries: TArray<TCommandEntry>);
var
  LFor: Integer;
begin
  FCmdEntries := AEntries;
  FCmdList.Items.BeginUpdate;
  try
    FCmdList.Items.Clear;
    for LFor := 0 to High(AEntries) do
      FCmdList.Items.Add('/' + AEntries[LFor].Name + ' '#8212' ' +
        AEntries[LFor].Description);
  finally
    FCmdList.Items.EndUpdate;
  end;
  if FCmdList.Items.Count > 0 then
    FCmdList.ItemIndex := 0;
end;

procedure TAefosChatPanel._ShowCommandList;
var
  LRows: Integer;
  LHeight: Integer;
  LTop: Integer;
begin
  LRows := FCmdList.Items.Count;
  if LRows > CMDLIST_MAX_ROWS then
    LRows := CMDLIST_MAX_ROWS;
  LHeight := LRows * CMDLIST_ROW_HEIGHT + 4;
  LTop := FInputPanel.Top - LHeight;
  if LTop < 0 then
    LTop := 0;
  FCmdList.SetBounds(0, LTop, ClientWidth, LHeight);
  // AC-12: theme the dynamically shown popup to match the host panel.
  _ApplyThemeTo(FCmdList);
  FCmdList.Visible := True;
  FCmdList.BringToFront;
end;

procedure TAefosChatPanel._HideCommandList;
begin
  if Assigned(FCmdList) then
    FCmdList.Visible := False;
end;

procedure TAefosChatPanel._MoveCommandSelection(const ADelta: Integer);
var
  LIndex: Integer;
  LCount: Integer;
begin
  LCount := FCmdList.Items.Count;
  if LCount = 0 then
    Exit;
  LIndex := FCmdList.ItemIndex + ADelta;
  if LIndex < 0 then
    LIndex := 0;
  if LIndex > LCount - 1 then
    LIndex := LCount - 1;
  FCmdList.ItemIndex := LIndex;
end;

procedure TAefosChatPanel._AcceptListSelection;
var
  LText: string;
begin
  if (FCmdList.ItemIndex < 0) or
    (FCmdList.ItemIndex > High(FCmdEntries)) then
    Exit;
  // BR-3: insert '/<name> ' and return focus to the input — never dispatch.
  LText := BuildInsertText(FCmdEntries[FCmdList.ItemIndex].Name);
  _HideCommandList;
  FInput.Text := LText;
  FInput.SelStart := Length(LText);
  FInput.SelLength := 0;
  if FInput.CanFocus then
    FInput.SetFocus;
end;

procedure TAefosChatPanel._PanelShow;
begin
  TChatPanelHost.ShowChatPanel;
  // Start browser navigation once the panel window exists. Idempotent:
  // Navigate no-ops after the first call (FNavigated guard in controller).
  if Assigned(FController) then
    FController.Navigate(_BuildPanelTheme);
end;

procedure TAefosChatPanel.LoadWindowState(Desktop: TCustomIniFile);
begin
  // Empty body required: TDockableForm declares this virtual abstract and
  // the IDE invokes it per desktop layout (default / project / debug) when
  // restoring docking. Without the override, calling it raises EAbstractError
  // — which the IDE surfaces as the "Abstract Error" dialog. No `inherited`
  // because the parent is abstract; no custom state to restore for this panel.
end;

procedure TAefosChatPanel.SaveWindowState(Desktop: TCustomIniFile;
  isProject: Boolean);
begin
  // Empty body required: see comment on LoadWindowState. The IDE calls
  // this 3 times on shutdown for a docked form (one per desktop layout),
  // producing the 3 stacked Abstract Error dialogs observed before this
  // override was added. No `inherited`; no custom state to persist.
end;

procedure TAefosChatPanel.Clear;
begin
  _RunOnMainThread(procedure
  begin
    if _UseBrowser then
      FController.EnqueueClear
    else
    begin
      if Assigned(FOutput) then
      begin
        FOutput.Lines.Clear;
        FOutput.Visible := False;
        if Assigned(FWelcomePanel) then
          FWelcomePanel.Visible := True;
      end;
    end;
  end);
end;

procedure TAefosChatPanel.ResetConversation;
begin
  // Idle reset (see the interface-declaration comment): the browser path drops
  // the recorded conversation + reconciles the turn state to idle via the
  // controller's ResetConversation (dsResetThread -> empty welcome, footer
  // "ready.", typing hidden, Send button restored, FInTurn := False). Calling
  // Clear here instead would post the "working..." turn-start indicator with no
  // dispatch behind it, freezing the panel on a pulsing "working..." after a
  // provider switch (reported live 2026-07-11). The non-browser fallback mirrors
  // Clear's else branch — a blank output + visible welcome IS the idle state.
  _RunOnMainThread(procedure
  begin
    if _UseBrowser then
      FController.ResetConversation
    else if Assigned(FOutput) then
    begin
      FOutput.Lines.Clear;
      FOutput.Visible := False;
      if Assigned(FWelcomePanel) then
        FWelcomePanel.Visible := True;
    end;
  end);
end;

procedure TAefosChatPanel._AppendToFOutput(const AText: string;
  const AStream: TStdStream);
var
  LWasReadOnly: Boolean;
begin
  if not (Assigned(FOutput) and FOutput.HandleAllocated) then
    Exit;
  if not FOutput.Visible then
  begin
    FOutput.Visible := True;
    if Assigned(FWelcomePanel) then
      FWelcomePanel.Visible := False;
  end;
  LWasReadOnly := FOutput.ReadOnly;
  FOutput.ReadOnly := False;
  try
    SendMessage(FOutput.Handle, EM_SETSEL, WPARAM(-1), LPARAM(-1));
    if AStream = stStderr then
      FOutput.SelAttributes.Color := clRed
    else
      FOutput.SelAttributes.Color := FOutput.Font.Color;
    FOutput.SelText := AText;
  finally
    FOutput.ReadOnly := LWasReadOnly;
  end;
  _ScrollToBottom;
end;

function TAefosChatPanel._TColorToHex(const AColor: TColor): string;
var
  LRgb: DWORD;
begin
  LRgb := ColorToRGB(AColor);
  Result := Format('#%.2x%.2x%.2x', [
    GetRValue(LRgb),
    GetGValue(LRgb),
    GetBValue(LRgb)
  ]);
end;

function TAefosChatPanel._BuildPanelTheme: TPanelTheme;
var
  {$IF Declared(IOTAIDEThemingServices250)}
  LTheming: IOTAIDEThemingServices250;
  {$IFEND}
  LStyle: TCustomStyleServices;
  LThemeName: string;
  LIsDark: Boolean;
begin
  LStyle := nil;
  LIsDark := False;
  LThemeName := '';
  // 10 Seattle's ToolsAPI has no theming service - that IDE had no themes - so
  // LStyle stays nil there and the luminance fallback right below decides
  // dark/light. That is the same path taken today when the service exists but
  // the user has theming switched off, so nothing new is being exercised.
  {$IF Declared(IOTAIDEThemingServices250)}
  if Assigned(BorlandIDEServices) and
     Supports(BorlandIDEServices, IOTAIDEThemingServices250, LTheming) then
  begin
    try
      LThemeName := LTheming.GetActiveThemeName;
      LIsDark := LThemeName.ToLower.Contains('dark');
      if LTheming.GetIDEThemingEnabled then
        LStyle := LTheming.GetIDEStyleServices;
    except
      LStyle := nil;
    end;
  end;
  {$IFEND}
  if (not Assigned(LStyle)) and (Self.Color <> clNone) then
    LIsDark := ((0.299 * GetRValue(ColorToRGB(Self.Color))) +
                (0.587 * GetGValue(ColorToRGB(Self.Color))) +
                (0.114 * GetBValue(ColorToRGB(Self.Color)))) < 128;
  // The chat shell is dark BY DESIGN (hardcoded dark surfaces + white-alpha
  // overlays: composer, attachment chips, header). Following a LIGHT IDE theme
  // paints a dark --ds-fg on that dark shell — exactly the unreadable composer
  // text reported on a no-/light-theme IDE. So the chat ALWAYS uses a dark
  // palette: for a DARK IDE theme we still match its exact system colours; for a
  // light or absent theme we fall back to the branded TPanelTheme.Dark (never the
  // light one). A proper light shell would need its own surface redesign (TODO).
  if LIsDark and Assigned(LStyle) then
  begin
    try
      Result := TPanelTheme.Dark;
      Result.Bg        := _TColorToHex(LStyle.GetSystemColor(clBtnFace));
      Result.Fg        := _TColorToHex(LStyle.GetSystemColor(clWindowText));
      Result.Secondary := _TColorToHex(LStyle.GetSystemColor(clGrayText));
      Result.Border    := _TColorToHex(LStyle.GetSystemColor(cl3DLight));
      Exit;
    except
      // StyleServices call failed - fall through to the branded dark default
    end;
  end;
  Result := TPanelTheme.Dark;
end;

procedure TAefosChatPanel.AppendChunk(const AText: string;
  const AStream: TStdStream);
begin
  if AText = '' then
    Exit;
  _RunOnMainThread(procedure
  begin
    if _UseBrowser then
    begin
      _EnsureOutputVisible;
      FController.EnqueueAppend(AText);
    end
    else
      _AppendToFOutput(AText, AStream);
  end);
end;

procedure TAefosChatPanel.ReportComplete(const AExitCode: Integer);
begin
  _RunOnMainThread(procedure
  var
    LMsg: string;
  begin
    if _UseBrowser then
    begin
      if AExitCode = 0 then
        FController.EnqueueFooter('completed.', False)
      else
        FController.EnqueueFooter(Format('exit code: %d', [AExitCode]), True);
    end
    else
    begin
      if AExitCode = 0 then
        LMsg := sLineBreak + '--- completed ---' + sLineBreak
      else
        LMsg := sLineBreak + Format('--- exit code: %d ---', [AExitCode]) + sLineBreak;
      AppendChunk(LMsg, stStdout);
    end;
    // Response completed: the full turn (user + assistant) is now in the
    // controller's history, so this is the safe point to record the session.
    _SaveCurrentSession;
    _NotifyTurnEnded;
    // Then hand the turn to the next queued send-during-run message (if any).
    _DrainQueuedMessage;
  end);
end;

procedure TAefosChatPanel._NotifyTurnEnded;
begin
  // Never let a listener's failure take the turn's completion down with it: this
  // runs after the answer is already on screen, and a drawing concern is not
  // worth an exception on the completion path.
  if not Assigned(FOnTurnEnded) then
    Exit;
  try
    FOnTurnEnded();
  except
    // deliberately silent -- see above
  end;
end;

procedure TAefosChatPanel.ReportError(const AException: Exception);
var
  LClassName, LMessage: string;
begin
  LClassName := AException.ClassName;
  LMessage := AException.Message;
  _RunOnMainThread(procedure
  var
    LMsg: string;
  begin
    // BR-6 / ADR-101: an error must be visible even when the panel was never
    // shown. Show it before writing the error output.
    _PanelShow;
    if _UseBrowser then
    begin
      _EnsureOutputVisible;
      LMsg := Format('error: %s (%s)', [LMessage, LClassName]);
      FController.EnqueueFooter(LMsg, True);
    end
    else
    begin
      if Assigned(FOutput) then
      begin
        LMsg := sLineBreak + Format('--- error: %s (%s) ---',
          [LMessage, LClassName]) + sLineBreak;
        AppendChunk(LMsg, stStderr);
      end;
    end;
    // An errored turn is a settled turn: close out anything still drawing itself
    // as live, then drain the send-during-run queue so a transient failure never
    // strands the messages behind it. Each drained message dispatches once; a
    // persistent failure surfaces one visible error per message (bounded by the
    // queue length — no retry loop).
    _NotifyTurnEnded;
    _DrainQueuedMessage;
  end);
end;

procedure TAefosChatPanel.PrefillInput(const AText: string);
begin
  // When the WebView is live, the HTML composer (#ds-input) IS the input — the VCL
  // TMemo is the legacy fallback. Prefilling the VCL one only popped its hidden
  // control (the welcome shortcut "opened a window that did nothing"); drive the
  // real composer instead so the slash-command lands where the user types/sends.
  if _UseBrowser and Assigned(FController) then
  begin
    FController.PrefillComposer(AText);
    Exit;
  end;
  if not Assigned(FInput) then
    Exit;
  FInput.Text := AText;
  FInput.SelStart := Length(AText);
  FInput.SelLength := 0;
  if FInput.CanFocus then
    FInput.SetFocus;
end;

// Returns an already-live TAefosChatPanel (e.g. one the IDE recreated from a saved
// desktop) so we ADOPT it instead of creating a second -> the double-instance fix
// (mirrors DTerminal.New scanning Screen.CustomForms). nil = none exists yet.
function _FindRestoredChatPanel: TAefosChatPanel;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to Screen.CustomFormCount - 1 do
    if Screen.CustomForms[I] is TAefosChatPanel then
      Exit(TAefosChatPanel(Screen.CustomForms[I]));
end;

class procedure TChatPanelHost.RegisterChatPanel;
begin
  // Adopt a desktop-restored instance before creating one (prevents two panels:
  // RegisterFieldAddress alone did not reliably bind GChatPanel to the restored
  // form, so a fresh create here floated a 2nd chat).
  if not Assigned(GChatPanel) then
    GChatPanel := _FindRestoredChatPanel;
  if not Assigned(GChatPanel) then
    GChatPanel := TAefosChatPanel.Create(nil);
  // NOTE: the desktop-persistence class/field registration is NOT here — it must
  // run at BPL LOAD (before the IDE restores a saved desktop at startup), so it
  // lives in RegisterChatDesktopClass (called by the host Register), release-only.
end;

class procedure TChatPanelHost.RegisterChatDesktopClass;
begin
  // DISABLED (2026-06-16). RegisterDesktopFormClass has NO unregister, so even the
  // release-only registration dangled after a Build-All-in-IDE and the IDE's
  // desktop-layout load (SwitchDesktopLayout -> LoadDesktopFormClasses ->
  // TDesktopFormClassItem.LoadWindow) AV'd on the dead class, corrupting the
  // "Default" layout. The chat reappears via Path B (debugger-notifier re-show)
  // instead — no native desktop persistence. Kept as a no-op so the host
  // Register call sites stay stable.
end;

class procedure TChatPanelHost.UnregisterChatDesktopClass;
begin
  // No-op: paired with the now-disabled RegisterChatDesktopClass (see above).
end;

class procedure TChatPanelHost.UnregisterChatPanel;
var
  LParentForm: TCustomForm;
begin
  _DbgLog('[Aefos] UnregisterChatPanel started.');
  GChatPanelShuttingDown := True;
  if Assigned(GChatPanel) then
  begin
    _DbgLog('[Aefos] UnregisterChatPanel: GChatPanel is assigned. Starting cleanup...');
    // Mark the focus seam shutting-down and drain its pending queued op BEFORE
    // ManualFloat re-parents the panel: a shut-down seam will not queue a new
    // focus op against the dying panel (the AV root cause).
    GChatPanel.BeginFocusShutdown;

    // 1. Clear the active control to prevent the IDE from trying to access it during deactivation
    try
      _DbgLog('[Aefos] UnregisterChatPanel: Clearing active control.');
      GChatPanel.ActiveControl := nil;
    except
      on E: Exception do
        _DbgLog('[Aefos] UnregisterChatPanel active control clear error: ' + E.Message);
    end;

    // 2. Scan and detach CnWizards components from the panel and the host parent form
    // BEFORE shifting focus via RefocusTopWindow or undocking via ManualFloat!
    try
      _DetachCnWizardsFromForm(GChatPanel);
      LParentForm := GetParentForm(GChatPanel);
      if Assigned(LParentForm) and (LParentForm <> GChatPanel) then
        _DetachCnWizardsFromForm(LParentForm);
    except
      on E: Exception do
        _DbgLog('[Aefos] UnregisterChatPanel CnWizards parent form detach error: ' + E.Message);
    end;

    // 3. Safely shift focus to the IDE main window before destroying the panel
    try
      _DbgLog('[Aefos] UnregisterChatPanel: Shifting focus away via RefocusTopWindow.');
      RefocusTopWindow;
    except
      on E: Exception do
        _DbgLog('[Aefos] UnregisterChatPanel RefocusTopWindow error: ' + E.Message);
    end;

    // 4. Programmatically undock the panel if it is docked
    try
      if GChatPanel.HostDockSite <> nil then
      begin
        _DbgLog(Format('[Aefos] UnregisterChatPanel: Form is docked in %s, programmatically undocking via ManualFloat.', [GChatPanel.HostDockSite.ClassName]));
        GChatPanel.ManualFloat(Rect(0, 0, 0, 0));
      end
      else
        _DbgLog('[Aefos] UnregisterChatPanel: Form is not docked (floating).');
    except
      on E: Exception do
        _DbgLog('[Aefos] UnregisterChatPanel ManualFloat error: ' + E.Message);
    end;

    GChatPanel.OnShow := nil;
    GChatPanel.OnResize := nil;
    _DbgLog('[Aefos] UnregisterChatPanel: Hiding panel and clearing Parent.');
    GChatPanel.Hide;
    GChatPanel.Parent := nil;
  end
  else
    _DbgLog('[Aefos] UnregisterChatPanel: GChatPanel is already nil.');

  // NOTE: UnregisterFieldAddress is paired at BPL teardown (host Register), not
  // here — it matches the load-time RegisterFieldAddress, not the per-open create.
  _DbgLog('[Aefos] UnregisterChatPanel: Calling FreeAndNil(GChatPanel).');
  FreeAndNil(GChatPanel);
  _DbgLog('[Aefos] UnregisterChatPanel completed successfully.');
end;

class procedure TChatPanelHost.ShowChatPanel(AFromUser: Boolean = False);
begin
  // Lazily create + wire the dock form on first open (the hook is the composition
  // root's _EnsureChatPanel). Idempotent: when the panel already exists (e.g. the
  // internal _PanelShow path) the hook returns immediately, so no recursion.
  if Assigned(GChatPanelEnsureHook) then
    GChatPanelEnsureHook();
  if not Assigned(GChatPanel) then
    Exit;
  // Anti-blink: the dispatch calls this on every submit; on an already-visible panel
  // re-showing flashes the WebView. So skip when already Visible — BUT NOT for an
  // explicit user "Open Chat" click (AFromUser): Visible can be True while the IDE
  // hid the dock on a desktop/layout switch, and the old unconditional early-exit
  // made the menu a no-op (the "vanishes and won't come back" bug). A user click
  // must always force it forward.
  if GChatPanel.Visible and not AFromUser then
    Exit;
  // ForceShow (TDockableForm) recovers a DOCKED pane the IDE hid on a layout switch —
  // plain ShowDockableForm/Show does not. Proven pattern in GExperts (GX_IdeDock) and
  // CnWizards (CnWizIdeDock). Plain Show only for a floating (undocked) window.
  if GChatPanel.Floating then
    GChatPanel.Show
  else
    GChatPanel.ForceShow;
  FocusWindow(GChatPanel);
end;

class function TChatPanelHost.ChatPanelSurface: IOutputPanelSurface;
begin
  Result := GChatPanel;
end;

initialization
  // Desktop persistence: register the dock CLASS at BPL LOAD here (this unit's
  // initialization runs BEFORE the IDE restores a saved desktop), so the chat is
  // recreated on restore -- exactly like the Terminal, which registers in its unit
  // init and restores reliably. (Was in the host Register proc = too late for the
  // startup/layout restore -> chat vanished.) Release-only + a no-op in DEBUG
  // (inside RegisterChatDesktopClass). Guarded: unit init must never abort BPL load.
  try
    TChatPanelHost.RegisterChatDesktopClass;
  except // NOSONAR — init must not raise.
    on E: Exception do
      _DbgLog('[Aefos] ChatPanel.init RegisterChatDesktopClass: '
        + E.ClassName + ' - ' + E.Message);
  end;

finalization
  try
    TChatPanelHost.UnregisterChatDesktopClass;  // pair the init RegisterFieldAddress (release-only)
  except // NOSONAR — teardown must never raise.
    on E: Exception do
      _DbgLog('[Aefos] ChatPanel.fin UnregisterChatDesktopClass: '
        + E.ClassName + ' - ' + E.Message);
  end;
  // Guarded: freeing a TDockableForm during BPL unload can fault if the
  // IDE's window/docking manager still holds a reference. An exception
  // escaping finalization is what produces the IDE-shutdown Abstract Error
  // dialogs + 0x80808078 AVs.
  try
    TChatPanelHost.UnregisterChatPanel;
  except // NOSONAR — teardown must never raise.
    on E: Exception do
      _DbgLog(
        'Aefos teardown [ChatPanel.finalization]: '
        + E.ClassName + ' - ' + E.Message);
  end;

  // *** BEFORE CHANGING THIS: read Aefos.OTA.Chat.UnloadContract (the law). ***
  // Safety net: the docked panel form is owned by the IDE's docking manager and
  // may NOT be destroyed before this BPL unmaps — so the panel destructor's
  // hook-restore never runs. If a global IDE hook (Application.OnMessage for the
  // Ctrl+V intercept, or the root form's OnShortCut) still points at OUR code,
  // force-restore it; otherwise the IDE keeps a method pointer into this unmapped
  // BPL: unload blocked, .bpl locked (F2039), AV on the next message/keystroke.
  // Comparing the wired Code against our own method address is exact; restore to
  // the saved prior handler, or nil if that is somehow ours too (double hook).
  try
    if TMethod(Application.OnMessage).Code = @TAefosChatPanel._AppMessage then
    begin
      if TMethod(GPrevAppOnMessage).Code = @TAefosChatPanel._AppMessage then
        Application.OnMessage := nil
      else
        Application.OnMessage := GPrevAppOnMessage;
      _DbgLog('[Aefos] ChatPanel.finalization: forced Application.OnMessage restore.');
    end;
  except // NOSONAR — teardown must never raise.
  end;

  try
    if Assigned(GHookedRoot) and
       (TMethod(TCustomFormAccess(GHookedRoot).OnShortCut).Code =
          @TAefosChatPanel._RootShortCut) then
    begin
      if TMethod(GPrevRootShortCut).Code = @TAefosChatPanel._RootShortCut then
        TCustomFormAccess(GHookedRoot).OnShortCut := nil
      else
        TCustomFormAccess(GHookedRoot).OnShortCut := GPrevRootShortCut;
      _DbgLog('[Aefos] ChatPanel.finalization: forced root OnShortCut restore.');
    end;
  except // NOSONAR — teardown must never raise.
  end;

end.
