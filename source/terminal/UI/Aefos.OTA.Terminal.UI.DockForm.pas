unit Aefos.OTA.Terminal.UI.DockForm;

interface

{$I ..\Aefos.OTA.Terminal.inc}

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Types,
  System.SysUtils,
  System.Classes,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Dialogs,
  Vcl.StdCtrls,
  Vcl.Buttons,
  Vcl.Themes,
  Vcl.ComCtrls,
  Vcl.Menus,
  ToolsAPI,
  DockForm,
  DeskUtil,
  Vcl.ExtCtrls,
  Aefos.OTA.Terminal.Core.Profiles,
  Aefos.OTA.Terminal.Core.SlashCommands,
  Aefos.OTA.Terminal.UI.ComposerWebPane,
  Aefos.OTA.Terminal.UI.ComposerPicker,
  Aefos.OTA.Terminal.Core.Themes,
  Aefos.OTA.Terminal.Core.Snippets,
  Aefos.OTA.Terminal.UI.SnippetEditDialog,
  Aefos.OTA.Terminal.UI.TerminalView,
  Aefos.OTA.Terminal.UI.ActivityPulse,
  Aefos.OTA.Terminal.Core.Layout,
  Aefos.OTA.Terminal.Core.ActionRunner,
  Aefos.OTA.Terminal.Core.Actions,
  Aefos.OTA.Terminal.UI.ActionExec,
  Aefos.OTA.Terminal.UI.ActionsSidebar,
  Aefos.OTA.Terminal.UI.SnippetsSidebar,
  Aefos.OTA.Terminal.UI.FindBar,
  System.Generics.Collections;

const
  /// <summary>Deferred welcome-card launch (ESP-058). Posted from
  /// <c>_OnWelcomeCardActivated</c> so the pane is freed and the terminal is
  /// spawned only after the originating card click has fully unwound.</summary>
  WM_WELCOME_LAUNCH = WM_USER + 137;

type

  // TMatchAnchor / TFindGridMetrics (the find-bar match-anchor + grid-metric records)
  // moved to Aefos.OTA.Terminal.UI.FindBar alongside the find logic that uses them;
  // the form no longer references them directly (it uses FindBar).

  // TSnippetSidebarRow (the shared snippets/actions list-row model) lives in
  // Aefos.OTA.Terminal.UI.ActionsSidebar so both extracted sidebar helpers
  // (TActionsSidebar + TSnippetsSidebar) can use it without a unit cycle. The form no
  // longer references it directly — each helper owns its own row array.

  /// <summary>
  ///   Owner-drawn toolbar surface (ESP-057 / ADR-057-02). Paints a
  ///   StyleServices-tracked chrome background plus a rounded "pill" behind
  ///   each child <see cref="TSpeedButton"/>, with the primary New-Tab action
  ///   carrying the orange accent. Visual-only: the flat speed buttons keep
  ///   their native hover/pressed feedback on top of the pill (BR1/BR5/BR8).
  /// </summary>
  TAefosTerminalToolbarPanel = class(TPanel)
  protected
    procedure Paint; override;
  end;

  TAefosTerminalDockForm = class(TDockableForm)
    pgcTerminals: TPageControl;
    pnlTerminalSidebar: TPanel;
    splSidebar: TSplitter;
    lstTerminals: TListBox;

    dlgFont: TFontDialog;
    pnlFind: TPanel;
    edtFind: TEdit;
    btnFindNext: TSpeedButton;
    btnFindPrev: TSpeedButton;
    chkCaseSensitive: TCheckBox;
    lblFindCount: TLabel;
    pnlToolbar: TAefosTerminalToolbarPanel;
    btnNewTab: TSpeedButton;
    btnActions: TSpeedButton;
    btnClosePane: TSpeedButton;
    btnShowFind: TSpeedButton;
    btnSplitV: TSpeedButton;
    btnSplitH: TSpeedButton;
    pnlSnippetsSidebar: TPanel;
    splSnippetsSidebar: TSplitter;
    btnSnippetsSidebar: TSpeedButton;
    procedure btnNewTabClick(Sender: TObject);
    procedure btnActionsClick(Sender: TObject);
    procedure btnSplitHClick(Sender: TObject);
    procedure btnSplitVClick(Sender: TObject);
    procedure btnClosePaneClick(Sender: TObject);
    procedure btnFontClick(Sender: TObject);
    procedure btnShowFindClick(Sender: TObject);
    procedure edtFindChange(Sender: TObject);
    procedure btnFindNextClick(Sender: TObject);
    procedure btnFindPrevClick(Sender: TObject);
    procedure edtFindKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure lstTerminalsClick(Sender: TObject);
    procedure lstTerminalsDrawItem(Control: TWinControl; Index: Integer; Rect: TRect; State: TOwnerDrawState);
    procedure lstTerminalsMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure lstTerminalsMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    // Must stay published: wired as pgcTerminals.OnChange in the .dfm, so the
    // DFM reader resolves it via MethodAddress (published methods only).
    procedure _OnTabChange(Sender: TObject);
  private
    pmNewTab: TPopupMenu;
    // ESP-058 review #95: this handler is _-prefixed per the documented
    // private-method convention (20-delphi-conventions.md). The sibling
    // On*Click handlers below predate the rule and remain grandfathered; a
    // future cleanup normalizes the whole VCL event-handler cluster.
    procedure _OnNewWelcomeTabClick(Sender: TObject);
    procedure OnProfileMenuItemClick(Sender: TObject);
    procedure OnSplitHMenuClick(Sender: TObject);
    procedure OnSplitVMenuClick(Sender: TObject);
    procedure OnSnippetMenuItemClick(Sender: TObject);
    procedure OnManageSnippetsClick(Sender: TObject);
    procedure OnThemeMenuItemClick(Sender: TObject);
    procedure OnFontMenuClick(Sender: TObject);
    procedure OnDefaultProfileMenuItemClick(Sender: TObject);
    procedure OnAutoSyncClick(Sender: TObject);
    procedure OnActionMenuItemClick(Sender: TObject);
    procedure OnManageActionsClick(Sender: TObject);
    // V.5 command palette (ESP-062): run an action by id / launch a profile by
    // index (shared with the menu handlers), and open the Ctrl+P overlay.
    procedure _RunActionById(const AActionId: string);
    procedure _LaunchProfile(const AProfileIndex: Integer);
    procedure _ShowCommandPalette;
  private
    FTerminalViews: TList<TAefosTerminalTerminalView>;
    FFocusedView: TAefosTerminalTerminalView;
    FProfileManager: TProfileManager;
    FThemeManager: TThemeManager;
    FSnippetManager: TSnippetManager;
    // Runs saved terminal actions by id (extracted helper, DockForm split).
    FActionExecutor: TTerminalActionExecutor;
    FSnippetsPopup: TPopupMenu;
    FHoveredItemIndex: Integer;
    FHoveredAction: Integer;
    FOriginalListBoxWP: TWndMethod;
    // V.2 activity pulse (ESP-059): tracks which views had recent output.
    // Extracted helper (DockForm split) — owns the map + decay timer.
    FActivityPulse: TTerminalActivityPulse;
    // V.3 snippets sidebar (ESP-060): extracted helper (DockForm split) owning the
    // snippets panel's controls + row model, built into the DFM pnlSnippetsSidebar.
    FSnippetsSidebar: TSnippetsSidebar;
    // AI composer bar (toolbar toggle): a footer input that turns THIS terminal
    // into an "AI terminal" — the user runs their own CLI in the pane, then drives
    // it from the bar (type / for an installed command, or a plain message; Enter
    // injects it into the active PTY). Created in _InitComposerBar; hidden by default.
    FComposerBar: TPanel;
    FComposerPane: TComposerWebPane;
    FComposerBtn: TSpeedButton;
    // Floating '/' command picker: a CHILD control of this DockForm that overlays
    // the terminal (above the composer bar) instead of pushing layout up. As a
    // child it never activates and never steals focus off the webview textarea.
    // FComposerFilter mirrors the current slash query so a commit with no match
    // falls back to injecting it verbatim.
    FPickerForm: TComposerPickerControl;
    FComposerFilter: string;
    // Composer attachments (paperclip chips): id -> full file path. FAttachSeq
    // mints a fresh id per pick. On a plain send the paths are appended to the
    // injected text (the PTY is text-only) then cleared; a '/command' commit is
    // self-contained and never carries attachments.
    FAttachments: TDictionary<string, string>;
    FAttachSeq: Integer;
    // Shared LEFT host for the two left sidebars (snippets + actions). The host, the
    // inter-sidebar splitter and the snippets-wanted flag STAY on the form;
    // _ArrangeLeftSidebars coordinates geometry across both sidebars.
    FLeftSidebarHost: TPanel;
    FSidebarVSplitter: TSplitter;
    FSnippetsWanted: Boolean;
    // Actions execution sidebar (ESP-060+): extracted helper (DockForm split) owning
    // the actions panel + its controls + row model, built into FLeftSidebarHost.
    FActionsSidebar: TActionsSidebar;
    // V.8 (ESP-065 / ADR-065-03): the find bar (overlay show/hide, incremental search,
    // counter, anchor, theme tint, keyboard-focus ring) is an extracted helper (DockForm
    // split) owning the DFM-published find controls' behaviour + the pnlFind WindowProc
    // subclass. The DFM-wired handlers stay on the form as thin forwarders.
    FFindBar: TFindBar;
    procedure ListBoxSubclassWP(var Message: TMessage);
    procedure _SyncTerminalsList;
    // True when the sidebar row AIndex is the welcome/home tab (hosts a
    // TWelcomeWebPane). Used to keep it intact — no split/close hover icons.
    function _IsWelcomeTab(const AIndex: Integer): Boolean;
    procedure SaveWorkspace;
    procedure LoadWorkspace;
    procedure _InitComposerBar;
    procedure _ToggleComposerBar(Sender: TObject);
    procedure _ComposerPaneSend(Sender: TObject; const AText: string);
    procedure _ComposerRequestHeight(Sender: TObject; const AHeight: Integer);
    // Attachment chips: paperclip opens a file picker, the chip X removes one,
    // the brain opens the global-memory editor. _PushComposerAttachments syncs
    // the webview chip bar from FAttachments.
    procedure _ComposerAttachOpen(Sender: TObject);
    procedure _ComposerAttachRemove(Sender: TObject; const AId: string);
    procedure _ComposerMemoryOpen(Sender: TObject);
    procedure _PushComposerAttachments;
    // '/' picker: relays webview keyboard intents to the floating picker window.
    procedure _ComposerPicker(Sender: TObject;
      AAction: TComposerPickerAction; const AQuery: string);
    // Commits a picked command (click or Enter): injects it and closes the picker.
    procedure _PickerPicked(Sender: TObject; const ACommand: TSlashCommand);
    // Injects a '/name' (expanded) or plain text into the active pane; clears input.
    procedure _InjectComposerText(const AText: string);
    procedure _InitSpeedButtons;
    procedure _ShowSnippetsPopup;
    // Coordinator: flips BOTH left sidebars (snippets via FSnippetsSidebar + actions via
    // FActionsSidebar) and re-arranges. Stays on the form; the snippets helper reaches it
    // through its OnToggle callback (chevron + list Esc).
    procedure _ToggleSnippetsSidebar(Sender: TObject);
    // Left-sidebar host + cross-sidebar geometry coordinator (stay on the form; the
    // actions panel itself lives in FActionsSidebar). _InitLeftSidebarHost builds the
    // shared host + splitter; the actions helper is constructed into it afterward.
    procedure _InitLeftSidebarHost;
    procedure _ArrangeLeftSidebars;
    function _ExportNode(AContainer: TWinControl): TLayoutNode;
    procedure _ImportNode(ANode: TLayoutNode; AParent: TWinControl);
  protected
    procedure _OnTerminalFocus(Sender: TObject);
    procedure _OnTerminalSnippetsRequest(Sender: TObject);
    // True when the focus currently sits inside the focused terminal view —
    // the canvas itself or its AI-CLI context-strip child (ESP-076). Feeds the
    // pure ShouldRouteShortcutToCanvas predicate so the Ctrl+C/Ctrl+V intercept
    // is restored after the context strip could hold focus (ESP-080/ADR-080-01).
    function _ActivePaneIsTerminalView: Boolean;
    procedure SetParent(AParent: TWinControl); override;
    procedure Resize; override;
  private
    procedure _InitManagers;
    procedure _InitLayout;
    procedure _ApplyActiveTheme;
    procedure _TerminateViewsInTab(ATab: TTabSheet);
    
    function _AddTerminalTab(const AName: string): TTabSheet;
    procedure _AddTerminalView(const AExecutable, AArguments, AStartDir: string; AParent: TWinControl = nil; const AProfileName: string = '');
    
    function _IsViewInTab(AView: TAefosTerminalTerminalView; ATab: TTabSheet): Boolean;
    function _CountViewsInTab(ATab: TTabSheet): Integer;
    function _FindViewInTab(ATab: TTabSheet): TAefosTerminalTerminalView;
    procedure _GetContainerContent(AContainer: TWinControl; out AView: TAefosTerminalTerminalView; 
      out ASplitter: TSplitter; out APanel: TPanel);
    procedure _CleanupContainer(AContainer: TWinControl);
    
    procedure _HandleTabShortcuts(var Key: Word; Shift: TShiftState);
    // The find-bar handlers (_HandleFindShortcuts / _UpdateFindCounter / _AnchorFindOverlay
    // / _ApplyFindOverlayTheme + the find click/key handlers) moved into TFindBar (FFindBar);
    // the form keeps only the DFM-wired forwarders + the active-pane outline below.
    // V.4 (ESP-061): refresh the active-pane accent outline. Visual-only (BR1).
    procedure _UpdateActivePaneOutline;

    procedure _SaveActionCenterState(AWorkspace: TWorkspaceLayout);
    procedure _RestoreActionCenterState(AWorkspace: TWorkspaceLayout);
    procedure _ExportViewNode(ANode: TLayoutNode; AView: TAefosTerminalTerminalView);
    procedure _ExportSplitNode(ANode: TLayoutNode; AContainer: TWinControl; ASplitter: TSplitter);
    function _GetSplitOrientation(ASplitter: TSplitter): string;
    function _GetSplitPercent(AContainer: TWinControl; ASplitter: TSplitter; 
      const AOrientation: string): Double;
    procedure _ImportViewNode(ANode: TLayoutNode; AParent: TWinControl);
    procedure _ImportSplitNode(ANode: TLayoutNode; AParent: TWinControl);
    procedure _ConfigureSplitControls(ANode: TLayoutNode; AParent, 
      AChild1: TWinControl; ASplitter: TSplitter);
    procedure _DoSplit(AAlign: TAlign);
    function _CreatePanel(AParent: TWinControl): TPanel;
    function _CreateSplitter(AParent: TWinControl): TSplitter;
    
    function _GetControlByAlign(AContainer: TWinControl; AAlign: TAlign; 
      AExclude: TControl): TWinControl;
    function _DoExportSplit(AContainer: TWinControl; ASplitter: TSplitter): TLayoutNode;
    function _DoExportView(AView: TAefosTerminalTerminalView): TLayoutNode;
    function _ShouldCloseActiveTab: Boolean;
    procedure _OpenDefaultPane;
    // V.1 welcome pane (ESP-058). _OpenWelcomeTab parents a host-less
    // TWelcomePane into a fresh tab; _OnWelcomeCardActivated posts
    // WM_WELCOME_LAUNCH so the pane->terminal swap runs after the card click
    // has unwound (it frees the pane that owns the clicked control).
    procedure _OpenWelcomeTab;
    procedure _AddWelcomeTabMenuItems(AMenu: TPopupMenu);
    procedure _OnTerminalActivity(Sender: TObject);
    procedure _OnActivityDecayed(Sender: TObject);
    procedure _DrawActivityPulse(ACanvas: TCanvas; const ARect: TRect;
      ADotMid, AIndex: Integer);
    procedure _OnWelcomeCardActivated(Sender: TObject; const AProfileIndex: Integer);
    procedure WMWelcomeLaunch(var AMessage: TMessage); message WM_WELCOME_LAUNCH;
    procedure _DoCloseActivePane;
    procedure _UpdateAfterPaneClose(ALastTab: TTabSheet);
    procedure _FlattenTabToSingleView(const ATab: TTabSheet);
  public
    function IsShortCut(var AMessage: TWMKey): Boolean; override;
    /// <summary>
    ///   Initializes a new instance of the dock form and loads the workspace.
    /// </summary>
    constructor Create(AOwner: TComponent); override;
    /// <summary>
    ///   Saves the workspace and cleans up resources.
    /// </summary>
    destructor Destroy; override;
    /// <summary>
    ///   Navigates the focused terminal pane to the specified path.
    /// </summary>
    procedure NavigateTo(const APath: string);

    // Public members accessed by Aefos.OTA.Terminal.UI.SnippetsForm
    property SnippetManager: TSnippetManager read FSnippetManager;
    property ProfileManager: TProfileManager read FProfileManager;
    procedure _CreateButtonGlyph(AButton: TSpeedButton; const AIconType: string);
    function _IsIDEDarkTheme: Boolean;
    /// <summary>
    ///   Builds the live {{...}} variable context from current IDE state
    ///   (OTA project, focused profile, git, datetime). Caller owns the result.
    ///   The snippet editor's live preview renders against this (ESP-064/BR1).
    /// </summary>
    function _BuildSnippetVarContext: TDictionary<string, string>;
    /// <summary>
    ///   Splits the active pane horizontally.
    /// </summary>
    procedure SplitHorizontal;
    /// <summary>
    ///   Splits the active pane vertically.
    /// </summary>
    procedure SplitVertical;
    /// <summary>
    ///   Closes the active terminal pane.
    /// </summary>
    procedure SendCommandToActivePane(const ACommand: string);
    procedure CloseActivePane;
    /// <summary>
    ///   Closes the active terminal tab.
    /// </summary>
    procedure CloseActiveTab;
    /// <summary>
    ///   Returns the terminal-input channel of the focused pane, or nil.
    /// </summary>
    function ActiveTerminalInput: ITerminalInput;
    /// <summary>Currently focused terminal view, or nil. Exposed so the
    /// wizard's Application.OnShortCut hook can route Ctrl+C to it.</summary>

    ///
    function AutoSync: Boolean;
    /// <summary>Re-derives Project/Team snippet scope roots from the active
    /// OTA project (empty when none) and refreshes the sidebar (ESP-060).</summary>
    procedure UpdateSnippetScopes;
    property FocusedView: TAefosTerminalTerminalView read FFocusedView;
  end;

