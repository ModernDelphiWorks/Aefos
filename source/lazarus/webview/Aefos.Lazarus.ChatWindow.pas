unit Aefos.Lazarus.ChatWindow;

{ TAefosLazChatWindow -- the LCL "Aefos AI Chat" window (Lazarus edition).

  A form hosting the windowed WebView2 host (TAefosLazWebView) client-aligned. It
  loads the REAL chat shell (the same HTML_SHELL Pascal-string constants the RAD
  Studio plugin ships, in Aefos.OTA.Chat.UI.OutputPanel.Assets) and drives the
  full chat loop through TAefosLazChatController: a user types, the Ollama
  transport streams a reply, and each chunk renders into the assistant bubble via
  the window.ds*() render protocol.

  DOCKABLE PANEL (this slice): the window is registered with the IDE's own
  window-creation seam (IDEWindowCreators.Add, IDEIntf), so when AnchorDocking is
  active it behaves like any native IDE tool panel -- the user docks/undocks it
  beside the editor instead of it popping as a free-floating TForm. The registered
  form Name (cAefosChatFormName) keys the IDE layout/dock persistence. Showing the
  chat routes through IDEWindowCreators.ShowForm (create-on-demand + dock); if IDE
  docking is unavailable it degrades gracefully to a plain floating Show. See
  TAefosLazChatDock below.

  Scope of the chat loop: the LOCAL-model (Ollama) path only. When the configured
  executor is an external CLI (Claude/Codex/Gemini/Copilot) the controller shows a
  friendly in-chat notice -- external-CLI dispatch is a later slice.

  Built in code (no .lfm) so the custom WebView control is not LFM-streamed. It is
  a single reusable instance; the phase-M liveness token, WebView2-loader discovery
  and shutdown teardown are unchanged. }