var
  AefosTerminalDockForm: TAefosTerminalDockForm;

procedure ShowAefosTerminalDockForm(const ANavigateTo: string = '');
/// <summary>
///   Returns the terminal-input channel of the focused pane, or nil when no
///   terminal is active. Consumed by TActionRunner.
/// </summary>
function AefosOTATerminalActiveTerminalInput: ITerminalInput;

// ComputeMatchRect / FormatFindCounter / ComputeFindOverlayRect (the find-bar pure
// helpers) moved to Aefos.OTA.Terminal.UI.FindBar with the find logic that uses them.

/// <summary>
///   Pure predicate for the active-pane outline (ESP-061 / ADR-061-03). The
///   focused pane carries the orange accent outline only when two or more
///   panes are visible; a single-pane layout shows no outline.
/// </summary>
function ShouldDrawActivePaneOutline(const APaneCount: Integer): Boolean;

/// <summary>
///   Pure routing predicate for the terminal Ctrl+C / Ctrl+V shortcut intercept
///   (ESP-080 / ADR-080-01). Returns True only when a plain Ctrl+C or Ctrl+V
///   (no Alt, no Shift) is pressed while the active pane is a live terminal
///   view — the case where the keystroke must reach the canvas paste/copy path
///   instead of the IDE's global Edit action. Any other modifier blend, any
///   other key, or a non-terminal active pane returns False so the keystroke
///   passes through unchanged (AC1/AC2/BR5). No VCL state — headless-testable.
/// </summary>
function ShouldRouteShortcutToCanvas(const ACharCode: Word;
  const ACtrlDown, AAltDown, AShiftDown, AActivePaneIsTerminal: Boolean): Boolean;

implementation

  uses
    Aefos.OTA.Terminal.UI.ActionCenterView, System.IOUtils, Aefos.OTA.Terminal.UI.SnippetsForm, Aefos.OTA.Terminal.UI.FontDialog, Aefos.OTA.Terminal.UI.IDEThemes,
    Aefos.OTA.Terminal.Core.ActionStore, Aefos.OTA.Terminal.Core.VisualTokens, Aefos.OTA.Terminal.Core.Accessibility, Aefos.OTA.Terminal.UI.WelcomePane, Aefos.OTA.Terminal.UI.WelcomeWebPane,
    Aefos.OTA.Terminal.Core.TerminalHost,
    Aefos.OTA.Terminal.Core.WelcomeModel, Aefos.OTA.Terminal.Core.CommandPalette, Aefos.OTA.Terminal.UI.CommandPaletteView,
    Aefos.OTA.Terminal.Core.WindowPlacement,
    Aefos.OTA.Terminal.UI.ComposerMemory;

{$R *.dfm}

{ TAefosTerminalToolbarPanel }

procedure TAefosTerminalToolbarPanel.Paint;
var
  LTheming: IOTAIDEThemingServices;
  LStyle: TCustomStyleServices;
  LBg, LPill: TColor;
  LIndex: Integer;
  LCtrl: TControl;
  LBtn: TSpeedButton;
  LRect: TRect;
begin
  LStyle := nil;
  if Assigned(BorlandIDEServices) and
     Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
     LTheming.IDEThemingEnabled then
    LStyle := LTheming.GetIDEStyleServices;

  // Base chrome surface comes from StyleServices (BR5) so the toolbar tracks
  // the locked "Delphi IDE" theme; accents come from VisualTokens.
  LBg := TVisualSurfaces.ChromeBackground(LStyle);
  LPill := TVisualTokens.SurfaceHover(LBg);

  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := LBg;
  Canvas.FillRect(ClientRect);

  Canvas.Pen.Style := psClear;
  for LIndex := 0 to ControlCount - 1 do
  begin
    LCtrl := Controls[LIndex];
    if not (LCtrl is TSpeedButton) or not LCtrl.Visible then
      Continue;
    LBtn := TSpeedButton(LCtrl);
    LRect := LBtn.BoundsRect;
    // The primary New-Tab action carries the orange accent pill; the rest use
    // the neutral surface pill. The flat speed buttons paint their glyph and
    // native hover/pressed feedback on top of the pill afterwards.
    if SameText(LBtn.Name, 'btnNewTab') then
      Canvas.Brush.Color := TVisualTokens.Accent
    else
      Canvas.Brush.Color := LPill;
    Canvas.RoundRect(LRect.Left, LRect.Top, LRect.Right, LRect.Bottom, 8, 8);
  end;
  Canvas.Pen.Style := psSolid;
end;

// ComputeMatchRect / FormatFindCounter / ComputeFindOverlayRect moved to
// Aefos.OTA.Terminal.UI.FindBar (the find logic that consumes them moved with them).

function ShouldDrawActivePaneOutline(const APaneCount: Integer): Boolean;
begin
  Result := APaneCount >= 2;
end;

function ShouldRouteShortcutToCanvas(const ACharCode: Word;
  const ACtrlDown, AAltDown, AShiftDown, AActivePaneIsTerminal: Boolean): Boolean;
begin
  // Plain Ctrl+C / Ctrl+V routes to the terminal canvas only when the active
  // pane is a live terminal view. Alt or Shift held, or a non-terminal pane,
  // passes the keystroke through to the IDE (Shift+Insert stays the untouched
  // paste fallback — its VK_INSERT key never reaches here).
  Result := AActivePaneIsTerminal and ACtrlDown and
            (not AAltDown) and (not AShiftDown) and
            ((ACharCode = Ord('C')) or (ACharCode = Ord('V')));
end;

/// <summary>
///   Registers TAefosTerminalDockForm with the IDE theming service so the form
///   stays themed when undocked/floating. Without RegisterFormClass the
///   floating window falls back to unstyled system chrome.
/// </summary>
/// <remarks>Authorized by ADR-027-01.</remarks>
procedure _RegisterThemedFormClass;
begin
  // No-op to prevent Access Violations on IDE close/BPL unload
end;

procedure _UnregisterThemedFormClass;
begin
  // No-op
end;

/// <summary>
///   Applies the active IDE theme to controls the system style hooks do
///   not cover (panels, labels). No-op headlessly when BorlandIDEServices
///   is nil.
/// </summary>
/// <remarks>Authorized by ADR-027-01.</remarks>
procedure _ApplyIDETheme(const AForm: TCustomForm);
begin
  ApplyAefosTerminalIDETheme(AForm);
end;

procedure _ApplyMenuTheme(const AMenu: TPopupMenu);
var
  LThemeServices: IOTAIDEThemingServices250;
begin
  if Assigned(BorlandIDEServices) and
     Supports(BorlandIDEServices, IOTAIDEThemingServices250, LThemeServices) and
     LThemeServices.IDEThemingEnabled then
    LThemeServices.ApplyTheme(AMenu);
end;

function AefosOTATerminalActiveTerminalInput: ITerminalInput;
begin
  Result := nil;
  if Assigned(AefosTerminalDockForm) then
    Result := AefosTerminalDockForm.ActiveTerminalInput;
end;

/// <summary>
///   A primary-monitor-centered fallback rect sized to <c>AForm</c>, used by
///   the off-screen guard when the persisted bounds fall outside every monitor
///   (ESP-083 / ADR-083-02). Returns <c>AForm.BoundsRect</c> unchanged when no
///   primary monitor is reported, so the guard degrades to a no-op (BR4).
/// </summary>
function _PrimaryCenteredDefault(AForm: TCustomForm): TRect;
var
  LPrimary: TRect;
begin
  if Screen.PrimaryMonitor = nil then
    Exit(AForm.BoundsRect);
  LPrimary := Screen.PrimaryMonitor.BoundsRect;
  Result.Left := LPrimary.Left + (LPrimary.Width - AForm.Width) div 2;
  Result.Top := LPrimary.Top + (LPrimary.Height - AForm.Height) div 2;
  Result.Right := Result.Left + AForm.Width;
  Result.Bottom := Result.Top + AForm.Height;
end;

/// <summary>
///   Floating-only off-screen recovery (ADR-083-02 / AC3): when <c>AForm</c> is
///   a free top-level window (<c>Parent = nil</c>) whose bounds lie entirely
///   off every monitor, reset it to a primary-centered default. A docked form
///   (parented to the IDE dock host, bounds in client coords) is never
///   repositioned (R3); a partially-visible form is kept (AC2). Never raises.
/// </summary>
procedure _RecoverOffScreenBounds(AForm: TCustomForm);
var
  LMonitors: array of TRect;
  LIndex: Integer;
  LResolved: TRect;
begin
  if AForm.Parent <> nil then
    Exit; // docked → IDE dock-manager owns position; never reposition
  SetLength(LMonitors, Screen.MonitorCount);
  for LIndex := 0 to Screen.MonitorCount - 1 do
    LMonitors[LIndex] := Screen.Monitors[LIndex].BoundsRect;

  LResolved := TWindowPlacement.ResolveVisibleBounds(AForm.BoundsRect,
    _PrimaryCenteredDefault(AForm), LMonitors);
  if LResolved <> AForm.BoundsRect then
    AForm.BoundsRect := LResolved;
end;

/// <summary>
///   The top-level window to pull forward after re-activating the panel: the
///   form's own handle when floating, otherwise the IDE main window so the
///   surrounding IDE comes forward with the re-activated dock tab. Returns 0
///   when no usable handle exists (caller skips <c>SetForegroundWindow</c>).
/// </summary>
function _ForegroundHandle(AForm: TCustomForm): HWND;
begin
  if AForm.Parent = nil then
    Result := AForm.Handle
  else if Assigned(Application.MainForm) then
    Result := Application.MainForm.Handle
  else
    Result := AForm.Handle;
end;

// Returns an already-live TAefosTerminalDockForm (e.g. one the IDE recreated from a
// saved desktop) so we ADOPT it instead of creating a second (anti double-instance,
// mirrors DTerminal.New). nil = none exists yet.
function _FindRestoredTerminalForm: TAefosTerminalDockForm;
var
  LIndex: Integer;
begin
  Result := nil;
  for LIndex := 0 to Screen.CustomFormCount - 1 do
    if Screen.CustomForms[LIndex] is TAefosTerminalDockForm then
      Exit(TAefosTerminalDockForm(Screen.CustomForms[LIndex]));
end;

procedure ShowAefosTerminalDockForm(const ANavigateTo: string = '');
var
  LHandle: HWND;
begin
  if not Assigned(AefosTerminalDockForm) then
    AefosTerminalDockForm := _FindRestoredTerminalForm;  // adopt a restored one
  if not Assigned(AefosTerminalDockForm) then
  begin
    _RegisterThemedFormClass;
    AefosTerminalDockForm := TAefosTerminalDockForm.Create(nil);
  end;

  _RecoverOffScreenBounds(AefosTerminalDockForm);

  // Re-activation. CRITICAL: when the form is DOCKED, use ForceShow (TDockableForm)
  // — plain Show does NOT recover a dock pane that the IDE hid on a desktop/layout
  // switch (the "it vanishes and clicking the menu again won't bring it back" bug,
  // reported on the Terminal). ForceShow is exactly how the IDE dock-manager brings a
  // hidden docked form back; it's the proven pattern in GExperts (GX_IdeDock) and
  // CnWizards (CnWizIdeDock). Plain Show only for a floating (undocked) window.
  if AefosTerminalDockForm.Floating then
    AefosTerminalDockForm.Show
  else
    AefosTerminalDockForm.ForceShow;
  AefosTerminalDockForm.BringToFront;
  LHandle := _ForegroundHandle(AefosTerminalDockForm);
  if LHandle <> 0 then
    SetForegroundWindow(LHandle);

  if ANavigateTo <> '' then
    AefosTerminalDockForm.NavigateTo(ANavigateTo);
end;

{ TAefosTerminalDockForm }

procedure TAefosTerminalDockForm.NavigateTo(const APath: string);
begin
  if Assigned(FFocusedView) then
    FFocusedView.Host.NavigateTo(APath);
end;

constructor TAefosTerminalDockForm.Create(AOwner: TComponent);
begin
  inherited;
  Caption := 'Aefos Terminal';
  // IDE desktop persistence (DeskSection/AutoSave + RegisterDesktopFormClass)
  // DISABLED (2026-06-16): no UnregisterDesktopFormClass exists, so a
  // Build-All-in-IDE dangles the registered class and the AutoSave'd .dst section
  // AVs the next desktop-layout load (corrupted "Default" layout, crash on project
  // open). Same root cause as the chat dock. No DeskSection -> not keyed into the
  // desktop INI.
  SaveStateNecessary := False;
  AutoSave := False;
  KeyPreview := True;
  OnKeyDown := FormKeyDown;
  FTerminalViews := TList<TAefosTerminalTerminalView>.Create;
  FActionExecutor := TTerminalActionExecutor.Create;
  FActivityPulse := TTerminalActivityPulse.Create(_OnActivityDecayed);
  pgcTerminals.OnChange := _OnTabChange;

  pmNewTab := TPopupMenu.Create(Self);

  FHoveredItemIndex := -1;
  FHoveredAction := 0;
  if Assigned(lstTerminals) then
  begin
    lstTerminals.StyleElements := [seFont, seBorder];
    FOriginalListBoxWP := lstTerminals.WindowProc;
    lstTerminals.WindowProc := ListBoxSubclassWP;
  end;

  // V.8 (ESP-065 / ADR-065-03): build the find bar over the DFM-published find controls.
  // The helper installs the pnlFind WindowProc subclass (the uniform keyboard-focus ring,
  // same swap pattern used for lstTerminals above) in its constructor and restores it in
  // its destructor — so it is freed in Destroy BEFORE the inherited destructor frees the
  // panel. FFocusedView is fetched fresh each call (mutable form state); pgcTerminals is
  // the overlay's anchor frame.
  FFindBar := TFindBar.Create(Self, pnlFind, edtFind, btnFindNext, btnFindPrev,
    chkCaseSensitive, lblFindCount, pgcTerminals,
    function: TAefosTerminalTerminalView
    begin
      Result := FFocusedView;
    end);

  _InitSpeedButtons;
  _InitManagers;
  _InitComposerBar;
  // Build the snippets sidebar into the DFM panel pnlSnippetsSidebar (form-owned, so
  // teardown is unchanged). FSnippetManager is injected — it stays owned by the form
  // (created in _InitManagers, freed in Destroy, exposed via the SnippetManager prop).
  // The callbacks reach back into the form: a fresh FFocusedView each call (mutable
  // state), _RunActionById for mixed action rows, _ToggleSnippetsSidebar (the both-
  // sidebar coordinator, for chevron + Esc), _ArrangeLeftSidebars, _IsIDEDarkTheme.
  // Built BEFORE _InitLeftSidebarHost re-parents the panel into the shared host, exactly
  // as the old _InitSnippetsSidebar ran before it (visual result unchanged).
  FSnippetsSidebar := TSnippetsSidebar.Create(Self, pnlSnippetsSidebar, FSnippetManager,
    function: TAefosTerminalTerminalView
    begin
      Result := FFocusedView;
    end,
    procedure(AId: string)
    begin
      _RunActionById(AId);
    end,
    procedure
    begin
      _ToggleSnippetsSidebar(nil);
    end,
    _ArrangeLeftSidebars,
    function: Boolean
    begin
      Result := _IsIDEDarkTheme;
    end);
  // Build the shared left host FIRST so the actions helper has somewhere to dock; then
  // construct the helper into it. The form stays the Owner of every actions control, so
  // teardown is unchanged. Geometry callbacks are method/closure references into the
  // form: _RunActionById (run an action), _ArrangeLeftSidebars (parameterless coord),
  // _IsIDEDarkTheme (theme query). The helper is freed in Destroy before the form's
  // controls, so these never reach a dead form.
  _InitLeftSidebarHost;
  FActionsSidebar := TActionsSidebar.Create(Self, FLeftSidebarHost,
    procedure(AId: string)
    begin
      _RunActionById(AId);
    end,
    _ArrangeLeftSidebars,
    function: Boolean
    begin
      Result := _IsIDEDarkTheme;
    end);
  LoadWorkspace;
  _InitLayout;
  _ApplyActiveTheme;
  _SyncTerminalsList;
  _ApplyIDETheme(Self);

  // If the Action Center was already restored from layout, force its icons to bind now
  if Assigned(AefosActionCenterView) then
    AefosActionCenterView.UpdateGlyphs;

  // Seed the snippet scope roots from the active project (if one is open).
  UpdateSnippetScopes;
end;

procedure TAefosTerminalDockForm._InitSpeedButtons;
begin
  // Set double buffering for smooth rendering and no flickering
  DoubleBuffered := True;
  pgcTerminals.DoubleBuffered := True;
  pnlToolbar.DoubleBuffered := True;
  if Assigned(pnlTerminalSidebar) then
    pnlTerminalSidebar.DoubleBuffered := True;
  if Assigned(lstTerminals) then
    lstTerminals.DoubleBuffered := True;

  // Main Toolbar Buttons
  btnNewTab.Flat := True;
  btnNewTab.Hint := 'New Terminal / Options (Ctrl+T)';
  btnNewTab.ShowHint := True;
  btnNewTab.Caption := '';
  _CreateButtonGlyph(btnNewTab, 'plusChevron');

  // Actions button: dedicated icon (lightning) that toggles the Action Center,
  // mirroring the {} snippets-sidebar button. Replaces the old 'Commands'
  // dropdown combobox (2026-06-09 — its menu duplicated the + button).
  btnActions.Flat := True;
  btnActions.Hint := 'Actions sidebar (toggle)';
  btnActions.ShowHint := True;
  btnActions.Caption := '';
  _CreateButtonGlyph(btnActions, 'actions');

  // Snippets sidebar toggle (ESP-061 / ADR-061-01): glyph-only left-cluster
  // icon. Drawn here as well as in _InitSnippetsSidebar so a theme switch
  // (which re-runs _InitSpeedButtons) re-tints the braces with the new pen
  // color, consistent with every other toolbar glyph (BR4).
  if Assigned(btnSnippetsSidebar) then
  begin
    btnSnippetsSidebar.Flat := True;
    btnSnippetsSidebar.Caption := '';
    _CreateButtonGlyph(btnSnippetsSidebar, 'snippets');
    // Toggle wiring stays on the form (the toolbar button coordinates BOTH sidebars
    // via _ToggleSnippetsSidebar); only the snippets panel's own controls moved to
    // TSnippetsSidebar. Formerly set in _InitSnippetsSidebar.
    btnSnippetsSidebar.Hint := 'Snippets sidebar (toggle)';
    btnSnippetsSidebar.ShowHint := True;
    btnSnippetsSidebar.OnClick := _ToggleSnippetsSidebar;
  end;

  btnSplitH.Flat := True;
  btnSplitH.Hint := 'Split Horizontally';
  btnSplitH.ShowHint := True;
  btnSplitH.Caption := '';
  _CreateButtonGlyph(btnSplitH, 'splitH');

  btnSplitV.Flat := True;
  btnSplitV.Hint := 'Split Vertically';
  btnSplitV.ShowHint := True;
  btnSplitV.Caption := '';
  _CreateButtonGlyph(btnSplitV, 'splitV');

  btnClosePane.Flat := True;
  btnClosePane.Hint := 'Close Active Pane (Ctrl+W)';
  btnClosePane.ShowHint := True;
  btnClosePane.Caption := '';
  _CreateButtonGlyph(btnClosePane, 'trash');

  btnShowFind.Flat := True;
  btnShowFind.Hint := 'Find Text (Ctrl+F)';
  btnShowFind.ShowHint := True;
  btnShowFind.Caption := '';
  _CreateButtonGlyph(btnShowFind, 'find');

  // Find Panel Buttons
  btnFindNext.Flat := True;
  btnFindNext.Hint := 'Find Next (Enter)';
  btnFindNext.ShowHint := True;
  btnFindNext.Caption := '';
  _CreateButtonGlyph(btnFindNext, 'down');

  btnFindPrev.Flat := True;
  btnFindPrev.Hint := 'Find Previous (Shift+Enter)';
  btnFindPrev.ShowHint := True;
  btnFindPrev.Caption := '';
  _CreateButtonGlyph(btnFindPrev, 'up');
end;

procedure TAefosTerminalDockForm._InitComposerBar;
begin
  // Toolbar toggle (glyph, in the same style as the other buttons) — turns the AI
  // prompt bar on/off for the active terminal. One obvious click; any pane becomes
  // an "AI terminal" (no separate profile to understand). Visible by default (the
  // feature is launched — no hidden config key gates it).
  FComposerBtn := TSpeedButton.Create(Self);
  FComposerBtn.Parent := pnlToolbar;
  FComposerBtn.Align := alLeft;
  FComposerBtn.Flat := True;
  FComposerBtn.AllowAllUp := True;
  FComposerBtn.GroupIndex := 9;
  FComposerBtn.Width := 34;
  FComposerBtn.Hint := 'AI prompt bar (toggle)';
  FComposerBtn.ShowHint := True;
  FComposerBtn.Caption := '';
  FComposerBtn.OnClick := _ToggleComposerBar;
  _CreateButtonGlyph(FComposerBtn, 'ai');

  // Footer host + the WebView2 composer (the SAME composition host the welcome
  // pane already uses — no new dependency, per the maintainer). Hidden until
  // toggled. alBottom sits at the bottom of the center terminal area.
  FComposerBar := TPanel.Create(Self);
  FComposerBar.Parent := Self;
  FComposerBar.Align := alBottom;
  FComposerBar.Height := 92;
  FComposerBar.BevelOuter := bvNone;
  FComposerBar.ParentBackground := False;
  FComposerBar.StyleElements := [];
  FComposerBar.Color := $001E1E1E;
  FComposerBar.Visible := False;

  FComposerPane := TComposerWebPane.Create(Self);
  FComposerPane.Parent := FComposerBar;
  FComposerPane.Align := alClient;
  FComposerPane.OnSend := _ComposerPaneSend;
  FComposerPane.OnRequestHeight := _ComposerRequestHeight;
  FComposerPane.OnPicker := _ComposerPicker;
  FComposerPane.OnAttachOpen := _ComposerAttachOpen;
  FComposerPane.OnAttachRemove := _ComposerAttachRemove;
  FComposerPane.OnMemoryOpen := _ComposerMemoryOpen;

  // Attachment state (paperclip chips): id -> full path.
  FAttachments := TDictionary<string, string>.Create;
  FAttachSeq := 0;

  // Floating '/' picker: a CHILD control of the DockForm (parented to Self), shown
  // above the composer bar on demand. Parenting it here (not to FComposerBar) lets
  // it overlay the terminal pane above the bar via sibling z-order (BringToFront).
  FPickerForm := TComposerPickerControl.Create(Self);
  FPickerForm.Parent := Self;
  FPickerForm.OnPick := _PickerPicked;
end;

procedure TAefosTerminalDockForm._ComposerPicker(Sender: TObject;
  AAction: TComposerPickerAction; const AQuery: string);
var
  LAll, LMatch: TArray<TSlashCommand>;
  LIndex: Integer;
  LQ: string;
begin
  if not Assigned(FPickerForm) then
    Exit;
  case AAction of
    cpaFilter:
      begin
        FComposerFilter := '/' + AQuery;
        LQ := LowerCase(Trim(AQuery));
        LAll := ListSlashCommands('');
        SetLength(LMatch, 0);
        for LIndex := 0 to High(LAll) do
          if (LQ = '') or (Pos(LQ, LowerCase(LAll[LIndex].Name)) > 0) then
          begin
            SetLength(LMatch, Length(LMatch) + 1);
            LMatch[High(LMatch)] := LAll[LIndex];
          end;
        FPickerForm.SetItems(LMatch);
        // The bar's BoundsRect is in this DockForm's client coords — the same space
        // the picker (a sibling child) lives in — so the picker positions itself
        // directly above the bar with no screen<->client conversion.
        FPickerForm.ShowAbove(FComposerBar.BoundsRect);
      end;
    cpaNavDown:
      FPickerForm.MoveSel(1);
    cpaNavUp:
      FPickerForm.MoveSel(-1);
    cpaCommit:
      begin
        FPickerForm.HidePicker;
        if FPickerForm.ItemCount > 0 then
          _PickerPicked(FPickerForm, Default(TSlashCommand))  // uses selection
        else
          _InjectComposerText(FComposerFilter);               // no match: verbatim
      end;
    cpaCancel:
      FPickerForm.HidePicker;
  end;
end;

procedure TAefosTerminalDockForm._PickerPicked(Sender: TObject;
  const ACommand: TSlashCommand);
var
  LCmd: TSlashCommand;
begin
  if not (Assigned(FPickerForm) and FPickerForm.Selected(LCmd)) then
    Exit;
  FPickerForm.HidePicker;
  // Inject the EXPANDED PROMPT (body): the CLI in the pane has no slash registered.
  _InjectComposerText(SlashInjectionText(LCmd, False));
end;

procedure TAefosTerminalDockForm._InjectComposerText(const AText: string);
begin
  if Trim(AText) = '' then
    Exit;
  SendCommandToActivePane(AText);
  if Assigned(FComposerPane) then
    FComposerPane.ClearInput;
end;

procedure TAefosTerminalDockForm._ComposerRequestHeight(Sender: TObject;
  const AHeight: Integer);
const
  MIN_H = 92;   // input row + action bar (icons below)
  MAX_H = 320;  // never eat more than this of the terminal (picker caps at ~220)
var
  LWanted: Integer;
begin
  if not (Assigned(FComposerBar) and FComposerBar.Visible) then
    Exit;
  LWanted := AHeight;
  if LWanted < MIN_H then LWanted := MIN_H;
  if LWanted > MAX_H then LWanted := MAX_H;
  if FComposerBar.Height <> LWanted then
    FComposerBar.Height := LWanted;
end;

procedure TAefosTerminalDockForm._ToggleComposerBar(Sender: TObject);
begin
  if not Assigned(FComposerBar) then
    Exit;
  FComposerBar.Visible := not FComposerBar.Visible;
  if FComposerBar.Visible and Assigned(FComposerPane) then
  begin
    FComposerBar.Height := 92;  // input + action bar; the page re-reports exact px
    FComposerPane.Activate;
  end
  else if Assigned(FPickerForm) then
    FPickerForm.HidePicker;
end;

procedure TAefosTerminalDockForm._ComposerPaneSend(Sender: TObject;
  const AText: string);
var
  LText, LSend, LPath: string;
  LCmds: TArray<TSlashCommand>;
  LIndex: Integer;
  LIsSlash: Boolean;
begin
  LText := Trim(AText);
  if LText = '' then
    Exit;
  LSend := LText;
  LIsSlash := False;
  // '/name' -> inject the command's EXPANDED PROMPT (body), so the AI CLI running
  // in the pane acts on it without needing the slash registered in its own dir.
  if (Length(LText) > 1) and (LText[1] = '/') then
  begin
    LIsSlash := True;
    LCmds := ListSlashCommands('');
    for LIndex := 0 to High(LCmds) do
      if SameText(LCmds[LIndex].Trigger, LText) then
      begin
        LSend := SlashInjectionText(LCmds[LIndex], False);
        Break;
      end;
  end;
  // On a PLAIN send (not a self-contained '/command'), ride the attached file
  // paths along in the text so the CLI in the pane can read them (the PTY is
  // text-only). Then clear the chips both in Pascal state and in the webview.
  if (not LIsSlash) and Assigned(FAttachments) and (FAttachments.Count > 0) then
  begin
    LSend := LSend + sLineBreak + sLineBreak + 'Attached files:';
    for LPath in FAttachments.Values do
      LSend := LSend + sLineBreak + LPath;
    FAttachments.Clear;
    if Assigned(FComposerPane) then
      FComposerPane.SetAttachments([]);
  end;
  SendCommandToActivePane(LSend);
end;

procedure TAefosTerminalDockForm._PushComposerAttachments;
var
  LItems: TArray<TPair<string, string>>;
  LPair: TPair<string, string>;
  LCount: Integer;
begin
  if not (Assigned(FComposerPane) and Assigned(FAttachments)) then
    Exit;
  SetLength(LItems, FAttachments.Count);
  LCount := 0;
  for LPair in FAttachments do
  begin
    LItems[LCount] := TPair<string, string>.Create(LPair.Key,
      ExtractFileName(LPair.Value));
    Inc(LCount);
  end;
  FComposerPane.SetAttachments(LItems);
end;

procedure TAefosTerminalDockForm._ComposerAttachOpen(Sender: TObject);
var
  LDlg: TOpenDialog;
  LId: string;
begin
  if not Assigned(FAttachments) then
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
    begin
      Inc(FAttachSeq);
      LId := IntToStr(FAttachSeq);
      FAttachments.AddOrSetValue(LId, LDlg.FileName);
      _PushComposerAttachments;
    end;
  finally
    LDlg.Free;
  end;
end;

procedure TAefosTerminalDockForm._ComposerAttachRemove(Sender: TObject;
  const AId: string);
begin
  if not Assigned(FAttachments) then
    Exit;
  FAttachments.Remove(AId);
  _PushComposerAttachments;
end;

procedure TAefosTerminalDockForm._ComposerMemoryOpen(Sender: TObject);
begin
  // Edit the SAME global memory file the chat edits
  // (%AppData%\Roaming\Aefos\memory.md). The dialog owns the load + save.
  TComposerMemoryForm.Execute(Self);
end;

procedure TAefosTerminalDockForm._CreateButtonGlyph(AButton: TSpeedButton; const AIconType: string);
var
  LBitmap: TBitmap;
  LPenColor: TColor;
  LUseIDETheme: Boolean;
  LTheming: IOTAIDEThemingServices;
  LStyle: TCustomStyleServices;
begin
  LBitmap := TBitmap.Create;
  try
    if AIconType = 'plusChevron' then
    begin
      LBitmap.Width := 24;
      LBitmap.Height := 16;
    end
    else
    begin
      LBitmap.Width := 16;
      LBitmap.Height := 16;
    end;
    LBitmap.PixelFormat := pf32bit;
    
    // Clear with transparent Fuchsia
    LBitmap.Canvas.Brush.Color := clFuchsia;
    LBitmap.Canvas.FillRect(Rect(0, 0, LBitmap.Width, LBitmap.Height));

    LUseIDETheme := False;
    if Assigned(FThemeManager) and (FThemeManager.ActiveThemeIndex >= 0) and
       (FThemeManager.ActiveThemeIndex < FThemeManager.Themes.Count) then
      LUseIDETheme := SameText(FThemeManager.Themes[FThemeManager.ActiveThemeIndex].Name, 'Delphi IDE');

    LStyle := nil;
    if LUseIDETheme and
       Assigned(BorlandIDEServices) and
       Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
       LTheming.IDEThemingEnabled then
    begin
      LStyle := LTheming.GetIDEStyleServices;
    end;

    if Assigned(LStyle) then
      LPenColor := LStyle.GetSystemColor(clWindowText)
    else
    begin
      if _IsIDEDarkTheme then
        LPenColor := $D4D4D4 // Modern light grey (VS Code dark theme text)
      else
        LPenColor := $333333; // Modern dark grey (VS Code light theme text)
    end;
      
    LBitmap.Canvas.Pen.Color := LPenColor;
    LBitmap.Canvas.Pen.Width := 1;
    LBitmap.Canvas.Brush.Style := bsClear;
    
    if AIconType = 'plus' then
    begin
      // Thin wireframe Plus (+)
      LBitmap.Canvas.MoveTo(8, 2);
      LBitmap.Canvas.LineTo(8, 14);
      LBitmap.Canvas.MoveTo(2, 8);
      LBitmap.Canvas.LineTo(14, 8);
    end
    else if AIconType = 'plusChevron' then
    begin
      // Plus (+) sign on the left
      LBitmap.Canvas.MoveTo(6, 2);
      LBitmap.Canvas.LineTo(6, 14);
      LBitmap.Canvas.MoveTo(1, 8);
      LBitmap.Canvas.LineTo(11, 8);
      
      // Downward Chevron (v) on the right
      LBitmap.Canvas.MoveTo(16, 6);
      LBitmap.Canvas.LineTo(19, 9);
      LBitmap.Canvas.LineTo(22, 6);
    end
    else if AIconType = 'splitH' then
    begin
      // Horizontal Split [-]
      LBitmap.Canvas.Rectangle(2, 3, 14, 13);
      LBitmap.Canvas.MoveTo(2, 8);
      LBitmap.Canvas.LineTo(13, 8);
    end
    else if AIconType = 'splitV' then
    begin
      // Vertical Split [|]
      LBitmap.Canvas.Rectangle(3, 2, 13, 14);
      LBitmap.Canvas.MoveTo(8, 2);
      LBitmap.Canvas.LineTo(8, 13);
    end
    else if AIconType = 'find' then
    begin
      // Magnifying glass wireframe
      LBitmap.Canvas.Ellipse(2, 2, 11, 11);
      LBitmap.Canvas.MoveTo(9, 9);
      LBitmap.Canvas.LineTo(14, 14);
    end
    else if AIconType = 'trash' then
    begin
      // Thin wireframe Trash Can (Lixeira estilo VS Code)
      // Lid
      LBitmap.Canvas.MoveTo(2, 4);
      LBitmap.Canvas.LineTo(14, 4);
      // Handle
      LBitmap.Canvas.MoveTo(6, 4);
      LBitmap.Canvas.LineTo(6, 2);
      LBitmap.Canvas.LineTo(10, 2);
      LBitmap.Canvas.LineTo(10, 4);
      // Body
      LBitmap.Canvas.MoveTo(4, 5);
      LBitmap.Canvas.LineTo(5, 14);
      LBitmap.Canvas.LineTo(11, 14);
      LBitmap.Canvas.LineTo(12, 5);
      // Inner vertical bars
      LBitmap.Canvas.MoveTo(7, 6);
      LBitmap.Canvas.LineTo(7, 12);
      LBitmap.Canvas.MoveTo(9, 6);
      LBitmap.Canvas.LineTo(9, 12);
    end
    else if AIconType = 'pencil' then
    begin
      // Pencil / Edit icon
      LBitmap.Canvas.MoveTo(12, 2);
      LBitmap.Canvas.LineTo(14, 4);
      LBitmap.Canvas.LineTo(6, 12);
      LBitmap.Canvas.LineTo(3, 13);
      LBitmap.Canvas.LineTo(4, 10);
      LBitmap.Canvas.LineTo(12, 2);
      LBitmap.Canvas.MoveTo(4, 10);
      LBitmap.Canvas.LineTo(6, 10);
      LBitmap.Canvas.LineTo(6, 12);
    end
    else if AIconType = 'play' then
    begin
      // Play triangle wireframe
      LBitmap.Canvas.Polygon([Point(5, 3), Point(13, 8), Point(5, 13)]);
    end
    else if AIconType = 'down' then
    begin
      // Arrow/Chevron Down
      LBitmap.Canvas.MoveTo(3, 6);
      LBitmap.Canvas.LineTo(8, 11);
      LBitmap.Canvas.LineTo(13, 6);
    end
    else if AIconType = 'up' then
    begin
      // Arrow/Chevron Up
      LBitmap.Canvas.MoveTo(3, 10);
      LBitmap.Canvas.LineTo(8, 5);
      LBitmap.Canvas.LineTo(13, 10);
    end
    else if AIconType = 'snippets' then
    begin
      // Code-fragment braces { } — the universal "snippet" mark (ADR-061-01).
      // Left brace, tip pointing left.
      LBitmap.Canvas.MoveTo(6, 3);
      LBitmap.Canvas.LineTo(5, 4);
      LBitmap.Canvas.LineTo(5, 7);
      LBitmap.Canvas.LineTo(3, 8);
      LBitmap.Canvas.LineTo(5, 9);
      LBitmap.Canvas.LineTo(5, 12);
      LBitmap.Canvas.LineTo(6, 13);
      // Right brace, tip pointing right.
      LBitmap.Canvas.MoveTo(10, 3);
      LBitmap.Canvas.LineTo(11, 4);
      LBitmap.Canvas.LineTo(11, 7);
      LBitmap.Canvas.LineTo(13, 8);
      LBitmap.Canvas.LineTo(11, 9);
      LBitmap.Canvas.LineTo(11, 12);
      LBitmap.Canvas.LineTo(10, 13);
    end
    else if AIconType = 'actions' then
    begin
      // Lightning bolt — quick Actions (Action Center). Filled with the pen
      // colour so it reads as a solid mark, like the {} snippets glyph.
      LBitmap.Canvas.Brush.Style := bsSolid;
      LBitmap.Canvas.Brush.Color := LPenColor;
      LBitmap.Canvas.Polygon([Point(9, 2), Point(4, 9), Point(8, 9),
        Point(6, 14), Point(12, 7), Point(8, 7)]);
    end
    else if AIconType = 'ai' then
    begin
      // Chat bubble — the AI prompt bar. Wireframe rounded rect + a small tail,
      // matching the thin-line glyph style (plus/find/split).
      LBitmap.Canvas.Brush.Style := bsClear;
      LBitmap.Canvas.RoundRect(2, 2, 14, 11, 5, 5);
      LBitmap.Canvas.MoveTo(6, 10);
      LBitmap.Canvas.LineTo(5, 14);
      LBitmap.Canvas.LineTo(9, 10);
    end;

    LBitmap.TransparentColor := clFuchsia;
    LBitmap.Transparent := True;

    AButton.Glyph.Assign(LBitmap);
    // NOTE: Do NOT clear Caption here — a caller that needs a text label sets it
    // explicitly after this call inside _InitSpeedButtons. Blanket-clearing
    // would wipe that label every time the theme changes and it re-runs.
  finally
    LBitmap.Free;
  end;