{$mode delphi}
{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, LCLType, LazUTF8,
  Aefos.Win.WebView2, Aefos.Lazarus.WebViewHost,
  Aefos.Lazarus.ChatController;

type
  TAefosLazChatWindow = class(TForm)
  private
    FWeb: TAefosLazWebView;
    FController: TAefosLazChatController;
    FActiveFormHooked: Boolean;
    procedure _WebFailed(const AHResult: HRESULT);
    // Wired to the controller's OnOpenSettings (the header gear / hdr:settings):
    // deep-link into Tools > Options at the Aefos AI page, the Lazarus twin of the
    // Delphi panel's OnOpenSettings -> OpenAefosOptions.
    procedure _OpenSettings;
    // Wired to the controller's OnResolveProjectRoot: the active project's folder,
    // for the user-command "This project" scope (.aefos\commands under it). '' when
    // no project is open -> a project-scoped save is rejected with an inline notice.
    function _ResolveProjectRoot: UnicodeString;
    // Screen active-form hook: an AnchorDocking undock/float turns our host site into
    // a new top-level window and activates it, but it keeps this window (and the
    // alClient WebView inside) at the same relative position -- so neither Resize nor
    // WM_WINDOWPOSCHANGED reaches the WebView, and the windowed WebView2 keeps
    // presenting into the old (now dead) parent surface (blank). This fires on that
    // activation; we defer a root-guarded re-home to the next message cycle so the
    // reparent/float has fully settled and the fresh HWND is valid.
    procedure _ActiveFormChanged(Sender: TObject; AForm: TCustomForm);
    procedure _AsyncSyncWebView(Data: PtrInt);
  protected
    procedure DoShow; override;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    destructor Destroy; override;
  end;

  { TAefosLazChatDock -- registers the chat window as a native, DOCKABLE IDE panel
    and shows/focuses it on demand. All entry points are class methods so no loose
    product routines are exported (the IDEWindowCreators create-callback itself is
    an implementation-section IDE callback, the shape IDEIntf mandates). }
  TAefosLazChatDock = class
  public
    { Registers the dockable window creator with the IDE. Call at package LOAD
      (like the menu). Idempotent + guarded: never raises, no-op when the IDE
      window seam is unavailable. }
    class procedure RegisterDockable;
    { Shows/focuses the chat: the native docked panel when the creator is
      registered (AnchorDocking docks it), else a floating fallback window. }
    class procedure Show;
    { Removes the IDE-held creator reference at teardown (IDE-unload discipline). }
    class procedure UnregisterDockable;
  end;

implementation

uses
  IDEWindowIntf,
  LazIDEIntf,          // LazarusIDE.DoOpenIDEOptions (the Options deep-link)
  ProjectIntf,         // TLazProject.ProjectInfoFile (the active project's .lpi)
  Aefos.Lazarus.Options;   // TAefosOptionsFrame (the Aefos AI options page class)

const
  { The IDE-window registration id. Must be a valid identifier: it also becomes the
    form's Name -- the key AnchorDocking and the IDE layout storage persist on. }
  cAefosChatFormName = 'AefosAIChat';

var
  GChatWindow: TAefosLazChatWindow = nil;
  GChatCreator: TIDEWindowCreator = nil;

{ The IDE window-creation callback IDEWindowCreators invokes on demand. A plain
  implementation-level procedure is the contract IDEWindowIntf requires (the same
  shape every Lazarus dockable window uses, e.g. CreateFileBrowser) -- an IDE
  callback, not loose product API. Creates the single chat window on first use and
  stamps its Name so the layout/dock persistence and Screen.FindForm reuse key on
  it. }
procedure _CreateAefosChatWindow(Sender: TObject; aFormName: string;
  var AForm: TCustomForm; DoDisableAutoSizing: Boolean);
begin
  if CompareText(aFormName, cAefosChatFormName) <> 0 then
    Exit;
  if GChatWindow = nil then
  begin
    GChatWindow := TAefosLazChatWindow.CreateNew(Application);
    GChatWindow.Name := aFormName;
  end;
  // Honor the IDEWindowIntf contract: when DoDisableAutoSizing is True the caller
  // (TIDEWindowCreatorList.GetForm / the AnchorDocking dock master) will call
  // EnableAutoSizing after we return, so the create-callback MUST hand back a form
  // whose auto-sizing is already DISABLED -- otherwise the later EnableAutoSizing is
  // unbalanced and the LCL raises "missing DisableAutoSizing" (surfaced now that the
  // AnchorDocking ShowForm path runs with DoDisableAutoSizing=True). This mirrors
  // TIDEWindowCreatorList.CreateForm's own "else if DoDisableAutoSizing then
  // DisableAutoSizing" tail (idewindowintf.pas), applied unconditionally whenever
  // the flag is set -- freshly created OR reused instance -- because the caller
  // balances it with EnableAutoSizing on every invocation.
  if DoDisableAutoSizing then
    GChatWindow.DisableAutoSizing;
  AForm := GChatWindow;
end;

{ Fallback: open the chat as a plain floating window when IDE docking is not
  available (IDEWindowCreators unset / creator not registered). Preserves the
  pre-dock behavior so the feature degrades gracefully. }
procedure _ShowFloatingFallback;
begin
  if GChatWindow = nil then
    GChatWindow := TAefosLazChatWindow.CreateNew(Application);
  GChatWindow.Show;
  GChatWindow.BringToFront;
end;

{ TAefosLazChatDock }

class procedure TAefosLazChatDock.RegisterDockable;
begin
  { IDEWindowCreators is provided by the IDE core (IDEIntf), independent of whether
    AnchorDocking is installed; when AnchorDocking IS present, ShowForm routes
    through IDEDockMaster and the panel becomes dockable. Idempotent + guarded so a
    failure only degrades to the floating fallback, never blocks IDE load. }
  if IDEWindowCreators = nil then
    Exit;
  if GChatCreator <> nil then
    Exit;
  try
    GChatCreator := IDEWindowCreators.Add(cAefosChatFormName,
      @_CreateAefosChatWindow, nil,
      { Default placement HINTS (the dock master may override): a right-side tool
        panel ~560 px wide spanning most of the height. }
      '60%', '10%', '+560', '85%',
      '', alRight);
  except
    GChatCreator := nil;
  end;
end;

class procedure TAefosLazChatDock.Show;
begin
  { Prefer the native docked panel: ShowForm create-on-demands the form via the
    creator and, when AnchorDocking is active, docks it. Fall back to a floating
    window if the creator could not be registered. }
  if (IDEWindowCreators <> nil) and (GChatCreator <> nil) then
    IDEWindowCreators.ShowForm(cAefosChatFormName, True)
  else
    _ShowFloatingFallback;
end;

class procedure TAefosLazChatDock.UnregisterDockable;
var
  LIndex: Integer;
begin
  { IDE-unload discipline: drop the IDE-held reference to our create-proc so no
    dangling pointer into this unit survives (mirrors the Delphi teardown rules).
    Guarded: IDEWindowCreators may already be gone at finalization order. }
  if (GChatCreator <> nil) and (IDEWindowCreators <> nil) then
  begin
    try
      LIndex := IDEWindowCreators.IndexOfName(cAefosChatFormName);
      if LIndex >= 0 then
        IDEWindowCreators.Delete(LIndex);
    except
    end;
  end;
  GChatCreator := nil;
end;

{ TAefosLazChatWindow }

constructor TAefosLazChatWindow.CreateNew(AOwner: TComponent; Num: Integer);
var
  LLoader: string;
begin
  inherited CreateNew(AOwner, Num);
  Caption := 'Aefos AI Chat';
  Width := 560;
  Height := 640;
  Position := poScreenCenter;

  // Point the SDK loader at a WebView2Loader.dll shipped beside the IDE exe, if
  // present (best-effort; a missing loader surfaces via OnFailed, not a crash).
  LLoader := ExtractFilePath(ParamStr(0)) + 'WebView2Loader.dll';
  if FileExists(LLoader) then
    // L8: this unit is {$mode delphi} (string = UTF-8 AnsiString) but the SDK is
    // {$MODE DELPHIUNICODE} (string = UTF-16). Cast explicitly through UTF8Decode so
    // the seam does not rely on an implicit AnsiString->UnicodeString conversion.
    SetWebView2Path(UTF8Decode(LLoader));

  FWeb := TAefosLazWebView.Create(Self);
  FWeb.Parent := Self;
  FWeb.Align := alClient;
  // OnFailed stays with the window (runtime-missing caption); the controller owns
  // OnMessageReceived + OnNavigationCompleted (the render protocol / chat loop).
  FWeb.OnFailed := _WebFailed;

  FController := TAefosLazChatController.Create(FWeb);
  // The header gear opens the IDE Options page; the controller is IDE-free, so it
  // delegates through this callback (nil in the standalone proof harness).
  FController.OnOpenSettings := _OpenSettings;
  // The user-command "This project" scope needs the active project's folder; the
  // IDE-free controller resolves it through this seam (nil in the proof harness).
  FController.OnResolveProjectRoot := _ResolveProjectRoot;
  FController.AttachAndLoad;

  // Catch AnchorDocking undock/float, which activates a new floating host window but
  // leaves this window (and its alClient WebView) at the same relative position, so
  // no Resize / WM_WINDOWPOSCHANGED reaches the WebView to notice the root changed.
  // Multi-subscriber handler list (not a single-slot event), so it never clobbers
  // another consumer; removed in Destroy per IDE-unload discipline.
  if Screen <> nil then
  begin
    Screen.AddHandlerActiveFormChanged(_ActiveFormChanged);
    FActiveFormHooked := True;
  end;
end;

destructor TAefosLazChatWindow.Destroy;
begin
  // IDE-unload discipline: drop the Screen handler and any queued async call FIRST,
  // so neither can fire into this (now dying) window after teardown begins.
  if FActiveFormHooked and (Screen <> nil) then
  begin
    try
      Screen.RemoveHandlerActiveFormChanged(_ActiveFormChanged);
    except
    end;
    FActiveFormHooked := False;
  end;
  if Application <> nil then
    Application.RemoveAsyncCalls(Self);
  // Free the controller first so it cancels any in-flight Ollama stream while the
  // host is still alive, then the inherited Destroy tears down FWeb (owned by the
  // form) with the C1 liveness token guarding late WebView2 callbacks.
  FreeAndNil(FController);
  inherited Destroy;
end;

procedure TAefosLazChatWindow._ActiveFormChanged(Sender: TObject;
  AForm: TCustomForm);
begin
  // An undock/float/re-dock changes which top-level form is active. Defer the
  // root-guarded re-home to the next message cycle so the reparent has fully settled
  // and the fresh HWND is valid. QueueAsyncCall coalesces naturally (a burst of
  // activation changes collapses to one settled re-check); RemoveAsyncCalls(Self) in
  // Destroy cancels any still-pending call. No-op unless the WebView root changed.
  if Assigned(FWeb) and (Application <> nil) then
    Application.QueueAsyncCall(_AsyncSyncWebView, 0);
end;

procedure TAefosLazChatWindow._AsyncSyncWebView(Data: PtrInt);
begin
  if Assigned(FWeb) then
    FWeb.SyncIfHostChanged;
end;

procedure TAefosLazChatWindow.DoShow;
begin
  inherited DoShow;
  // After the IDE (re)shows this panel -- e.g. it was just docked/undocked, which
  // recreated the window handle -- re-home the windowed WebView2 onto the live HWND
  // so it never presents into a dead parent (blank). Cheap + idempotent; a no-op
  // before the controller is live.
  if Assigned(FWeb) then
    FWeb.SyncToHostWindow;
end;

procedure TAefosLazChatWindow._WebFailed(const AHResult: HRESULT);
begin
  Caption := Format('Aefos AI Chat - WebView2 unavailable (hr=0x%.8x)', [AHResult]);
end;

procedure TAefosLazChatWindow._OpenSettings;
begin
  // DoOpenIDEOptions(EditorClass) selects the Aefos AI node by class -- the same
  // deep-link the "Options..." menu item uses (Aefos.Lazarus.Register.HandleOptions).
  // Guarded: no-op if the IDE seam is unavailable.
  if LazarusIDE <> nil then
    LazarusIDE.DoOpenIDEOptions(TAefosOptionsFrame);
end;

function TAefosLazChatWindow._ResolveProjectRoot: UnicodeString;
var
  LInfoFile: string;
  LDir: string;
begin
  // The active project's folder = the directory of its .lpi (ProjectInfoFile). ''
  // when no project is open, so the controller falls back to the global catalogue.
  // ProjectInfoFile is LCL UTF-8; the controller seam wants UnicodeString, so
  // convert at this boundary (UTF8Decode, as the WebView2-loader path above does).
  Result := '';
  if LazarusIDE = nil then
    Exit;
  if LazarusIDE.ActiveProject = nil then
    Exit;
  LInfoFile := LazarusIDE.ActiveProject.ProjectInfoFile;
  if LInfoFile = '' then
    Exit;
  LDir := ExtractFileDir(LInfoFile);
  if LDir <> '' then
    Result := UTF8Decode(LDir);
end;

finalization
  // M5: mirror the sibling singletons (McpHost.GHost, Options.GAefosOptionsInstance)
  // -- the package is statically linked, so this runs only at IDE shutdown. Remove
  // the IDE-held window-creator reference FIRST (unload discipline), then close and
  // free the single chat window in order; with the C1 liveness token in the host
  // this is a controlled teardown, not a callback race. Guarded so shutdown never
  // raises.
  TAefosLazChatDock.UnregisterDockable;
  if GChatWindow <> nil then
  begin
    try
      GChatWindow.Close;
    except
    end;
    FreeAndNil(GChatWindow);
  end;

end.