end;

function TAefosTerminalDockForm._IsIDEDarkTheme: Boolean;
var
  LThemeServices: IOTAIDEThemingServices;
  LThemeName: string;
  LColor: Longint;
  R, G, B: Byte;
  LInt: Double;
begin
  Result := True; // Default to dark theme
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, LThemeServices) and
     LThemeServices.IDEThemingEnabled then
  begin
    LThemeName := LowerCase(LThemeServices.ActiveTheme);
    if (Pos('light', LThemeName) > 0) or
       (Pos('mountain', LThemeName) > 0) or
       (LThemeName = 'windows') or
       (LThemeName = 'campbell') then
      Result := False;
  end
  else
  begin
    // Fallback if not running inside the IDE (like in our unit tests)
    LColor := ColorToRGB(Self.Color);
    R := GetRValue(LColor);
    G := GetGValue(LColor);
    B := GetBValue(LColor);
    LInt := 0.299 * R + 0.587 * G + 0.114 * B;
    Result := LInt < 140.0;
  end;
end;

procedure TAefosTerminalDockForm._InitManagers;
begin
  FProfileManager := TProfileManager.Create;
  FThemeManager := TThemeManager.Create;
  FSnippetManager := TSnippetManager.Create;
end;

procedure TAefosTerminalDockForm._InitLayout;
begin
  // 2026-06-09: always land on the welcome/home pane on open — even when a saved
  // workspace restored terminal tabs — so the welcome is the first thing seen
  // (mirrors the chat). Restored sessions stay accessible as tabs; _OpenWelcomeTab
  // adds the welcome last and makes it the active page. Welcome tabs carry no
  // terminal view, so SaveWorkspace does not persist them (no accumulation).
  _OpenWelcomeTab;
end;

procedure TAefosTerminalDockForm._AddTerminalView(const AExecutable, AArguments,
  AStartDir: string; AParent: TWinControl = nil; const AProfileName: string = '');
var
  LView: TAefosTerminalTerminalView;
  LTarget: TWinControl;
  LClientType: TAIClientType;
  LProfile: TShellProfile;
begin
  if Assigned(AParent) then
    LTarget := AParent
  else if pgcTerminals.PageCount > 0 then
    LTarget := pgcTerminals.ActivePage
  else
    LTarget := pgcTerminals;

  LView := TAefosTerminalTerminalView.Create(Self);
  LView.Parent := LTarget;
  LView.Align := alClient;
  LView.OnFocusChanged := _OnTerminalFocus;
  LView.OnSnippetsRequest := _OnTerminalSnippetsRequest;
  LView.ApplyTheme(FThemeManager);
  
  FTerminalViews.Add(LView);
  FActivityPulse.Track(LView);
  LView.Host.OnActivity := _OnTerminalActivity;
  FFocusedView := LView;

  LView.Host.ActiveProfileName := AProfileName;

  // ESP-075 (S3): resolve the AI CLI family from the named profile so an
  // aitClaude session opens in the project root and auto-wires MCP. Unknown /
  // non-AI profiles resolve to aitNone — no behaviour change (BR2).
  LClientType := aitNone;
  LProfile := FProfileManager.FindProfileByName(AProfileName);
  if Assigned(LProfile) then
    LClientType := LProfile.AIClientType;

  // A failed shell launch (bad exe / unusable WSL distro) raises an OS error in the
  // ConPTY start. That must NEVER bubble up to the IDE — degrade gracefully: drop
  // the half-built view and tell the user, so one bad profile can't crash the host.
  try
    LView.Start(AExecutable, AArguments, AStartDir, LClientType);
  except
    on E: Exception do
    begin
      FFocusedView := nil;
      FActivityPulse.Forget(LView);
      FTerminalViews.Remove(LView);
      FreeAndNil(LView);
      MessageDlg(Format('Could not start "%s".'#10#10'%s',
        [AProfileName, E.Message]), mtError, [mbOK], 0);
    end;
  end;
end;

function TAefosTerminalDockForm._AddTerminalTab(const AName: string): TTabSheet;
var
  LName: string;
begin
  Result := TTabSheet.Create(Self);
  Result.PageControl := pgcTerminals;

  LName := AName;
  if SameText(LName, 'PowerShell') then
    LName := 'pwsh'
  else if SameText(LName, 'Command Prompt') then
    LName := 'cmd';
    
  Result.Caption := LName;
  Result.TabVisible := False; // Hide classical VCL tab headers
  pgcTerminals.ActivePage := Result;
  _SyncTerminalsList;
end;

procedure TAefosTerminalDockForm.btnActionsClick(Sender: TObject);
begin
  // Repointed (ESP-060+): the toolbar lightning button now toggles the Actions
  // EXECUTION sidebar (distinct from the snippets sidebar). The Action Center
  // (cadastro/management) stays on the New-Tab (+) menu via "Action Center...".
  FActionsSidebar.Toggle;
end;

procedure TAefosTerminalDockForm.OnActionMenuItemClick(Sender: TObject);
begin
  _RunActionById(TMenuItem(Sender).Hint);
end;

procedure TAefosTerminalDockForm._RunActionById(const AActionId: string);
begin
  // Thin shim onto the extracted TTerminalActionExecutor (DockForm split). Kept on
  // the form because the new-tab menu, both sidebars and the command palette all
  // call it; the executor loads the catalog, runs the action and owns the confirm /
  // placeholder-resolve callbacks.
  FActionExecutor.RunById(AActionId, ActiveTerminalInput);
end;

procedure TAefosTerminalDockForm.OnManageActionsClick(Sender: TObject);
begin
  ShowAefosActionCenterView;
end;

procedure TAefosTerminalDockForm.btnNewTabClick(Sender: TObject);
var
  LPoint: TPoint;
  LMenuItem, LSubMenu: TMenuItem;
  LIndex: Integer;
  LExecutable, LArguments, LStartDir, LProfileName: string;
  LTab: TTabSheet;
  LThemeSub, LDefProfileSub: TMenuItem;
begin
  // Handle headless environment (unit tests)
  if IsConsole or not Self.HandleAllocated then
  begin
    LExecutable := 'cmd.exe';
    LArguments := '';
    LStartDir := '';
    LProfileName := 'Default';

    if FProfileManager.ActiveProfileIndex >= 0 then
    begin
      LExecutable := FProfileManager.Profiles[FProfileManager.ActiveProfileIndex].Executable;
      LArguments := FProfileManager.Profiles[FProfileManager.ActiveProfileIndex].Arguments;
      LStartDir := FProfileManager.Profiles[FProfileManager.ActiveProfileIndex].StartDir;
      LProfileName := FProfileManager.Profiles[FProfileManager.ActiveProfileIndex].Name;
    end;

    LTab := _AddTerminalTab(LProfileName);
    _AddTerminalView(LExecutable, LArguments, LStartDir, LTab, LProfileName);
    _ApplyActiveTheme;
    Exit;
  end;

  if not Assigned(pmNewTab) then Exit;

  pmNewTab.Items.Clear;

  // 0. New Tab -> welcome landing pane (ESP-058 / A1).
  _AddWelcomeTabMenuItems(pmNewTab);

  // 1. Profiles (Novo Terminal)
  for LIndex := 0 to FProfileManager.Profiles.Count - 1 do
  begin
    LMenuItem := TMenuItem.Create(pmNewTab);
    LMenuItem.Caption := FProfileManager.Profiles[LIndex].Name;
    LMenuItem.Tag := LIndex;
    LMenuItem.OnClick := OnProfileMenuItemClick;
    pmNewTab.Items.Add(LMenuItem);
  end;

  // Separator
  LMenuItem := TMenuItem.Create(pmNewTab);
  LMenuItem.Caption := '-';
  pmNewTab.Items.Add(LMenuItem);

  // 2. Split Terminal Horizontally / Vertically
  LMenuItem := TMenuItem.Create(pmNewTab);
  LMenuItem.Caption := 'Split Horizontally';
  LMenuItem.OnClick := OnSplitHMenuClick;
  pmNewTab.Items.Add(LMenuItem);

  LMenuItem := TMenuItem.Create(pmNewTab);
  LMenuItem.Caption := 'Split Vertically';
  LMenuItem.OnClick := OnSplitVMenuClick;
  pmNewTab.Items.Add(LMenuItem);

  // Separator
  LMenuItem := TMenuItem.Create(pmNewTab);
  LMenuItem.Caption := '-';
  pmNewTab.Items.Add(LMenuItem);

  // 3. Snippets Submenu
  LSubMenu := TMenuItem.Create(pmNewTab);
  LSubMenu.Caption := 'Snippets';
  
  for LIndex := 0 to FSnippetManager.Snippets.Count - 1 do
  begin
    LMenuItem := TMenuItem.Create(pmNewTab);
    LMenuItem.Caption := FSnippetManager.Snippets[LIndex].Title;
    LMenuItem.Tag := LIndex;
    LMenuItem.OnClick := OnSnippetMenuItemClick;
    LSubMenu.Add(LMenuItem);
  end;

  if FSnippetManager.Snippets.Count > 0 then
  begin
    LMenuItem := TMenuItem.Create(pmNewTab);
    LMenuItem.Caption := '-';
    LSubMenu.Add(LMenuItem);
  end;

  LMenuItem := TMenuItem.Create(pmNewTab);
  LMenuItem.Caption := 'Manage Snippets...';
  LMenuItem.OnClick := OnManageSnippetsClick;
  LSubMenu.Add(LMenuItem);
  
  pmNewTab.Items.Add(LSubMenu);

  // Action Center
  LMenuItem := TMenuItem.Create(pmNewTab);
  LMenuItem.Caption := 'Action Center...';
  LMenuItem.OnClick := OnManageActionsClick;
  pmNewTab.Items.Add(LMenuItem);

  // Separator
  LMenuItem := TMenuItem.Create(pmNewTab);
  LMenuItem.Caption := '-';
  pmNewTab.Items.Add(LMenuItem);

  // 4. Settings Submenu
  LSubMenu := TMenuItem.Create(pmNewTab);
  LSubMenu.Caption := 'Settings';

  // 4.1 Themes Submenu
  LThemeSub := TMenuItem.Create(pmNewTab);
  LThemeSub.Caption := 'Color / Theme';
  for LIndex := 0 to FThemeManager.Themes.Count - 1 do
  begin
    LMenuItem := TMenuItem.Create(pmNewTab);
    LMenuItem.Caption := FThemeManager.Themes[LIndex].Name;
    LMenuItem.Tag := LIndex;
    LMenuItem.Checked := (LIndex = FThemeManager.ActiveThemeIndex);
    LMenuItem.OnClick := OnThemeMenuItemClick;
    LThemeSub.Add(LMenuItem);
  end;
  LSubMenu.Add(LThemeSub);

  // 4.2 Font option
  LMenuItem := TMenuItem.Create(pmNewTab);
  LMenuItem.Caption := 'Change Font...';
  LMenuItem.OnClick := OnFontMenuClick;
  LSubMenu.Add(LMenuItem);

  // 4.3 Default Profile Submenu
  LDefProfileSub := TMenuItem.Create(pmNewTab);
  LDefProfileSub.Caption := 'Default Profile';
  for LIndex := 0 to FProfileManager.Profiles.Count - 1 do
  begin
    LMenuItem := TMenuItem.Create(pmNewTab);
    LMenuItem.Caption := FProfileManager.Profiles[LIndex].Name;
    LMenuItem.Tag := LIndex;
    LMenuItem.Checked := (LIndex = FProfileManager.ActiveProfileIndex);
    LMenuItem.OnClick := OnDefaultProfileMenuItemClick;
    LDefProfileSub.Add(LMenuItem);
  end;
  LSubMenu.Add(LDefProfileSub);

  // 4.4 AutoSync MenuItemCheck
  LMenuItem := TMenuItem.Create(pmNewTab);
  LMenuItem.Caption := 'Auto-sync Folder';
  LMenuItem.Checked := FProfileManager.AutoSync;
  LMenuItem.OnClick := OnAutoSyncClick;
  LSubMenu.Add(LMenuItem);

  pmNewTab.Items.Add(LSubMenu);

  // Popup menu positioning below btnNewTab
  LPoint := btnNewTab.Parent.ClientToScreen(Point(btnNewTab.Left, btnNewTab.Top + btnNewTab.Height));
  // Re-apply the IDE theme so newly-created menu items are styled correctly.
  _ApplyIDETheme(Self);
  _ApplyMenuTheme(pmNewTab);
  pmNewTab.Popup(LPoint.X, LPoint.Y);
end;

function TAefosTerminalDockForm._IsViewInTab(AView: TAefosTerminalTerminalView; ATab: TTabSheet): Boolean;
var
  LControl: TControl;
begin
  Result := False;
  LControl := AView;
  while Assigned(LControl) do
  begin
    if LControl = ATab then
      Exit(True);
    LControl := LControl.Parent;
  end;
end;

procedure TAefosTerminalDockForm._CleanupContainer(AContainer: TWinControl);
var
  LSplitter: TSplitter;
  LView: TAefosTerminalTerminalView;
  LPanel: TPanel;
  LParent: TWinControl;
  LChildCount: Integer;
  LRemainingChild: TControl;
  LIndex: Integer;
  LCtrl: TControl;
begin
  if not Assigned(AContainer) then Exit;
  if not (AContainer is TPanel) then Exit;

  LParent := AContainer.Parent;

  // If this container is now completely empty (all its views were closed),
  // we can free this container itself and clean up its parent recursively!
  if AContainer.ControlCount = 0 then
  begin
    AContainer.Free;
    if Assigned(LParent) and (LParent is TPanel) then
      _CleanupContainer(LParent);
    Exit;
  end;

  _GetContainerContent(AContainer, LView, LSplitter, LPanel);

  if Assigned(LSplitter) then
  begin
    LChildCount := 0;
    LRemainingChild := nil;
    for LIndex := 0 to AContainer.ControlCount - 1 do
    begin
      LCtrl := AContainer.Controls[LIndex];
      if not (LCtrl is TSplitter) then
      begin
        Inc(LChildCount);
        LRemainingChild := LCtrl;
      end;
    end;

    // If there is only 1 child left besides the splitter, we collapse the split
    if LChildCount <= 1 then
    begin
      LSplitter.Free;
      if Assigned(LRemainingChild) then
        LRemainingChild.Align := alClient;

      // Since this container was collapsed, bubble up the cleanup to its parent
      if Assigned(LParent) and (LParent is TPanel) then
        _CleanupContainer(LParent);
    end;
  end;
end;

function TAefosTerminalDockForm._CountViewsInTab(ATab: TTabSheet): Integer;
var
  LViewItem: TAefosTerminalTerminalView;
begin
  Result := 0;
  for LViewItem in FTerminalViews do
    if _IsViewInTab(LViewItem, ATab) then
      Inc(Result);
end;

function TAefosTerminalDockForm._FindViewInTab(ATab: TTabSheet): TAefosTerminalTerminalView;
var
  LViewItem: TAefosTerminalTerminalView;
begin
  Result := nil;
  for LViewItem in FTerminalViews do
    if _IsViewInTab(LViewItem, ATab) then
      Exit(LViewItem);
end;

procedure TAefosTerminalDockForm._GetContainerContent(AContainer: TWinControl; out AView: TAefosTerminalTerminalView;
  out ASplitter: TSplitter; out APanel: TPanel);
var
  LIndex: Integer;
  LCtrl: TControl;
begin
  AView := nil;
  ASplitter := nil;
  APanel := nil;
  for LIndex := 0 to AContainer.ControlCount - 1 do
  begin
    LCtrl := AContainer.Controls[LIndex];
    if LCtrl is TAefosTerminalTerminalView then
      AView := TAefosTerminalTerminalView(LCtrl)
    else if LCtrl is TSplitter then
      ASplitter := TSplitter(LCtrl)
    else if LCtrl is TPanel then
      APanel := TPanel(LCtrl);
  end;
end;

procedure TAefosTerminalDockForm._OnTabChange(Sender: TObject);
var
  LView: TAefosTerminalTerminalView;
begin
  if Assigned(pgcTerminals.ActivePage) then
  begin
    // A welcome (host-less) tab has no terminal view: _FindViewInTab returns
    // nil and we leave FFocusedView pointing at the last real view (BR8). Only
    // adopt focus when the active tab actually hosts a terminal.
    LView := _FindViewInTab(pgcTerminals.ActivePage);
    if Assigned(LView) then
    begin
      if not IsConsole and LView.CanFocus then
        LView.SetFocus;
      FFocusedView := LView;
    end;
  end;
  if Assigned(lstTerminals) then
    lstTerminals.ItemIndex := pgcTerminals.ActivePageIndex;
  _UpdateActivePaneOutline;
end;

procedure TAefosTerminalDockForm._OnTerminalFocus(Sender: TObject);
begin
  FFocusedView := TAefosTerminalTerminalView(Sender);
  _UpdateActivePaneOutline;
end;

procedure TAefosTerminalDockForm._OnTerminalSnippetsRequest(Sender: TObject);
begin
  _ShowSnippetsPopup;
end;

function TAefosTerminalDockForm._ActivePaneIsTerminalView: Boolean;
var
  LActiveCtrl: TWinControl;
begin
  // "Active pane is a live terminal view" = a focused view with a real canvas
  // exists and the focus currently sits anywhere inside that view — the canvas
  // itself or its AI-CLI context-strip child (ESP-076). Before ESP-080 the
  // intercept required TerminalCanvas.Focused, which now reads False on AI-CLI
  // panes because the context strip can hold focus; scoping to the view (not
  // the specific child) restores the route while still passing the keystroke
  // through when a welcome/dialog/non-terminal control is focused (AC2/BR5).
  Result := False;
  if not (Assigned(FFocusedView) and Assigned(FFocusedView.TerminalCanvas)) then
    Exit;
  LActiveCtrl := Screen.ActiveControl;
  Result := Assigned(LActiveCtrl) and FFocusedView.ContainsControl(LActiveCtrl);
end;

function TAefosTerminalDockForm.IsShortCut(var AMessage: TWMKey): Boolean;
begin
  // The RAD Studio IDE binds Ctrl+C / Ctrl+V globally to Edit > Copy / Paste
  // via TApplication.IsShortCut, which runs before the focused canvas can see
  // the keystroke. When the active pane is a live terminal view, route plain
  // Ctrl+C (copy on selection, else ETX to interrupt the foreground process)
  // and Ctrl+V (paste) to the canvas and report the key handled so the IDE
  // Edit action is not dispatched (ESP-026/OP1). The routing decision lives in
  // the pure ShouldRouteShortcutToCanvas predicate (ESP-080/ADR-080-01); the
  // Shift+Insert paste fallback is untouched.
  if ShouldRouteShortcutToCanvas(AMessage.CharCode,
       GetKeyState(VK_CONTROL) < 0, GetKeyState(VK_MENU) < 0,
       GetKeyState(VK_SHIFT) < 0, _ActivePaneIsTerminalView) then
  begin
    if AMessage.CharCode = Ord('C') then
      FFocusedView.TerminalCanvas.SendCtrlC
    else
      FFocusedView.TerminalCanvas.SendCtrlV;
    Exit(True);
  end;
  Result := inherited IsShortCut(AMessage);
end;

procedure TAefosTerminalDockForm.SetParent(AParent: TWinControl);
var
  LParentForm: TCustomForm;
begin
  inherited SetParent(AParent);
  if Assigned(AParent) then
  begin
    _ApplyIDETheme(Self);

    // When hosted in a floating dock window, apply the IDE theme to the host
    // form as well. We check both the direct parent and the top-level ancestor
    // form so that every floating-window variant used by different Delphi IDE
    // versions (TFloatDockForm, TFloatWindow, etc.) is covered automatically.
    LParentForm := GetParentForm(AParent);
    if Assigned(LParentForm) and (LParentForm <> Self) then
      _ApplyIDETheme(LParentForm);

    _ApplyActiveTheme;
  end;
end;

destructor TAefosTerminalDockForm.Destroy;
var
  LView: TAefosTerminalTerminalView;
begin
  // Persist the current layout before controls begin tearing down.
  SaveWorkspace;

  if Assigned(lstTerminals) and Assigned(FOriginalListBoxWP) then
    lstTerminals.WindowProc := FOriginalListBoxWP;

  for LView in FTerminalViews do
  begin
    if Assigned(LView.Host) then
      LView.Host.OnActivity := nil;
    LView.Free;
  end;
  FTerminalViews.Free;
  FActivityPulse.Free;
  
  FProfileManager.Free;
  FThemeManager.Free;
  FSnippetManager.Free;
  FSnippetsPopup.Free;
  FActionExecutor.Free;
  FAttachments.Free;
  // Sidebar helpers (DockForm split): free the helper instances only; their controls +
  // row menus are form-owned and released by the inherited destructor, so this is not
  // teardown-order-critical. Kept beside the other helper frees.
  FActionsSidebar.Free;
  FSnippetsSidebar.Free;
  // Free the find bar before inherited: its destructor restores the pnlFind WindowProc,
  // which the inherited destructor then frees. (DFM controls are form-owned; only the
  // WindowProc-restore is order-sensitive, and this ordering honors it.)
  FFindBar.Free;
  // Release the module-scope singleton so the wizard's _OpenOrRecreatePanel
  // helper sees Assigned=False after a close-via-X teardown and materializes
  // a fresh instance on the next menu re-open (#88, ADR-054-01). Guard the
  // pointer-compare so a stale reference (e.g. wizard already swapped in a
  // replacement during teardown ordering) does not get clobbered.
  if AefosTerminalDockForm = Self then
    AefosTerminalDockForm := nil;
  inherited;
end;

procedure TAefosTerminalDockForm._ShowSnippetsPopup;
var
  LMenuItem: TMenuItem;
  LPoint: TPoint;
  LIndex: Integer;
  LActionStore: TActionStore;
  LActionCatalog: TActionCatalog;
  LAllActions: TArray<TTerminalAction>;
  LAct: TTerminalAction;
  LHeaderItem: TMenuItem;
begin
  if not Assigned(FSnippetsPopup) then
    FSnippetsPopup := TPopupMenu.Create(Self)
  else
    FSnippetsPopup.Items.Clear;

  // 1. Snippets Section Header
  LHeaderItem := TMenuItem.Create(FSnippetsPopup);
  LHeaderItem.Caption := '[ Snippets ]';
  LHeaderItem.Enabled := False;
  FSnippetsPopup.Items.Add(LHeaderItem);
    
  // 2. Populate Snippets
  for LIndex := 0 to FSnippetManager.Snippets.Count - 1 do
  begin
    LMenuItem := TMenuItem.Create(FSnippetsPopup);
    LMenuItem.Caption := '  ' + FSnippetManager.Snippets[LIndex].Title;
    LMenuItem.Tag := LIndex;
    LMenuItem.OnClick := OnSnippetMenuItemClick;
    FSnippetsPopup.Items.Add(LMenuItem);
  end;

  if FSnippetManager.Snippets.Count = 0 then
  begin
    LMenuItem := TMenuItem.Create(FSnippetsPopup);
    LMenuItem.Caption := '  (No snippets registered)';
    LMenuItem.Enabled := False;
    FSnippetsPopup.Items.Add(LMenuItem);
  end;

  // Separator
  LMenuItem := TMenuItem.Create(FSnippetsPopup);
  LMenuItem.Caption := '-';
  FSnippetsPopup.Items.Add(LMenuItem);

  // 3. Actions Section Header
  LHeaderItem := TMenuItem.Create(FSnippetsPopup);
  LHeaderItem.Caption := '[ Actions ]';
  LHeaderItem.Enabled := False;
  FSnippetsPopup.Items.Add(LHeaderItem);

  // Load Actions dynamically from disk!
  LActionStore := TActionStore.Create;
  try
    LActionCatalog := LActionStore.LoadCatalog;
    try
      LAllActions := LActionCatalog.AllActions;
      if Length(LAllActions) = 0 then
      begin
        LMenuItem := TMenuItem.Create(FSnippetsPopup);
        LMenuItem.Caption := '  (No actions registered)';
        LMenuItem.Enabled := False;
        FSnippetsPopup.Items.Add(LMenuItem);
      end
      else
      begin
        for LIndex := 0 to High(LAllActions) do
        begin
          LAct := LAllActions[LIndex];
          LMenuItem := TMenuItem.Create(FSnippetsPopup);
          LMenuItem.Caption := '  ' + LAct.Name;
          LMenuItem.Hint := LAct.Id;
          LMenuItem.OnClick := OnActionMenuItemClick;
          FSnippetsPopup.Items.Add(LMenuItem);
        end;
      end;
    finally
      LActionCatalog.Free;
    end;
  finally
    LActionStore.Free;
  end;

  // Separator
  LMenuItem := TMenuItem.Create(FSnippetsPopup);
  LMenuItem.Caption := '-';
  FSnippetsPopup.Items.Add(LMenuItem);

  // 4. Management Shortcuts
  LMenuItem := TMenuItem.Create(FSnippetsPopup);
  LMenuItem.Caption := 'Manage Snippets...';
  LMenuItem.OnClick := OnManageSnippetsClick;
  FSnippetsPopup.Items.Add(LMenuItem);

  LMenuItem := TMenuItem.Create(FSnippetsPopup);
  LMenuItem.Caption := 'Manage Actions (Action Center)...';
  LMenuItem.OnClick := OnManageActionsClick;
  FSnippetsPopup.Items.Add(LMenuItem);

  // The snippets/actions popup is now reached from the terminal context
  // (_OnTerminalSnippetsRequest) — the toolbar combobox was removed — so anchor
  // it at the cursor.
  GetCursorPos(LPoint);
  // Re-apply the IDE theme so newly-created menu items are styled correctly.
  _ApplyIDETheme(Self);
  _ApplyMenuTheme(FSnippetsPopup);
  FSnippetsPopup.Popup(LPoint.X, LPoint.Y);
end;

// ── Actions sidebar (independent panel, ESP-060+) ──────────────────────────

procedure TAefosTerminalDockForm._InitLeftSidebarHost;
begin
  // Shared LEFT host: both sidebars live here and STACK vertically (snippets on
  // top, actions below) when both are open. Re-parent the snippets panel (a DFM
  // control) into the host so the two share one left column, split horizontally.
  // The actions panel itself is built afterward by the TActionsSidebar helper.
  FLeftSidebarHost := TPanel.Create(Self);
  FLeftSidebarHost.Parent := Self;
  FLeftSidebarHost.Align := alLeft;
  FLeftSidebarHost.Left := 0;
  FLeftSidebarHost.Width := 184;
  FLeftSidebarHost.BevelOuter := bvNone;
  FLeftSidebarHost.ParentBackground := False;
  FLeftSidebarHost.ParentColor := False;
  FLeftSidebarHost.Visible := False;

  // Re-parent snippets into the host FIRST so it sits on top in the alTop stack.
  if Assigned(pnlSnippetsSidebar) then
  begin
    pnlSnippetsSidebar.Parent := FLeftSidebarHost;
    pnlSnippetsSidebar.Align := alClient;
  end;

  // Horizontal splitter between snippets (top) and actions (below).
  FSidebarVSplitter := TSplitter.Create(Self);
  FSidebarVSplitter.Parent := FLeftSidebarHost;
  FSidebarVSplitter.Align := alTop;
  FSidebarVSplitter.Height := 5;
  FSidebarVSplitter.MinSize := 60;
  FSidebarVSplitter.Visible := False;
end;

procedure TAefosTerminalDockForm._ArrangeLeftSidebars;
var
  LBoth: Boolean;
  LFitH: Integer;
begin
  if not Assigned(FLeftSidebarHost) or not Assigned(FActionsSidebar) then
    Exit;
  LBoth := FSnippetsWanted and FActionsSidebar.Wanted;

  // FIXED alignments - NEVER flipped (flipping alClient<->alTop was leaving two
  // alClient controls, so snippets filled and actions collapsed to 0). Snippets
  // ALWAYS fills (alClient); actions ALWAYS sits on top (alTop) with a GUARANTEED
  // height so it can never be starved. A huge height when actions is alone is
  // clamped by the host, so it fills. DisableAlign batches it into one re-layout.
  FLeftSidebarHost.DisableAlign;
  try
    FLeftSidebarHost.Visible := FSnippetsWanted or FActionsSidebar.Wanted;
    if Assigned(splSnippetsSidebar) then
      splSnippetsSidebar.Visible := FLeftSidebarHost.Visible;

    pnlSnippetsSidebar.Align := alClient;
    FActionsSidebar.Panel.Align := alTop;
    FActionsSidebar.Panel.Top := 0;
    pnlSnippetsSidebar.Visible := FSnippetsWanted;
    FActionsSidebar.Panel.Visible := FActionsSidebar.Wanted;

    if LBoth then
    begin
      // Size the actions panel to its CONTENT so there's no empty gap above the
      // snippets panel. The fit height comes from the helper (header + filter +
      // rows); the host-relative clamp stays here (never starve the snippets
      // panel). This both-open tweak used to live in _RebuildActionsList — all
      // left-host geometry, incl. the splitter, now belongs to this coordinator.
      LFitH := FActionsSidebar.ContentFitHeight;
      if (FLeftSidebarHost.Height > 0) and (LFitH > FLeftSidebarHost.Height - 100) then
        LFitH := FLeftSidebarHost.Height - 100;
      FActionsSidebar.Panel.Height := LFitH;
      if Assigned(FSidebarVSplitter) then
      begin
        FSidebarVSplitter.Align := alTop;
        FSidebarVSplitter.Top := FActionsSidebar.Panel.Height + 1; // sit just below actions
        FSidebarVSplitter.Visible := True;
      end;
    end
    else
    begin
      if Assigned(FSidebarVSplitter) then
        FSidebarVSplitter.Visible := False;
      if FActionsSidebar.Wanted then
        FActionsSidebar.Panel.Height := 30000; // alone: host clamps it -> actions fills
    end;
  finally
    FLeftSidebarHost.EnableAlign;
  end;
end;

procedure TAefosTerminalDockForm._ToggleSnippetsSidebar(Sender: TObject);
begin
  FSnippetsWanted := not FSnippetsWanted;
  _ArrangeLeftSidebars;
  if FSnippetsWanted then
  begin
    FSnippetsSidebar.ApplyTheme;
    FSnippetsSidebar.Rebuild;
    FSnippetsSidebar.FocusFilter;
  end;
  // Entering "both" from the snippets button must also re-fit the actions panel
  // to its content (otherwise its fixed 240px leaves the empty gap).
  if FActionsSidebar.Wanted then
    FActionsSidebar.Rebuild;
end;

function TAefosTerminalDockForm._BuildSnippetVarContext: TDictionary<string, string>;
begin
  // Thin shim: the live variable context is built by the snippets helper. Kept public
  // because external units (SnippetsForm / the snippet editor live preview) call it.
  Result := FSnippetsSidebar.BuildVarContext;
end;

procedure TAefosTerminalDockForm.UpdateSnippetScopes;
begin
  // Thin shim (public; external callers preserved): the helper re-derives the scope
  // roots from the active OTA project and refreshes the list.
  FSnippetsSidebar.UpdateScopes;
end;

procedure TAefosTerminalDockForm.OnProfileMenuItemClick(Sender: TObject);
begin
  _LaunchProfile(TMenuItem(Sender).Tag);
end;

procedure TAefosTerminalDockForm._LaunchProfile(const AProfileIndex: Integer);
var
  LProfile: TShellProfile;
  LTab: TTabSheet;
begin
  if (AProfileIndex < 0) or (AProfileIndex >= FProfileManager.Profiles.Count) then
    Exit;
  LProfile := FProfileManager.Profiles[AProfileIndex];
  LTab := _AddTerminalTab(LProfile.Name);
  _AddTerminalView(LProfile.Executable, LProfile.Arguments, LProfile.StartDir,
    LTab, LProfile.Name);
  _ApplyActiveTheme;
  SaveWorkspace;
end;

procedure TAefosTerminalDockForm._ShowCommandPalette;
var
  LEntries: TArray<TPaletteEntry>;
  LDispatch: TPaletteDispatch;

  // Per-iteration dispatch builders: each call binds its own parameter copy so
  // the closures capture the right index/id/snippet (Delphi captures loop
  // variables by reference — a maker frame avoids the last-value trap).
  function _MakeProfileDispatch(const AIndex: Integer): TPaletteDispatch;
  begin
    Result := procedure begin _LaunchProfile(AIndex); end;
  end;

  function _MakeActionDispatch(const AActionId: string): TPaletteDispatch;
  begin
    Result := procedure begin _RunActionById(AActionId); end;
  end;

  function _MakeSnippetDispatch(const ASnippet: TSnippet): TPaletteDispatch;
  begin
    Result := procedure begin FSnippetsSidebar.RunSnippet(ASnippet); end;
  end;

  // ESP-078: re-run a recent command through the input funnel (SendInput delegates
  // to WriteText, which SendCommandToActivePane drives) appending Enter (AC5).
  function _MakeHistoryDispatch(const ACommand: string): TPaletteDispatch;
  begin
    Result := procedure begin SendCommandToActivePane(ACommand); end;
  end;

  function _BuildEntries: TArray<TPaletteEntry>;
  var
    LList: TList<TPaletteEntry>;

    procedure _Add(const AId: string; const ACategory: TPaletteCategory;
      const ATitle, ASubtitle: string; const ADispatch: TPaletteDispatch);
    var
      LEntry: TPaletteEntry;
    begin
      LEntry.Command.Id := AId;
      LEntry.Command.Category := ACategory;
      LEntry.Command.Title := ATitle;
      LEntry.Command.Subtitle := ASubtitle;
      LEntry.Command.SortKey := ATitle;
      LEntry.Dispatch := ADispatch;
      LList.Add(LEntry);
    end;

  const
    // Cap the recent-command rows surfaced in the palette (ESP-078).
    HISTORY_PALETTE_LIMIT = 50;
  var
    LIndex: Integer;
    LProfile: TShellProfile;
    LSnippet: TSnippet;
    LStore: TActionStore;
    LCatalog: TActionCatalog;
    LAction: TTerminalAction;
    LRecent: TArray<string>;
  begin
    LList := TList<TPaletteEntry>.Create;
    try
      // Profiles — dispatch via the shared profile-launch path (BR1/BR2).
      for LIndex := 0 to FProfileManager.Profiles.Count - 1 do
      begin
        LProfile := FProfileManager.Profiles[LIndex];
        _Add('profile:' + IntToStr(LIndex), pcProfile, 'Open: ' + LProfile.Name,
          TWelcomeModel.ShellSummary(LProfile.Executable, LProfile.Arguments),
          _MakeProfileDispatch(LIndex));
      end;

      // Actions — loaded from disk like the actions menu; run by id (BR1/BR2).
      LStore := TActionStore.Create;
      try
        LCatalog := LStore.LoadCatalog;
        try
          for LAction in LCatalog.AllActions do
            _Add('action:' + LAction.Id, pcAction, 'Run: ' + LAction.Name,
              LAction.EffectiveCategory, _MakeActionDispatch(LAction.Id));
        finally
          LCatalog.Free;
        end;
      finally
        LStore.Free;
      end;

      // Snippets — merged across scopes; inserted via the existing resolve path.
      for LIndex := 0 to FSnippetManager.Snippets.Count - 1 do
      begin
        LSnippet := FSnippetManager.Snippets[LIndex];
        _Add('snippet:' + IntToStr(LIndex), pcSnippet, 'Insert: ' + LSnippet.Title,
          LSnippet.Command, _MakeSnippetDispatch(LSnippet));
      end;

      // Built-in window commands — each routed to its existing handler.
      _Add('builtin:split-h', pcBuiltin, 'Split Horizontally', 'Split the active pane',
        procedure begin SplitHorizontal; end);
      _Add('builtin:split-v', pcBuiltin, 'Split Vertically', 'Split the active pane',
        procedure begin SplitVertical; end);
      _Add('builtin:close-pane', pcBuiltin, 'Close Pane', 'Close the active pane',
        procedure begin CloseActivePane; end);
      _Add('builtin:close-tab', pcBuiltin, 'Close Tab', 'Close the active tab',
        procedure begin CloseActiveTab; end);
      _Add('builtin:new-tab', pcBuiltin, 'New Tab', 'Open a new terminal tab',
        procedure begin btnNewTabClick(nil); end);
      _Add('builtin:find', pcBuiltin, 'Find', 'Search in the active terminal',
        procedure begin btnShowFindClick(nil); end);
      _Add('builtin:toggle-snippets', pcBuiltin, 'Toggle Snippets Sidebar',
        'Show or hide the snippets panel',
        procedure begin _ToggleSnippetsSidebar(nil); end);

      // Recent commands — newest-first from the focused pane's history; each
      // re-runs via the input funnel (ESP-078 / ADR-078-04). Index-keyed ids
      // keep entries unique even when a command repeats non-consecutively.
      if Assigned(FFocusedView) and Assigned(FFocusedView.Host) then
      begin
        LRecent := FFocusedView.Host.RecentCommands(HISTORY_PALETTE_LIMIT);
        for LIndex := 0 to High(LRecent) do
          _Add('history:' + IntToStr(LIndex), pcHistory, LRecent[LIndex],
            'Recent command', _MakeHistoryDispatch(LRecent[LIndex]));
      end;

      Result := LList.ToArray;
    finally
      LList.Free;
    end;
  end;

begin
  LEntries := _BuildEntries;
  if TCommandPaletteView.Execute(Self, LEntries, LDispatch) and Assigned(LDispatch) then
    LDispatch()
  else if Assigned(FFocusedView) and Assigned(FFocusedView.TerminalCanvas)
          and FFocusedView.TerminalCanvas.CanFocus then
    FFocusedView.TerminalCanvas.SetFocus; // cancelled: return focus to terminal
end;

procedure TAefosTerminalDockForm._DrawActivityPulse(ACanvas: TCanvas;
  const ARect: TRect; ADotMid, AIndex: Integer);
var
  LView: TAefosTerminalTerminalView;
begin
  // Draw accent glow ring behind the dot when the tab has recent activity (ESP-059).
  LView := nil;
  if AIndex < pgcTerminals.PageCount then
    LView := _FindViewInTab(pgcTerminals.Pages[AIndex]);
  if FActivityPulse.IsActive(LView) then
  begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := TVisualTokens.Accent;
    ACanvas.Pen.Color := TVisualTokens.Accent;
    ACanvas.Ellipse(ARect.Left + 4, ADotMid - 6, ARect.Left + 16, ADotMid + 6);
  end;
end;

procedure TAefosTerminalDockForm._OnTerminalActivity(Sender: TObject);
var
  LHost: TTerminalHost;
  LView: TAefosTerminalTerminalView;
begin
  // Runs on the main thread (via Synchronize in TTerminalReaderThread.Execute).
  // Mark the tab as active and start the decay timer (ESP-059 / ADR-059-01).
  LHost := TTerminalHost(Sender);
  for LView in FTerminalViews do
  begin
    if LView.Host = LHost then
    begin
      FActivityPulse.NoteActivity(LView);
      Break;
    end;
  end;
end;

procedure TAefosTerminalDockForm._OnActivityDecayed(Sender: TObject);
begin
  // The activity pulse decayed (flags cleared) -> repaint the tab strip.
  if Assigned(lstTerminals) then
    lstTerminals.Invalidate;
end;

procedure TAefosTerminalDockForm._AddWelcomeTabMenuItems(AMenu: TPopupMenu);
var
  LMenuItem: TMenuItem;
begin
  // Opening a tab with no pre-selected profile shows the welcome cards;
  // picking a specific profile below launches directly with no interstitial (AC4).
  LMenuItem := TMenuItem.Create(AMenu);
  LMenuItem.Caption := 'New Tab';
  LMenuItem.OnClick := _OnNewWelcomeTabClick;
  AMenu.Items.Add(LMenuItem);

  LMenuItem := TMenuItem.Create(AMenu);
  LMenuItem.Caption := '-';
  AMenu.Items.Add(LMenuItem);
end;

procedure TAefosTerminalDockForm._OnNewWelcomeTabClick(Sender: TObject);
begin
  _OpenWelcomeTab;
end;

procedure TAefosTerminalDockForm._OpenWelcomeTab;

  // The already-open welcome tab (the page hosting a TWelcomeWebPane), or nil.
  function _ExistingWelcome: TTabSheet;
  var
    LP, LC: Integer;
  begin
    Result := nil;
    for LP := 0 to pgcTerminals.PageCount - 1 do
      for LC := 0 to pgcTerminals.Pages[LP].ControlCount - 1 do
        if pgcTerminals.Pages[LP].Controls[LC] is TWelcomeWebPane then
          Exit(pgcTerminals.Pages[LP]);
  end;

var
  LTab: TTabSheet;
  LPane: TWelcomeWebPane;
begin
  // Single welcome/home, always pinned at the TOP of the sidebar (PageIndex 0;
  // the list mirrors page order via _SyncTerminalsList). Reuse the existing
  // welcome tab if one is already open so it never duplicates (2026-06-09).
  LTab := _ExistingWelcome;
  if Assigned(LTab) then
  begin
    LTab.PageIndex := 0;
    pgcTerminals.ActivePage := LTab;
    _SyncTerminalsList;
    Exit;
  end;
  // Host the WebView2 welcome (logo + launch cards) instead of spawning a shell;
  // card activation later swaps it for a terminal. Labelled "Welcome" in the
  // sidebar (it is the pinned home, not a blank new tab).
  LTab := _AddTerminalTab('Welcome');
  LTab.PageIndex := 0;
  LPane := TWelcomeWebPane.Create(Self);
  LPane.Parent := LTab;
  LPane.Align := alClient;
  pgcTerminals.ActivePage := LTab;
  LPane.OnLaunchProfile := _OnWelcomeCardActivated;
  LPane.BuildFromProfiles(FProfileManager.Profiles);
  _SyncTerminalsList;
  _ApplyActiveTheme;
  SaveWorkspace;
end;

procedure TAefosTerminalDockForm._OnWelcomeCardActivated(Sender: TObject;
  const AProfileIndex: Integer);
begin
  // The click originates from a control owned by the welcome pane, so the pane
  // cannot be freed here. Defer the pane->terminal swap until the click has
  // unwound (R3). The pane pointer stays valid until WMWelcomeLaunch frees it.
  if (Sender is TWelcomeWebPane) and HandleAllocated then
    PostMessage(Handle, WM_WELCOME_LAUNCH, WPARAM(Sender), LPARAM(AProfileIndex)); // NOSONAR — Win32 only: WPARAM/LPARAM are 32-bit; pointer and Integer fit without truncation
end;

procedure TAefosTerminalDockForm.WMWelcomeLaunch(var AMessage: TMessage);
var
  LPane: TWelcomeWebPane;
  LTab: TTabSheet;
  LProfile: TShellProfile;
  LIndex: Integer;
begin
  LPane := TWelcomeWebPane(AMessage.WParam);
  LIndex := Integer(AMessage.LParam); // NOSONAR — Win32 only: LParam is 32-bit; Integer cast is lossless
  if not Assigned(LPane) or not (LPane.Parent is TTabSheet) then Exit;
  if (LIndex < 0) or (LIndex >= FProfileManager.Profiles.Count) then Exit;

  LTab := TTabSheet(LPane.Parent);
  LProfile := FProfileManager.Profiles[LIndex];

  // Swap the welcome pane for a live terminal in the same tab, launched through
  // the existing path (BR1) so it is indistinguishable from a directly-opened
  // tab. Free the pane first, then parent the terminal onto the now-empty tab.
  pgcTerminals.ActivePage := LTab;
  LPane.Free;
  LTab.Caption := LProfile.Name;
  _AddTerminalView(LProfile.Executable, LProfile.Arguments, LProfile.StartDir, LTab, LProfile.Name);
  _ApplyActiveTheme;
  _SyncTerminalsList;
  if Assigned(FFocusedView) and not IsConsole and FFocusedView.CanFocus then
    FFocusedView.SetFocus;
  SaveWorkspace;
end;

procedure TAefosTerminalDockForm.OnSplitHMenuClick(Sender: TObject);
begin
  SplitHorizontal;
end;

procedure TAefosTerminalDockForm.OnSplitVMenuClick(Sender: TObject);
begin
  SplitVertical;
end;

procedure TAefosTerminalDockForm.OnSnippetMenuItemClick(Sender: TObject);
var
  LMenuItem: TMenuItem;
  LSnippetIndex: Integer;
begin
  LMenuItem := TMenuItem(Sender);
  LSnippetIndex := LMenuItem.Tag;
  if (LSnippetIndex >= 0) and (LSnippetIndex < FSnippetManager.Snippets.Count) then
  begin
    if Assigned(FFocusedView) then
    begin
      FFocusedView.WriteText(FSnippetManager.Snippets[LSnippetIndex].Command + sLineBreak);
      // Ensure keyboard focus returns to the active Aefos Terminal!
      if FFocusedView.TerminalCanvas.CanFocus then
        FFocusedView.TerminalCanvas.SetFocus;
    end;
  end;
end;

procedure TAefosTerminalDockForm.OnManageSnippetsClick(Sender: TObject);
var
  LForm: TAefosTerminalSnippetsForm;
begin
  LForm := TAefosTerminalSnippetsForm.Create(Self, Self);
  try
    LForm.ShowModal;
  finally
    LForm.Free;
  end;
end;

procedure TAefosTerminalDockForm.OnThemeMenuItemClick(Sender: TObject);
var
  LMenuItem: TMenuItem;
  LThemeIndex: Integer;
begin
  LMenuItem := TMenuItem(Sender);
  LThemeIndex := LMenuItem.Tag;
  if (LThemeIndex >= 0) and (LThemeIndex < FThemeManager.Themes.Count) then
  begin
    FThemeManager.ActiveThemeIndex := LThemeIndex;
    FThemeManager.SaveToIni;
    _ApplyActiveTheme;
    _InitSpeedButtons; // Dynamically redraw vector icons with new theme color!
  end;
end;

procedure TAefosTerminalDockForm.OnFontMenuClick(Sender: TObject);
begin
  btnFontClick(nil);
end;

procedure TAefosTerminalDockForm.OnAutoSyncClick(Sender: TObject);
begin
  TMenuItem(Sender).Checked := not TMenuItem(Sender).Checked;
  FProfileManager.AutoSync := TMenuItem(Sender).Checked;
  FProfileManager.SaveToIni;
end;

procedure TAefosTerminalDockForm.OnDefaultProfileMenuItemClick(Sender: TObject);
var
  LMenuItem: TMenuItem;
  LProfileIndex: Integer;
begin
  LMenuItem := TMenuItem(Sender);
  LProfileIndex := LMenuItem.Tag;
  if (LProfileIndex >= 0) and (LProfileIndex < FProfileManager.Profiles.Count) then
  begin
    FProfileManager.ActiveProfileIndex := LProfileIndex;
    FProfileManager.SaveToIni;
  end;
end;

procedure TAefosTerminalDockForm.btnFontClick(Sender: TObject);
var
  LFontName: string;
  LFontSize: Integer;
begin
  LFontName := FThemeManager.FontName;
  LFontSize := FThemeManager.FontSize;
  
  if TAefosTerminalFontDialog.Execute(LFontName, LFontSize) then
  begin
    FThemeManager.FontName := LFontName;
    FThemeManager.FontSize := LFontSize;
    FThemeManager.SaveToIni;
    _ApplyActiveTheme;
  end;
end;

procedure TAefosTerminalDockForm._ApplyActiveTheme;
var
  LView: TAefosTerminalTerminalView;
  LUseIDETheme: Boolean;
  LTheming: IOTAIDEThemingServices;
  LStyle: TCustomStyleServices;
begin
  // First apply the custom VCL themes recursively to self and child controls
  ApplyAefosTerminalIDETheme(Self);

  for LView in FTerminalViews do
    LView.ApplyTheme(FThemeManager);

  // Apply sidebar theme colors using Embarcadero style services
  if Assigned(lstTerminals) then
  begin
    lstTerminals.Font.Name := 'Segoe UI';
    lstTerminals.Font.Size := 10;

    LUseIDETheme := False;
    if Assigned(FThemeManager) and (FThemeManager.ActiveThemeIndex >= 0) and
       (FThemeManager.ActiveThemeIndex < FThemeManager.Themes.Count) then
      LUseIDETheme := SameText(FThemeManager.Themes[FThemeManager.ActiveThemeIndex].Name, 'Delphi IDE');

    LStyle := nil;
    if LUseIDETheme and
       Assigned(BorlandIDEServices) and
       Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
       LTheming.IDEThemingEnabled then
    begin
      LStyle := LTheming.GetIDEStyleServices;
    end;

    if Assigned(LStyle) then
    begin
      lstTerminals.Color := LStyle.GetSystemColor(clBtnFace);
      lstTerminals.Font.Color := LStyle.GetSystemColor(clWindowText);
      if Assigned(pnlTerminalSidebar) then
        pnlTerminalSidebar.Color := LStyle.GetSystemColor(clBtnFace);
    end
    else
    begin
      if _IsIDEDarkTheme then
      begin
        lstTerminals.Color := $1E1E1E; // VS Code Dark background
        lstTerminals.Font.Color := $D4D4D4; // VS Code Dark text
        if Assigned(pnlTerminalSidebar) then
          pnlTerminalSidebar.Color := $1E1E1E;
      end
      else
      begin
        lstTerminals.Color := $F3F3F3; // VS Code Light background
        lstTerminals.Font.Color := $333333; // VS Code Light text
        if Assigned(pnlTerminalSidebar) then
          pnlTerminalSidebar.Color := $F3F3F3;
      end;
    end;
    lstTerminals.Invalidate;
  end;
  if Assigned(FSnippetsSidebar) then
    FSnippetsSidebar.ApplyTheme;
  if Assigned(FFindBar) then
    FFindBar.ApplyTheme;
end;

function TAefosTerminalDockForm._IsWelcomeTab(const AIndex: Integer): Boolean;
var
  LC: Integer;
  LTab: TTabSheet;
begin
  Result := False;
  if (AIndex < 0) or (AIndex >= pgcTerminals.PageCount) then
    Exit;
  LTab := pgcTerminals.Pages[AIndex];
  for LC := 0 to LTab.ControlCount - 1 do
    if LTab.Controls[LC] is TWelcomeWebPane then
      Exit(True);
end;

procedure TAefosTerminalDockForm._SyncTerminalsList;
var
  LIndex: Integer;
  LTab: TTabSheet;
begin
  if not Assigned(lstTerminals) then Exit;
  lstTerminals.Items.BeginUpdate;
  try
    lstTerminals.Items.Clear;
    for LIndex := 0 to pgcTerminals.PageCount - 1 do
    begin
      LTab := pgcTerminals.Pages[LIndex];
      LTab.TabVisible := False; // Hide traditional tabs vertically
      lstTerminals.Items.Add(LTab.Caption);
    end;
    
    if pgcTerminals.ActivePageIndex >= 0 then
      lstTerminals.ItemIndex := pgcTerminals.ActivePageIndex
    else
      lstTerminals.ItemIndex := -1;
  finally
    lstTerminals.Items.EndUpdate;
  end;
end;

procedure TAefosTerminalDockForm.lstTerminalsClick(Sender: TObject);
begin
  if not Assigned(lstTerminals) then Exit;
  if (lstTerminals.ItemIndex >= 0) and (lstTerminals.ItemIndex < pgcTerminals.PageCount) then
  begin
    pgcTerminals.ActivePageIndex := lstTerminals.ItemIndex;
    _OnTabChange(nil);
  end;
end;

procedure TAefosTerminalDockForm.lstTerminalsDrawItem(Control: TWinControl; Index: Integer;
  Rect: TRect; State: TOwnerDrawState);
var
  LCanvas: TCanvas;
  LBgColor, LFgColor, LIconColor: TColor;
  LText: string;
  LPromptTop: Integer;
  LActiveTheme: TTerminalTheme;
  LIsSelectedBgDark: Boolean;
  LSelectedBgRGB: DWORD;
  LSelectedBgLuminance: Double;
  LUseIDETheme: Boolean;
  LTheming: IOTAIDEThemingServices;
  LStyle: TCustomStyleServices;
  LDotMid, LSplitLeft, LSplitTop, LTrashLeft, LTrashTop: Integer;
begin
  if (Index < 0) or (Index >= lstTerminals.Count) then Exit;

  LCanvas := lstTerminals.Canvas;
  LText := lstTerminals.Items[Index];

  // Load the active terminal theme
  if Assigned(FThemeManager) and (FThemeManager.ActiveThemeIndex >= 0) and
     (FThemeManager.ActiveThemeIndex < FThemeManager.Themes.Count) then
    LActiveTheme := FThemeManager.Themes[FThemeManager.ActiveThemeIndex]
  else
    LActiveTheme := FThemeManager.Themes[0];

  // Resolve theme colors
  LUseIDETheme := SameText(LActiveTheme.Name, 'Delphi IDE');
  LStyle := nil;
  if LUseIDETheme and
     Assigned(BorlandIDEServices) and
     Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
     LTheming.IDEThemingEnabled then
  begin
    LStyle := LTheming.GetIDEStyleServices;
  end;

  if Assigned(LStyle) then
  begin
    LBgColor := LStyle.GetSystemColor(clBtnFace);
    LFgColor := LStyle.GetSystemColor(clWindowText);
    LIconColor := LFgColor;
    if odSelected in State then
    begin
      // Selected background exactly matches the active terminal background color!
      LBgColor := LActiveTheme.Background;
      LFgColor := LActiveTheme.Foreground;
      LIconColor := LActiveTheme.Foreground;
    end;
  end
  else
  begin
    if _IsIDEDarkTheme then
    begin
      LBgColor := $1E1E1E;
      LFgColor := $D4D4D4;
      LIconColor := $D4D4D4;
      if odSelected in State then
      begin
        // Selected background exactly matches the active terminal background color!
        LBgColor := LActiveTheme.Background;
        LFgColor := LActiveTheme.Foreground;
        LIconColor := LActiveTheme.Foreground;
      end;
    end
    else
    begin
      LBgColor := $F3F3F3;
      LFgColor := $333333;
      LIconColor := $333333;
      if odSelected in State then
      begin
        // Selected background exactly matches the active terminal background color!
        LBgColor := LActiveTheme.Background;
        LFgColor := LActiveTheme.Foreground;
        LIconColor := LActiveTheme.Foreground;
      end;
    end;
  end;

  // Calculate dynamic selected background luminance for perfect button hover highlights!
  LSelectedBgRGB := ColorToRGB(LBgColor);
  LSelectedBgLuminance := 0.299 * GetRValue(LSelectedBgRGB) + 0.587 * GetGValue(LSelectedBgRGB) + 0.114 * GetBValue(LSelectedBgRGB);
  LIsSelectedBgDark := LSelectedBgLuminance < 140.0;

  // 1. Draw Background
  LCanvas.Brush.Color := LBgColor;
  LCanvas.FillRect(Rect);

  // 1b. Orange active accent bar on the selected (active) tab (ESP-057 /
  // ADR-057-02 — the "active underline" rendered as a left edge marker on the
  // vertical tab strip). Accent comes from VisualTokens.
  if odSelected in State then
  begin
    LCanvas.Brush.Style := bsSolid;
    LCanvas.Brush.Color := TVisualTokens.Accent;
    LCanvas.FillRect(System.Types.Rect(Rect.Left, Rect.Top, Rect.Left + 3, Rect.Bottom));
  end;

  // 1c. Shell-color dot per tab, keyed on the profile name (= tab caption).
  LDotMid := Rect.Top + Rect.Height div 2;

  // 1c'. Activity pulse ring (ESP-059).
  _DrawActivityPulse(LCanvas, Rect, LDotMid, Index);

  LCanvas.Brush.Style := bsSolid;
  LCanvas.Brush.Color := TVisualTokens.ProfileDotColor(LText);
  LCanvas.Pen.Color := LCanvas.Brush.Color;
  LCanvas.Ellipse(Rect.Left + 6, LDotMid - 4, Rect.Left + 14, LDotMid + 4);

  // 2. Draw Vector Terminal Icon (shifted right to clear the dot)
  LCanvas.Pen.Color := LIconColor;
  LCanvas.Pen.Width := 1;
  LCanvas.Brush.Style := bsClear;

  // Draw outline box (14 x 10)
  LPromptTop := Rect.Top + (Rect.Height - 10) div 2;
  LCanvas.Rectangle(Rect.Left + 18, LPromptTop, Rect.Left + 32, LPromptTop + 11);

  // Draw terminal prompt ">"
  LCanvas.MoveTo(Rect.Left + 21, LPromptTop + 3);
  LCanvas.LineTo(Rect.Left + 24, LPromptTop + 5);
  LCanvas.LineTo(Rect.Left + 21, LPromptTop + 7);

  // Draw cursor prompt "_"
  LCanvas.MoveTo(Rect.Left + 25, LPromptTop + 7);
  LCanvas.LineTo(Rect.Left + 28, LPromptTop + 7);

  // 3. Draw Text
  LCanvas.Font.Name := 'Segoe UI';
  LCanvas.Font.Size := 9;
  LCanvas.Font.Color := LFgColor;
  LCanvas.Font.Style := [];
  LCanvas.Brush.Style := bsClear;
  LCanvas.TextOut(Rect.Left + 36, Rect.Top + (Rect.Height - LCanvas.TextHeight(LText)) div 2, LText);

  // 4. Draw Inline Icons on the right side if selected/active — but never on
  // the welcome/home tab (it stays intact: no split/close).
  if (odSelected in State) and not _IsWelcomeTab(Index) then
  begin
    // Split vertical icon at Rect.Right - 38
    LSplitLeft := Rect.Right - 38;
    LSplitTop := Rect.Top + (Rect.Height - 12) div 2;

    // Draw button hover effect if split is hovered
    if (Index = FHoveredItemIndex) and (FHoveredAction = 1) then
    begin
      LCanvas.Brush.Style := bsSolid;
      if LIsSelectedBgDark then
        LCanvas.Brush.Color := $3A3A3A
      else
        LCanvas.Brush.Color := $D0D0D0;
      LCanvas.FillRect(System.Types.Rect(LSplitLeft - 2, LSplitTop - 2, LSplitLeft + 14, LSplitTop + 14));
      LCanvas.Brush.Style := bsClear;
    end;

    LCanvas.Rectangle(LSplitLeft, LSplitTop, LSplitLeft + 12, LSplitTop + 12);
    LCanvas.MoveTo(LSplitLeft + 6, LSplitTop);
    LCanvas.LineTo(LSplitLeft + 6, LSplitTop + 12);

    // Trash can / Close icon at Rect.Right - 18
    LTrashLeft := Rect.Right - 18;
    LTrashTop := Rect.Top + (Rect.Height - 12) div 2;

    // Draw button hover effect if trash is hovered
    if (Index = FHoveredItemIndex) and (FHoveredAction = 2) then
    begin
      LCanvas.Brush.Style := bsSolid;
      if LIsSelectedBgDark then
        LCanvas.Brush.Color := $3A3A3A
      else
        LCanvas.Brush.Color := $D0D0D0;
      LCanvas.FillRect(System.Types.Rect(LTrashLeft - 2, LTrashTop - 2, LTrashLeft + 14, LTrashTop + 14));
      LCanvas.Brush.Style := bsClear;
    end;

    // Lid
    LCanvas.MoveTo(LTrashLeft, LTrashTop + 2);
    LCanvas.LineTo(LTrashLeft + 12, LTrashTop + 2);
    // Body
    LCanvas.Rectangle(LTrashLeft + 2, LTrashTop + 3, LTrashLeft + 10, LTrashTop + 12);
    // Handle
    LCanvas.MoveTo(LTrashLeft + 4, LTrashTop + 2);
    LCanvas.LineTo(LTrashLeft + 4, LTrashTop);
    LCanvas.LineTo(LTrashLeft + 8, LTrashTop);
    LCanvas.LineTo(LTrashLeft + 8, LTrashTop + 2);
  end;
end;

procedure TAefosTerminalDockForm.lstTerminalsMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  LIndex: Integer;
  LPoint: TPoint;
begin
  if Button = mbLeft then
  begin
    LPoint := Point(X, Y);
    LIndex := lstTerminals.ItemAtPos(LPoint, True);
    if (LIndex >= 0) and (LIndex = lstTerminals.ItemIndex) and
       not _IsWelcomeTab(LIndex) then
    begin
      // Trash can clicked? (far right 24 pixels)
      if X >= lstTerminals.ClientWidth - 24 then
      begin
        CloseActiveTab;
        Exit;
      end;
      // Split clicked? (pixels 25 to 44 from right)
      if (X >= lstTerminals.ClientWidth - 44) and (X < lstTerminals.ClientWidth - 24) then
      begin
        SplitVertical;
        Exit;
      end;
    end;
  end;
end;

procedure TAefosTerminalDockForm.lstTerminalsMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  LIndex, LAction: Integer;
  LPoint: TPoint;
begin
  if not Assigned(lstTerminals) then Exit;

  LPoint := Point(X, Y);
  LIndex := lstTerminals.ItemAtPos(LPoint, True);
  LAction := 0; // none

  if (LIndex >= 0) and (LIndex = lstTerminals.ItemIndex) and
     not _IsWelcomeTab(LIndex) then
  begin
    if X >= lstTerminals.ClientWidth - 24 then
      LAction := 2 // trash
    else if (X >= lstTerminals.ClientWidth - 44) and (X < lstTerminals.ClientWidth - 24) then
      LAction := 1; // split
  end;

  if (LIndex <> FHoveredItemIndex) or (LAction <> FHoveredAction) then
  begin
    FHoveredItemIndex := LIndex;
    FHoveredAction := LAction;
    
    // Change cursor to handpoint when hovering over action buttons!
    if FHoveredAction <> 0 then
      lstTerminals.Cursor := crHandPoint
    else
      lstTerminals.Cursor := crDefault;

    // Repaint ListBox to refresh hover highlight immediately!
    lstTerminals.Invalidate;
  end;
end;

procedure TAefosTerminalDockForm.ListBoxSubclassWP(var Message: TMessage);
begin
  if Message.Msg = CM_MOUSELEAVE then
  begin
    if (FHoveredItemIndex <> -1) or (FHoveredAction <> 0) then
    begin
      FHoveredItemIndex := -1;
      FHoveredAction := 0;
      if Assigned(lstTerminals) then
      begin
        lstTerminals.Cursor := crDefault;
        lstTerminals.Invalidate;
      end;
    end;
  end;
  if Assigned(FOriginalListBoxWP) then
    FOriginalListBoxWP(Message);
end;

procedure TAefosTerminalDockForm.btnSplitHClick(Sender: TObject);
begin
  SplitHorizontal;
end;

procedure TAefosTerminalDockForm.btnSplitVClick(Sender: TObject);
begin
  SplitVertical;
end;

procedure TAefosTerminalDockForm.SplitHorizontal;
begin
  _DoSplit(alTop);
end;

procedure TAefosTerminalDockForm.SplitVertical;
begin
  _DoSplit(alLeft);
end;

procedure TAefosTerminalDockForm._DoSplit(AAlign: TAlign);
var
  LParent: TWinControl;
  LOldAlign: TAlign;
  LContainer: TPanel;
  LSplitter: TSplitter;
  LProfile: TShellProfile;
  LSplitWidth, LSplitHeight: Integer;
  LHeight, LWidth: Integer;
begin
  if not Assigned(FFocusedView) then Exit;

  // Use the focused pane's own profile so duplicating a cmd pane spawns cmd,
  // not whatever the global ActiveProfileIndex happens to point to.
  LProfile := FProfileManager.FindProfileByName(FFocusedView.Host.ActiveProfileName);
  if not Assigned(LProfile) then
  begin
    if FProfileManager.ActiveProfileIndex < 0 then Exit;
    LProfile := FProfileManager.Profiles[FProfileManager.ActiveProfileIndex];
  end;

  // Capture actual visible dimensions prior to reparenting
  LSplitWidth := FFocusedView.Width;
  LSplitHeight := FFocusedView.Height;

  LParent := FFocusedView.Parent;
  LOldAlign := FFocusedView.Align;
  
  // Disable alignment during dynamic hierarchy changes to prevent intermediate sizing errors
  LParent.DisableAlign;
  try
    LContainer := _CreatePanel(LParent);
    LContainer.Align := LOldAlign;
    
    FFocusedView.Parent := LContainer;
    FFocusedView.Align := AAlign;
    if AAlign = alTop then
    begin
      LHeight := LSplitHeight div 2;
      if LHeight < 30 then LHeight := 30; // Prevent collapsing below splitter MinSize
      FFocusedView.Height := LHeight;
      FFocusedView.Top := 0; // Force spatial position to outermost top
    end
    else
    begin
      LWidth := LSplitWidth div 2;
      if LWidth < 30 then LWidth := 30; // Prevent collapsing below splitter MinSize
      FFocusedView.Width := LWidth;
      FFocusedView.Left := 0; // Force spatial position to outermost left
    end;
      
    LSplitter := _CreateSplitter(LContainer);
    if AAlign = alTop then
      LSplitter.Top := FFocusedView.Height + 10 // Position physically below FFocusedView
    else
      LSplitter.Left := FFocusedView.Width + 10; // Position physically to the right of FFocusedView
    LSplitter.Align := AAlign;
    
    _AddTerminalView(LProfile.Executable, LProfile.Arguments, LProfile.StartDir, LContainer, LProfile.Name);
    // Redundant align ensuring the newly created and active FFocusedView remains alClient
    FFocusedView.Align := alClient;
  finally
    LParent.EnableAlign;
  end;
  SaveWorkspace;
  _UpdateActivePaneOutline;
end;

function TAefosTerminalDockForm.AutoSync: Boolean;
begin
  Result := FProfileManager.AutoSync;
end;

procedure TAefosTerminalDockForm.btnClosePaneClick(Sender: TObject);
begin
  CloseActivePane;
end;

// The find-bar handlers below are thin published forwarders: the .dfm reader resolves
// them by MethodAddress, so they MUST stay published on the form, but their logic moved
// into TFindBar (FFindBar). _UpdateFindCounter / _AnchorFindOverlay / _ApplyFindOverlayTheme
// / FindSubclassWP moved wholesale into the helper (AnchorOverlay / ApplyTheme are public).
procedure TAefosTerminalDockForm.btnShowFindClick(Sender: TObject);
begin
  FFindBar.ShowFind(Sender);
end;

procedure TAefosTerminalDockForm.edtFindChange(Sender: TObject);
begin
  FFindBar.FindChanged;
end;

procedure TAefosTerminalDockForm.btnFindNextClick(Sender: TObject);
begin
  FFindBar.FindNext;
end;

procedure TAefosTerminalDockForm.btnFindPrevClick(Sender: TObject);
begin
  FFindBar.FindPrev;
end;

procedure TAefosTerminalDockForm._UpdateActivePaneOutline;
var
  LCount: Integer;
  LShow: Boolean;
  LView: TAefosTerminalTerminalView;
begin
  if not Assigned(pgcTerminals) or not Assigned(pgcTerminals.ActivePage) then
    Exit;
  LCount := _CountViewsInTab(pgcTerminals.ActivePage);
  LShow := ShouldDrawActivePaneOutline(LCount);
  for LView in FTerminalViews do
  begin
    if _IsViewInTab(LView, pgcTerminals.ActivePage) then
      LView.ActiveOutline := LShow and (LView = FFocusedView)
    else
      LView.ActiveOutline := False;
  end;
end;

procedure TAefosTerminalDockForm.Resize;
begin
  inherited;
  // Keep the floating find overlay pinned to the terminal area's top-right as
  // the form grows/shrinks (R2 / AC7).
  if Assigned(pnlFind) and pnlFind.Visible and Assigned(FFindBar) then
    FFindBar.AnchorOverlay;
end;

// Published forwarder (DFM-wired edtFind.OnKeyDown, resolved by MethodAddress).
procedure TAefosTerminalDockForm.edtFindKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  FFindBar.KeyDown(Key, Shift);
end;

procedure TAefosTerminalDockForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  // Ctrl+P — command palette (ESP-062 / ADR-062-04). Dock-form-scoped via
  // KeyPreview; Ctrl+P is free of RESERVED_SHORTCUTS (ADR-062-04 / A1).
  if (Key = Ord('P')) and (ssCtrl in Shift) and
     not (ssShift in Shift) and not (ssAlt in Shift) then
  begin
    _ShowCommandPalette;
    Key := 0;
    Exit;
  end;

  if (Key = Ord('F')) and (ssCtrl in Shift) then
  begin
    FFindBar.HandleShortcuts(Key, Shift);
    Exit;
  end;

  if (Key = VK_F3) then
  begin
    FFindBar.HandleShortcuts(Key, Shift);
    Exit;
  end;

  if (ssCtrl in Shift) then
    _HandleTabShortcuts(Key, Shift);
end;

procedure TAefosTerminalDockForm._HandleTabShortcuts(var Key: Word; Shift: TShiftState);
begin
  case Key of
    Ord('T'):
    begin
      btnNewTabClick(nil);
      Key := 0;
    end;
    Ord('W'):
    begin
      CloseActiveTab;
      Key := 0;
    end;
    Ord('A'):
      if ssShift in Shift then
      begin
        ToggleActionCenterView;
        Key := 0;
      end;
    VK_TAB:
    begin
      pgcTerminals.SelectNextPage(not (ssShift in Shift));
      Key := 0;
    end;
  end;
end;

procedure TAefosTerminalDockForm.CloseActiveTab;
var
  LPage: TTabSheet;
begin
  if pgcTerminals.PageCount > 0 then
  begin
    LPage := pgcTerminals.ActivePage;
    _TerminateViewsInTab(LPage);
    LPage.Free;
    
    if FTerminalViews.Count > 0 then
      FFocusedView := FTerminalViews[FTerminalViews.Count - 1]
    else
      FFocusedView := nil;

    if pgcTerminals.PageCount = 0 then
      btnNewTabClick(nil)
    else
      _SyncTerminalsList;

    SaveWorkspace;
  end;
end;

procedure TAefosTerminalDockForm.CloseActivePane;
begin
  if not Assigned(FFocusedView) then Exit;

  if _ShouldCloseActiveTab then
    CloseActiveTab
  else
  begin
    _DoCloseActivePane;
    SaveWorkspace;
  end;
end;

procedure TAefosTerminalDockForm.SendCommandToActivePane(const ACommand: string);
begin
  if not Assigned(FFocusedView) then Exit;
  FFocusedView.WriteText(ACommand + sLineBreak);
end;

function TAefosTerminalDockForm.ActiveTerminalInput: ITerminalInput;
begin
  Result := nil;
  if Assigned(FFocusedView) and Assigned(FFocusedView.Host) then
    Result := FFocusedView.Host as ITerminalInput;
end;

function TAefosTerminalDockForm._ShouldCloseActiveTab: Boolean;
begin
  Result := _CountViewsInTab(pgcTerminals.ActivePage) <= 1;
end;

procedure TAefosTerminalDockForm._DoCloseActivePane;
var
  LView: TAefosTerminalTerminalView;
  LParent: TWinControl;
  LTab: TTabSheet;
begin
  LView := FFocusedView;
  LParent := TWinControl(LView.Parent);
  LTab := pgcTerminals.ActivePage;
  
  LView.Stop;
  LView.Host.OnActivity := nil;
  FActivityPulse.Forget(LView);
  FTerminalViews.Remove(LView);
  LView.Free;

  _UpdateAfterPaneClose(LTab);

  if Assigned(LParent) then
    _CleanupContainer(LParent);

  // _CleanupContainer only touches the closed pane's immediate container, so
  // collapsing toward a single pane leaves stale half-aligned panels and
  // splitters from the outer splits — the surviving view stays trapped at a
  // fraction of the tab. When the tab is back to one view, flatten it.
  if _CountViewsInTab(LTab) = 1 then
    _FlattenTabToSingleView(LTab);
  _UpdateActivePaneOutline;
end;

procedure TAefosTerminalDockForm._FlattenTabToSingleView(const ATab: TTabSheet);
var
  LView: TAefosTerminalTerminalView;
  LIndex: Integer;
begin
  LView := _FindViewInTab(ATab);
  if not Assigned(LView) then
    Exit;
  // Reparent the survivor straight onto the tab, then discard every leftover
  // split panel/splitter. Moving the view out first keeps it clear of the
  // recursive free. alClient on the full tab triggers the canvas Resize ->
  // _ApplyGeometry, so the buffer and pseudoconsole reflow to the real size.
  LView.Parent := ATab;
  LView.Align := alClient;
  for LIndex := ATab.ControlCount - 1 downto 0 do
    if ATab.Controls[LIndex] <> LView then
      ATab.Controls[LIndex].Free;
end;

procedure TAefosTerminalDockForm._UpdateAfterPaneClose(ALastTab: TTabSheet);
begin
  FFocusedView := _FindViewInTab(ALastTab);
  if Assigned(FFocusedView) and FFocusedView.CanFocus then
    FFocusedView.SetFocus;
end;

procedure TAefosTerminalDockForm._TerminateViewsInTab(ATab: TTabSheet);
var
  LViewsToRemove: TList<TAefosTerminalTerminalView>;
  LViewItem: TAefosTerminalTerminalView;
  LView: TAefosTerminalTerminalView;
begin
  // Tolerates a welcome (host-less) tab: it owns no TAefosTerminalTerminalView, so
  // the loop finds nothing and the caller frees the TWelcomePane with the tab
  // (BR8). No terminal host is assumed.
  LViewsToRemove := TList<TAefosTerminalTerminalView>.Create;
  try
    for LViewItem in FTerminalViews do
      if _IsViewInTab(LViewItem, ATab) then
        LViewsToRemove.Add(LViewItem);

    for LView in LViewsToRemove do
    begin
      LView.Stop;
      LView.Host.OnActivity := nil;
      FActivityPulse.Forget(LView);
      FTerminalViews.Remove(LView);
      LView.Free;
    end;
  finally
    LViewsToRemove.Free;
  end;
end;

procedure TAefosTerminalDockForm.SaveWorkspace;
var
  LWorkspace: TWorkspaceLayout;
  LTab: TTabLayout;
  LIndex: Integer;
  LRoot: TLayoutNode;
begin
  LWorkspace := TWorkspaceLayout.Create;
  try
    if Assigned(pgcTerminals) and not IsConsole then
    begin
      LWorkspace.ActiveTabIndex := pgcTerminals.ActivePageIndex;
      for LIndex := 0 to pgcTerminals.PageCount - 1 do
      begin
        // Skip the welcome/home tab and any empty husk: they own no terminal
        // view, so _ExportNode yields nil. Persisting them is what made stray
        // "New Tab" rows pile up across restarts; the welcome is recreated fresh
        // on open by _InitLayout anyway (2026-06-09).
        LRoot := _ExportNode(pgcTerminals.Pages[LIndex]);
        if not Assigned(LRoot) then
          Continue;
        LTab := TTabLayout.Create;
        LTab.Caption := pgcTerminals.Pages[LIndex].Caption;
        LTab.Root := LRoot;
        LWorkspace.Tabs.Add(LTab);
      end;
    end;
    _SaveActionCenterState(LWorkspace);
    TLayoutManager.Save(LWorkspace);
  finally
    LWorkspace.Free;
  end;
end;

procedure TAefosTerminalDockForm._SaveActionCenterState(AWorkspace: TWorkspaceLayout);
begin
  if not Assigned(AefosActionCenterView) or IsConsole then
    Exit;
  AWorkspace.ActionCenterVisible := AefosActionCenterView.Visible;
  AWorkspace.ActionCenterLeft := AefosActionCenterView.Left;
  AWorkspace.ActionCenterTop := AefosActionCenterView.Top;
  AWorkspace.ActionCenterWidth := AefosActionCenterView.Width;
  AWorkspace.ActionCenterHeight := AefosActionCenterView.Height;
end;

procedure TAefosTerminalDockForm._RestoreActionCenterState(AWorkspace: TWorkspaceLayout);
begin
  if IsConsole or not AWorkspace.ActionCenterVisible then
    Exit;
  ShowAefosActionCenterView;
  if Assigned(AefosActionCenterView) and (AWorkspace.ActionCenterWidth > 0) then
    AefosActionCenterView.SetBounds(AWorkspace.ActionCenterLeft,
      AWorkspace.ActionCenterTop, AWorkspace.ActionCenterWidth,
      AWorkspace.ActionCenterHeight);
end;

procedure TAefosTerminalDockForm._OpenDefaultPane;
var
  LExe, LArgs, LDir, LName: string;
  LTab: TTabSheet;
begin
  LExe  := 'cmd.exe';
  LArgs := '';
  LDir  := '';
  LName := 'cmd';
  if FProfileManager.ActiveProfileIndex >= 0 then
  begin
    LExe  := FProfileManager.Profiles[FProfileManager.ActiveProfileIndex].Executable;
    LArgs := FProfileManager.Profiles[FProfileManager.ActiveProfileIndex].Arguments;
    LDir  := FProfileManager.Profiles[FProfileManager.ActiveProfileIndex].StartDir;
    LName := FProfileManager.Profiles[FProfileManager.ActiveProfileIndex].Name;
  end;
  LTab := _AddTerminalTab(LName);
  _AddTerminalView(LExe, LArgs, LDir, LTab, LName);
end;

procedure TAefosTerminalDockForm.LoadWorkspace;
var
  LWorkspace: TWorkspaceLayout;
  LViewsBefore: Integer;
  LTabItem: TTabLayout;
  LTab: TTabSheet;
  LFallback, LAP: TShellProfile;
begin
  LWorkspace := TLayoutManager.Load;
  if LWorkspace = nil then
    Exit;
  try
    for LTabItem in LWorkspace.Tabs do
    begin
      LViewsBefore := FTerminalViews.Count;
      LTab := _AddTerminalTab(LTabItem.Caption);
      _ImportNode(LTabItem.Root, LTab);
      // Corrupted node: tab was added but no view materialised inside it.
      // Try to open the shell that matches the tab caption; fall back to the
      // active profile, then to cmd.exe as last resort.
      if FTerminalViews.Count = LViewsBefore then
      begin
        LFallback := FProfileManager.FindProfileByName(LTabItem.Caption);
        if Assigned(LFallback) then
          _AddTerminalView(LFallback.Executable, LFallback.Arguments, LFallback.StartDir, LTab, LFallback.Name)
        else if FProfileManager.ActiveProfileIndex >= 0 then
        begin
          LAP := FProfileManager.Profiles[FProfileManager.ActiveProfileIndex];
          _AddTerminalView(LAP.Executable, LAP.Arguments, LAP.StartDir, LTab, LAP.Name);
        end
        else
          _AddTerminalView('cmd.exe', '', '', LTab, 'cmd');
      end;
    end;

    if (LWorkspace.ActiveTabIndex >= 0) and (LWorkspace.ActiveTabIndex < pgcTerminals.PageCount) then
      pgcTerminals.ActivePageIndex := LWorkspace.ActiveTabIndex;

    _RestoreActionCenterState(LWorkspace);
  finally
    LWorkspace.Free;
  end;

  // Final safety net: entire layout was empty or all nodes were corrupt.
  if FTerminalViews.Count = 0 then
    _OpenDefaultPane;
end;

function TAefosTerminalDockForm._ExportNode(AContainer: TWinControl): TLayoutNode;
var
  LView: TAefosTerminalTerminalView;
  LPanel: TPanel;
  LSplitter: TSplitter;
begin
  Result := nil;
  if not Assigned(AContainer) then Exit;

  // _GetControlByAlign can return the TAefosTerminalTerminalView itself (not a
  // wrapper container). Detect it directly so we do not scan its internals.
  if AContainer is TAefosTerminalTerminalView then
    Exit(_DoExportView(TAefosTerminalTerminalView(AContainer)));

  _GetContainerContent(AContainer, LView, LSplitter, LPanel);

  if Assigned(LSplitter) then
    Result := _DoExportSplit(AContainer, LSplitter)
  else if Assigned(LView) then
    Result := _DoExportView(LView)
  else if Assigned(LPanel) then
    Result := _ExportNode(LPanel);
end;

function TAefosTerminalDockForm._DoExportSplit(AContainer: TWinControl; ASplitter: TSplitter): TLayoutNode;
begin
  Result := TLayoutNode.Create;
  _ExportSplitNode(Result, AContainer, ASplitter);
end;

function TAefosTerminalDockForm._DoExportView(AView: TAefosTerminalTerminalView): TLayoutNode;
begin
  Result := TLayoutNode.Create;
  _ExportViewNode(Result, AView);
end;

procedure TAefosTerminalDockForm._ExportSplitNode(ANode: TLayoutNode; AContainer: TWinControl; 
  ASplitter: TSplitter);
begin
  ANode.NodeType := lntSplit;
  ANode.Orientation := _GetSplitOrientation(ASplitter);
  ANode.SplitPercent := _GetSplitPercent(AContainer, ASplitter, ANode.Orientation);

  ANode.Child1 := _ExportNode(_GetControlByAlign(AContainer, ASplitter.Align, ASplitter));
  ANode.Child2 := _ExportNode(_GetControlByAlign(AContainer, alClient, ASplitter));
end;

function TAefosTerminalDockForm._GetSplitOrientation(ASplitter: TSplitter): string;
begin
  if ASplitter.Align = alLeft then
    Result := 'vertical'
  else
    Result := 'horizontal';
end;

function TAefosTerminalDockForm._GetSplitPercent(AContainer: TWinControl; 
  ASplitter: TSplitter; const AOrientation: string): Double;
begin
  if AOrientation = 'vertical' then
    Result := ASplitter.Left / (AContainer.Width + 1)
  else
    Result := ASplitter.Top / (AContainer.Height + 1);
end;

function TAefosTerminalDockForm._GetControlByAlign(AContainer: TWinControl; AAlign: TAlign;
  AExclude: TControl): TWinControl;
var
  LIndex: Integer;
  LCtrl: TControl;
begin
  Result := nil;
  for LIndex := 0 to AContainer.ControlCount - 1 do
  begin
    LCtrl := AContainer.Controls[LIndex];
    if (LCtrl is TWinControl) and (LCtrl <> AExclude) and (LCtrl.Align = AAlign) then
      Exit(TWinControl(LCtrl));
  end;
end;

procedure TAefosTerminalDockForm._ExportViewNode(ANode: TLayoutNode; AView: TAefosTerminalTerminalView);
begin
  ANode.NodeType := lntView;
  ANode.Profile := AView.Host.ActiveProfileName;
  ANode.Dir := AView.Host.LastDir;
  ANode.IsFocused := (AView = FFocusedView);
end;

procedure TAefosTerminalDockForm._ImportNode(ANode: TLayoutNode; AParent: TWinControl);
begin
  if not Assigned(ANode) then Exit;

  if ANode.NodeType = lntView then
    _ImportViewNode(ANode, AParent)
  else
    _ImportSplitNode(ANode, AParent);
end;

procedure TAefosTerminalDockForm._ImportViewNode(ANode: TLayoutNode; AParent: TWinControl);
var
  LExecutable, LArguments, LStartDir: string;
  LProfile: TShellProfile;
  LProfileName: string;
begin
  LProfileName := ANode.Profile;
  if SameText(LProfileName, 'PowerShell') then
    LProfileName := 'pwsh'
  else if SameText(LProfileName, 'Command Prompt') then
    LProfileName := 'cmd';

  LProfile := FProfileManager.FindProfileByName(LProfileName);
  if Assigned(LProfile) then
  begin
    LExecutable := LProfile.Executable;
    LArguments := LProfile.Arguments;
    LStartDir := ANode.Dir;
    if LStartDir = '' then LStartDir := LProfile.StartDir;
  end
  else
  begin
    LExecutable := 'cmd.exe';
    LArguments := '';
    LStartDir := ANode.Dir;
  end;

  _AddTerminalView(LExecutable, LArguments, LStartDir, AParent, LProfileName);
  // No SetFocus here: _ImportViewNode always runs from LoadWorkspace, which
  // executes in the form constructor — the form has no window handle yet, so
  // any SetFocus raises an AV (CanFocus only checks child Visible/Enabled, not
  // whether the form exists). Focused-pane restoration must be deferred to a
  // post-show step; it is intentionally not done here.
end;

procedure TAefosTerminalDockForm._ImportSplitNode(ANode: TLayoutNode; AParent: TWinControl);
var
  LChild1, LChild2: TPanel;
  LSplitter: TSplitter;
  LRemWidth, LRemHeight: Integer;
begin
  LChild1 := _CreatePanel(AParent);
  LSplitter := _CreateSplitter(AParent);
  LChild2 := _CreatePanel(AParent);
  LChild2.Align := alClient;

  _ConfigureSplitControls(ANode, AParent, LChild1, LSplitter);

  // Explicitly set dimensions on the alClient panel to ensure child nested splits
  // can compute non-zero initial percentages during layout construction
  if ANode.Orientation = 'vertical' then
  begin
    LRemWidth := AParent.Width - LChild1.Width - LSplitter.Width;
    if LRemWidth < 30 then LRemWidth := 30; // Safety constraint
    LChild2.Width := LRemWidth;
    LChild2.Height := AParent.Height;
  end
  else
  begin
    LRemHeight := AParent.Height - LChild1.Height - LSplitter.Height;
    if LRemHeight < 30 then LRemHeight := 30; // Safety constraint
    LChild2.Width := AParent.Width;
    LChild2.Height := LRemHeight;
  end;

  _ImportNode(ANode.Child1, LChild1);
  _ImportNode(ANode.Child2, LChild2);
end;

function TAefosTerminalDockForm._CreatePanel(AParent: TWinControl): TPanel;
begin
  Result := TPanel.Create(Self);
  Result.Parent := AParent;
  Result.BevelOuter := bvNone;
end;

function TAefosTerminalDockForm._CreateSplitter(AParent: TWinControl): TSplitter;
begin
  Result := TSplitter.Create(Self);
  Result.Parent := AParent;
end;

procedure TAefosTerminalDockForm._ConfigureSplitControls(ANode: TLayoutNode;
  AParent, AChild1: TWinControl; ASplitter: TSplitter);
var
  LPercent: Double;
  LWidth, LHeight: Integer;
begin
  LPercent := ANode.SplitPercent;
  if LPercent <= 0 then LPercent := 0.5;

  if ANode.Orientation = 'vertical' then
  begin
    AChild1.Align := alLeft;
    LWidth := Trunc(AParent.Width * LPercent);
    if LWidth < 30 then LWidth := 30; // Prevent collapsing below splitter MinSize
    AChild1.Width := LWidth;
    AChild1.Left := 0; // Force spatial position to outermost left
    
    ASplitter.Left := AChild1.Width + 10; // Position physically to the right of AChild1
    ASplitter.Align := alLeft;
  end
  else
  begin
    AChild1.Align := alTop;
    LHeight := Trunc(AParent.Height * LPercent);
    if LHeight < 30 then LHeight := 30; // Prevent collapsing below splitter MinSize
    AChild1.Height := LHeight;
    AChild1.Top := 0; // Force spatial position to outermost top
    
    ASplitter.Top := AChild1.Height + 10; // Position physically below AChild1
    ASplitter.Align := alTop;
  end;
end;



var
  GFontLoaded: Boolean = False;
  GFontFilePath: string = '';

procedure _LoadPrivateFont;
var
  LResStream: TResourceStream;
  LAppData: string;
  LDir: string;
  LRes: DWORD_PTR;
begin
  try
    LAppData := GetEnvironmentVariable('APPDATA');
    LDir := TPath.Combine(TPath.Combine(LAppData, 'ModernDelphiWorks'), 'Aefos.OTA.Terminal');
    if not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
      
    GFontFilePath := TPath.Combine(LDir, 'CaskaydiaCoveNerdFontMono-Regular.ttf');

    if not FileExists(GFontFilePath) or (TFile.GetSize(GFontFilePath) < 1000000) then
    begin
      try
        if FileExists(GFontFilePath) then
          TFile.Delete(GFontFilePath);
        LResStream := TResourceStream.Create(HInstance, 'AefosOTATerminal_FONT', RT_RCDATA);
        try
          LResStream.SaveToFile(GFontFilePath);
        finally
          LResStream.Free;
        end;
      except
        on E: Exception do
          OutputDebugString(PChar('[Aefos.OTA.Terminal] FontLoad-ResourceStream: ' + E.ClassName + ' - ' + E.Message));
      end;
    end;

    if FileExists(GFontFilePath) then
    begin
      if AddFontResourceEx(PChar(GFontFilePath), FR_PRIVATE, nil) > 0 then
      begin
        GFontLoaded := True;
        // After a BPL rebuild the font is removed + re-added inside the SAME
        // (IDE) process; without notifying running windows, GDI keeps the stale
        // "font not found" realization and the terminal renders tofu. Broadcast
        // WM_FONTCHANGE (timeout-guarded so a hung window can't block teardown)
        // so the re-registered Nerd Font is picked up immediately.
        SendMessageTimeout(HWND_BROADCAST, WM_FONTCHANGE, 0, 0,
          SMTO_ABORTIFHUNG, 1000, @LRes);
      end;
    end;
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos.OTA.Terminal] FontLoad-AddFontResource: ' + E.ClassName + ' - ' + E.Message));
  end;
end;

procedure _UnloadPrivateFont;
begin
  try
    if GFontLoaded and (GFontFilePath <> '') then
      RemoveFontResourceEx(PChar(GFontFilePath), FR_PRIVATE, nil);
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos.OTA.Terminal] FontUnload: ' + E.ClassName + ' - ' + E.Message));
  end;
end;

initialization
  // Register the owner-drawn toolbar panel so the DFM reader resolves the
  // pnlToolbar class at form-stream time (ESP-057 / ADR-057-02).
  RegisterClass(TAefosTerminalToolbarPanel);
  _LoadPrivateFont;
  // IDE desktop persistence (RegisterDesktopFormClass + RegisterFieldAddress)
  // DISABLED (2026-06-16): no UnregisterDesktopFormClass exists, so the class
  // dangled after a Build-All-in-IDE and the desktop-layout load AV'd on it,
  // corrupting the "Default" layout. Same root cause as the chat dock — both off.

finalization
  _UnregisterThemedFormClass;
  _UnloadPrivateFont;
  FreeAndNil(AefosTerminalDockForm);
  UnRegisterClass(TAefosTerminalToolbarPanel);

end.






