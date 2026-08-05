unit Aefos.Lazarus.WebViewHost;

{ TAefosLazWebView -- the LCL (Lazarus/FPC) COMPOSITION WebView2 host.

  This is the Lazarus reimplementation of the Delphi VCL facade TAefosWebView
  (source/webview/Aefos.WebView.Control.pas) + its TCompositionWebViewHost
  (source/webview/Aefos.WebView.CompositionHost.pas), folded into one LCL control.
  Same public facade (6 methods + 4 events) over Aefos's clean-room WebView2 SDK
  (Aefos.Win.WebView2), now hosting the WebView2 via DirectComposition instead of a
  windowed child HWND.

  WHY COMPOSITION (the end of the docked-chat ping-pong):
  A WINDOWED WebView2 parents its own child HWND to this control. That binding is
  fragile in the IDE dock: on every dock / undock / layout-switch the dock framework
  reparents or recreates the host window, and the windowed controller keeps
  presenting into the OLD parent surface (blank) until re-homed -- AND it stops
  compositing entirely when the top-level host is deactivated (the CLI terminal
  stealing the foreground). Each re-home trigger (Resize / WM_WINDOWPOSCHANGED /
  active-form hook) only ever covered PART of the transition, so fixing the dock
  case broke the undock case and vice-versa: whack-a-mole.

  Composition removes the whole class of bug because it decouples the two things the
  windowed host coupled to one fragile HWND parentage:
   * The WebView2 CONTROLLER's parent window is a hidden, STABLE anchor window
     (FAnchorWnd, a WS_POPUP STATIC created once and never destroyed until teardown).
     It never dies on dock/undock, so the controller never loses its parent and never
     stops compositing.
   * The WebView renders into a DirectComposition VISUAL tree that lives in the DComp
     device, independent of any HWND. The DWM composites that visual regardless of
     window activation/occlusion -> a foreground steal (terminal) never blanks it.
   * ONLY the DComp TARGET is bound to the host control's HWND. On the rare case where
     dock actually RECREATES the host HWND (CreateWnd), we rebuild JUST the target
     (CreateTargetForHwnd) and re-attach the SAME visual -- one step, no re-navigation,
     no controller reparent, nothing to "lose". When the HWND merely gets a new
     ancestor (the common AnchorDocking undock, host HWND persists) NOTHING is needed
     at all: the target is still valid and the DWM keeps compositing.
  So there is exactly one binding to maintain (the target) and one reliable trigger
  (CreateWnd) -- the ping-pong cannot recur.

  What differs from the Delphi VCL host, and why:
   * FPC has no anonymous methods, so the async COM callbacks are single-Invoke
     TInterfacedObject gates wrapping `of object` methods (as in the SDK spike idiom),
     each carrying a refcounted liveness token (C1) -- not the Delphi Callback<>
     closures.
   * The string seam: the SDK is MODE DELPHIUNICODE (UTF-16); LCL is UTF-8
     (mode delphi, string = AnsiString). Every string crossing the COM boundary is
     marshalled UTF-8 <-> UTF-16 explicitly (LazUTF8).
   * Input forwarding uses the LCL virtual mouse methods (MouseDown/Move/Up/Wheel)
     instead of the VCL WndProc override -- composition has no child HWND, so the host
     hands mouse+wheel to the composition controller (SendMouseInput) and routes
     keyboard by moving Win32 focus to the anchor on click (MoveFocus), mirroring the
     Delphi control. This is the control's OWN input path -- never an external
     WindowProc hook (that path caused the Delphi unload AV).

  Facade parity (Control.pas): Configure, Navigate, ExecuteScript x2,
  PostWebMessageAsString, FocusWebView (+ NavigateToString convenience);
  events OnReady, OnNavigationCompleted, OnMessageReceived, OnFailed. }

{$mode delphi}
{$H+}

interface

uses
  Windows, ActiveX, SysUtils, Classes, Controls, Graphics, LCLType, LazUTF8,
  LazLoggerBase, Aefos.WebView.Types, Aefos.Win.WebView2, Aefos.Lazarus.WebViewDComp;

type
  // Independently-lived liveness token. Refcounted (an interface), so it OUTLIVES
  // the control for as long as any in-flight async COM handler still holds it. The
  // control marks it dead (Kill) at the very top of Destroy; every handler checks
  // IsAlive BEFORE touching the (by then dangling) control, turning a would-be
  // use-after-free into a safe no-op. This is the C1 guard against WebView2 calling
  // back into a freed control (IDE shutdown racing env/controller creation).
  IAefosLiveToken = interface
    ['{7A3E1C4D-9B2F-4E6A-8D1C-3F5B7A2E9C4D}']
    function IsAlive: Boolean;
    procedure Kill;
  end;

  TAefosLazWebView = class(TCustomControl)
  private
    FEnv: ICoreWebView2Environment;
    FController: ICoreWebView2Controller;
    FCompController: ICoreWebView2CompositionController;
    FWebView: ICoreWebView2;
    FEnvH: ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler;
    FCompCtrlH: ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler;
    FNavH: ICoreWebView2NavigationCompletedEventHandler;
    FMsgH: ICoreWebView2WebMessageReceivedEventHandler;
    FNavToken: EventRegistrationToken;
    FMsgToken: EventRegistrationToken;
    // DirectComposition pipeline. The device + root visual are HWND-independent
    // (they survive every reparent); only the target is bound to the host HWND.
    FDCompDevice: IDCompositionDevice;
    FDCompTarget: IDCompositionTarget;
    FRootVisual: IDCompositionVisual;
    // Hidden, STABLE WS_POPUP window that is the composition controller's parent.
    // Never destroyed on dock/undock -> the controller never stops compositing.
    FAnchorWnd: HWND;
    // The HWND the DComp target is currently bound to (0 = none). Lets Reparent be a
    // cheap no-op when the host HWND did not actually change (idempotent re-home).
    FTargetWnd: HWND;
    FBounds: tagRECT;
    FConfig: TWebViewConfig;
    FLive: IAefosLiveToken;
    FStaOwned: Boolean;
    FStarted: Boolean;
    FReady: Boolean;
    FPendingUrl: string;
    FPendingHtml: string;
    FOnReady: TWebViewReadyEvent;
    FOnNav: TWebViewNavigationCompletedEvent;
    FOnMsg: TWebViewMessageEvent;
    FOnFailed: TWebViewFailedEvent;
    procedure _EnsureSTA;
    procedure _EnsureStarted;
    function _MakeEnvOptions: ICoreWebView2EnvironmentOptions;
    function _SetupComposition: Boolean;
    procedure _UpdateBounds;
    procedure _SyncAnchorToScreen;
    procedure _Reparent(ANewHostWnd: HWND);
    procedure _InjectBridgeShim;
    procedure _FlushPending;
    procedure _Fail(AHResult: HRESULT);
    procedure _SendMouse(AKind: COREWEBVIEW2_MOUSE_EVENT_KIND;
      AKeys: COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS; AData: Cardinal; AX, AY: Integer);
    function _ShiftToKeys(AShift: TShiftState): COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS;
    // The SDK handler idiom calls these `of object` methods (see unit header).
    function _EnvCompleted(errorCode: HResult;
      const AEnvironment: ICoreWebView2Environment): HResult;
    function _CompCtrlCompleted(errorCode: HResult;
      const AController: ICoreWebView2CompositionController): HResult;
    function _NavCompleted(const ASender: ICoreWebView2;
      const AArgs: ICoreWebView2NavigationCompletedEventArgs): HResult;
    function _WebMessage(const ASender: ICoreWebView2;
      const AArgs: ICoreWebView2WebMessageReceivedEventArgs): HResult;
  protected
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
    procedure Resize; override;
    procedure Paint; override;
    // Input forwarding: composition has no child HWND, so the host relays mouse +
    // wheel to the controller and routes keyboard focus to the anchor on click.
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // True once the WebView2 controller is live and events flow.
    property Ready: Boolean read FReady;
    // Set creation options BEFORE the control's HWND exists.
    procedure Configure(const AConfig: TWebViewConfig);
    procedure Navigate(const AUrl: string);
    // Load inline HTML (the chat shell / a bridge-test page) without a file.
    procedure NavigateToString(const AHtml: string);
    procedure ExecuteScript(const AScript: string); overload;
    procedure ExecuteScript(const AScript: string;
      const AOnResult: TWebViewScriptResult); overload;
    procedure PostWebMessageAsString(const AMessage: string);
    procedure FocusWebView;
    // Re-confirm the composition target for this control's CURRENT HWND. Composition
    // is activation-independent, so this is mostly a no-op the host window calls on
    // dock/undock/show signals for defence in depth; it rebuilds the DComp target
    // ONLY when the host HWND actually changed (FTargetWnd guard), so it never
    // flickers and cannot start a re-home loop. Retained for facade compatibility
    // with the previous windowed host (ChatWindow calls it on DoShow).
    procedure SyncToHostWindow;
    // Same as SyncToHostWindow -- the previous windowed host distinguished a cheap
    // "only if changed" variant; with composition + the FTargetWnd guard both are
    // already changed-guarded, so this is an alias kept so ChatWindow's active-form
    // hook compiles unchanged.
    procedure SyncIfHostChanged;
    property OnReady: TWebViewReadyEvent read FOnReady write FOnReady;
    property OnNavigationCompleted: TWebViewNavigationCompletedEvent
      read FOnNav write FOnNav;
    property OnMessageReceived: TWebViewMessageEvent read FOnMsg write FOnMsg;
    property OnFailed: TWebViewFailedEvent read FOnFailed write FOnFailed;
  published
    property Align;
    property Anchors;
    property TabStop default True;
    property Visible;
    property OnEnter;
    property OnExit;
  end;

implementation

const
  // WebView2 SDK target version -- mirrors the Delphi composition host
  // (Aefos.WebView.CompositionHost.CWebView2TargetVersion) so both editions expect
  // the SAME evergreen runtime baseline on a shared machine. A NON-EMPTY value is
  // mandatory whenever an options object is passed (empty -> E_INVALIDARG).
  CWebView2TargetVersion: UnicodeString = '137.0.3296.44';

  // COREWEBVIEW2_MOUSE_EVENT_KIND values ARE the Win32 WM_* mouse message codes
  // (Microsoft enum page). The SDK declares only the WHEEL constant; the button
  // kinds the host forwards are declared here.
  CMouseMove       = $0200; // WM_MOUSEMOVE
  CMouseLeftDown   = $0201; // WM_LBUTTONDOWN
  CMouseLeftUp     = $0202; // WM_LBUTTONUP
  CMouseRightDown  = $0204; // WM_RBUTTONDOWN
  CMouseRightUp    = $0205; // WM_RBUTTONUP
  CMouseMiddleDown = $0207; // WM_MBUTTONDOWN
  CMouseMiddleUp   = $0208; // WM_MBUTTONUP

  // COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS values ARE the Win32 MK_* flags.
  CMkLeftButton   = $0001; // MK_LBUTTON
  CMkRightButton  = $0002; // MK_RBUTTON
  CMkShift        = $0004; // MK_SHIFT
  CMkControl      = $0008; // MK_CONTROL
  CMkMiddleButton = $0010; // MK_MBUTTON

type
  // Concrete liveness token (see IAefosLiveToken). A single Boolean guarded only
  // by the fact that the control mutates it (Kill) on the IDE main thread before
  // freeing, and the handlers read it on that same (message-loop) thread.
  TAefosLiveToken = class(TInterfacedObject, IAefosLiveToken)
  private
    FAlive: Boolean;
  public
    constructor Create;
    function IsAlive: Boolean;
    procedure Kill;
  end;

  // Host-side liveness gates for the async/event callbacks. The SDK's own
  // TAefosWv2*Handler classes wrap a bare `of object` method pointer whose Self is
  // the control -- once the control is freed that Self dangles, and the SDK unit is
  // frozen (webview2-specialist-approved, kept byte-identical) so the gate cannot
  // live there. These host handlers implement the same single-Invoke WebView2 COM
  // interfaces directly: WebView2 AddRefs them (keeping FLive -- and thus the check
  // -- valid), and each Invoke consults FLive.IsAlive BEFORE dereferencing FOwner,
  // so a callback that lands after the control died is a safe S_OK no-op (C1). Each
  // Invoke is also wrapped in try/except so no Pascal exception crosses the native
  // stdcall boundary (H2).
  TAefosEnvGate = class(TInterfacedObject,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)
  private
    FLive: IAefosLiveToken;
    FOwner: TAefosLazWebView;
  public
    constructor Create(AOwner: TAefosLazWebView; const ALive: IAefosLiveToken);
    function Invoke(errorCode: HResult;
      const AEnvironment: ICoreWebView2Environment): HResult; stdcall;
  end;

  // Composition-controller-completed gate (the composition twin of the windowed
  // controller gate). Implements the single-Invoke composition handler interface.
  TAefosCompCtrlGate = class(TInterfacedObject,
    ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler)
  private
    FLive: IAefosLiveToken;
    FOwner: TAefosLazWebView;
  public
    constructor Create(AOwner: TAefosLazWebView; const ALive: IAefosLiveToken);
    function Invoke(errorCode: HResult;
      const AResult: ICoreWebView2CompositionController): HResult; stdcall;
  end;

  TAefosNavGate = class(TInterfacedObject,
    ICoreWebView2NavigationCompletedEventHandler)
  private
    FLive: IAefosLiveToken;
    FOwner: TAefosLazWebView;
  public
    constructor Create(AOwner: TAefosLazWebView; const ALive: IAefosLiveToken);
    function Invoke(const ASender: ICoreWebView2;
      const AArgs: ICoreWebView2NavigationCompletedEventArgs): HResult; stdcall;
  end;

  TAefosMsgGate = class(TInterfacedObject,
    ICoreWebView2WebMessageReceivedEventHandler)
  private
    FLive: IAefosLiveToken;
    FOwner: TAefosLazWebView;
  public
    constructor Create(AOwner: TAefosLazWebView; const ALive: IAefosLiveToken);
    function Invoke(const ASender: ICoreWebView2;
      const AArgs: ICoreWebView2WebMessageReceivedEventArgs): HResult; stdcall;
  end;

  // ExecuteScript-with-result adapter. The async creation/event handlers use the
  // of-object idiom, but the per-call script-result callback must capture the
  // caller's TWebViewScriptResult -- which an of-object method cannot. FPC 3.2.2 has
  // no closures either, so this dedicated single-Invoke COM handler carries the
  // callback as a field. WebView2 AddRefs it on ExecuteScript and Releases it after
  // Invoke, so its lifetime is correct with no manual keep-alive. It marshals the
  // UTF-16 result JSON to UTF-8.
  TAefosScriptResultHandler = class(TInterfacedObject,
    ICoreWebView2ExecuteScriptCompletedHandler)
  private
    FCallback: TWebViewScriptResult;
  public
    constructor Create(const ACallback: TWebViewScriptResult);
    function Invoke(errorCode: HResult; AResultJson: PWideChar): HResult; stdcall;
  end;

const
  // Document-create bootstrap that guarantees the window.chrome.webview.postMessage
  // contract the chat HTML/JS is written against (OutputPanel.Assets.pas et al).
  //
  // On WebView2 the runtime injects window.chrome.webview natively, and its
  // postMessage is what add_WebMessageReceived (wired below) delivers to Pascal --
  // so this bootstrap is idempotent: it only DEFINES the members when missing,
  // never shadows the native bridge. It is the seam a non-WebView2 host (e.g. a
  // future CEF-on-Linux host) would instead route to its own message channel;
  // keeping it here makes the shell HTML run byte-identical across hosts.
  CBridgeShim: UnicodeString =
    '(function(){' +
    'if(!window.chrome){window.chrome={};}' +
    'if(!window.chrome.webview){window.chrome.webview={};}' +
    'if(typeof window.chrome.webview.postMessage!=="function"){' +
    'window.chrome.webview.postMessage=function(m){' +
    '/* no native bridge on this host */};}' +
    '})();';

var
  // M4: process-lifetime counter giving each control instance a unique default
  // UserDataFolder suffix. An atomic increment (no timestamp/random -- both
  // unavailable in some FPC contexts) guarantees two WebView2 environments never
  // share one folder in-process, which would raise ERROR_INVALID_STATE 0x8007139F
  // (this project's own past docked-webview bug).
  GAefosWvSeq: LongInt = 0;

function _HrFailed(AHr: HResult): Boolean; inline;
begin
  // HRESULT failure == sign bit set (independent of Failed()/Succeeded() RTL).
  Result := AHr < 0;
end;

{ TAefosLiveToken }

constructor TAefosLiveToken.Create;
begin
  inherited Create;
  FAlive := True;
end;

function TAefosLiveToken.IsAlive: Boolean;
begin
  Result := FAlive;
end;

procedure TAefosLiveToken.Kill;
begin
  FAlive := False;
end;

{ TAefosEnvGate }

constructor TAefosEnvGate.Create(AOwner: TAefosLazWebView;
  const ALive: IAefosLiveToken);
begin
  inherited Create;
  FOwner := AOwner;
  FLive := ALive;
end;

function TAefosEnvGate.Invoke(errorCode: HResult;
  const AEnvironment: ICoreWebView2Environment): HResult; stdcall;
begin
  Result := S_OK;
  try
    // Gate BEFORE the of-object call: FOwner's Self is dangling once the token is
    // dead, so it must never be dereferenced then.
    if (FLive <> nil) and FLive.IsAlive then
      Result := FOwner._EnvCompleted(errorCode, AEnvironment);
  except
    on E: Exception do
      // Never let a Pascal exception cross the native stdcall boundary.
      DebugLn('[AefosAI] webview: EnvCompleted swallowed ' + E.ClassName
        + ': ' + E.Message);
  end;
end;

{ TAefosCompCtrlGate }

constructor TAefosCompCtrlGate.Create(AOwner: TAefosLazWebView;
  const ALive: IAefosLiveToken);
begin
  inherited Create;
  FOwner := AOwner;
  FLive := ALive;
end;

function TAefosCompCtrlGate.Invoke(errorCode: HResult;
  const AResult: ICoreWebView2CompositionController): HResult; stdcall;
begin
  Result := S_OK;
  try
    if (FLive <> nil) and FLive.IsAlive then
      Result := FOwner._CompCtrlCompleted(errorCode, AResult);
  except
    on E: Exception do
      DebugLn('[AefosAI] webview: CompCtrlCompleted swallowed ' + E.ClassName
        + ': ' + E.Message);
  end;
end;

{ TAefosNavGate }

constructor TAefosNavGate.Create(AOwner: TAefosLazWebView;
  const ALive: IAefosLiveToken);
begin
  inherited Create;
  FOwner := AOwner;
  FLive := ALive;
end;

function TAefosNavGate.Invoke(const ASender: ICoreWebView2;
  const AArgs: ICoreWebView2NavigationCompletedEventArgs): HResult; stdcall;
begin
  Result := S_OK;
  try
    if (FLive <> nil) and FLive.IsAlive then
      Result := FOwner._NavCompleted(ASender, AArgs);
  except
    on E: Exception do
      DebugLn('[AefosAI] webview: NavCompleted swallowed ' + E.ClassName
        + ': ' + E.Message);
  end;
end;

{ TAefosMsgGate }

constructor TAefosMsgGate.Create(AOwner: TAefosLazWebView;
  const ALive: IAefosLiveToken);
begin
  inherited Create;
  FOwner := AOwner;
  FLive := ALive;
end;

function TAefosMsgGate.Invoke(const ASender: ICoreWebView2;
  const AArgs: ICoreWebView2WebMessageReceivedEventArgs): HResult; stdcall;
begin
  Result := S_OK;
  try
    if (FLive <> nil) and FLive.IsAlive then
      Result := FOwner._WebMessage(ASender, AArgs);
  except
    on E: Exception do
      DebugLn('[AefosAI] webview: WebMessage swallowed ' + E.ClassName
        + ': ' + E.Message);
  end;
end;

{ TAefosScriptResultHandler }

constructor TAefosScriptResultHandler.Create(const ACallback: TWebViewScriptResult);
begin
  inherited Create;
  FCallback := ACallback;
end;

function TAefosScriptResultHandler.Invoke(errorCode: HResult;
  AResultJson: PWideChar): HResult; stdcall;
begin
  Result := S_OK;
  if not Assigned(FCallback) then
    Exit;
  // H2: the callback runs on WebView2's native stdcall stack -- a Pascal exception
  // escaping here is undefined behavior / a hard IDE crash. Swallow + log.
  try
    if AResultJson <> nil then
      FCallback(errorCode, UTF16ToUTF8(UnicodeString(AResultJson)))
    else
      FCallback(errorCode, '');
  except
    on E: Exception do
      DebugLn('[AefosAI] webview: ScriptResult swallowed ' + E.ClassName
        + ': ' + E.Message);
  end;
end;

{ TAefosLazWebView }

constructor TAefosLazWebView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FConfig := TWebViewConfig.Default;
  // Composition (the DComp visual) paints the content; let the control accept focus
  // + clicks and not fight the DWM-composited frame for its client area.
  ControlStyle := ControlStyle - [csOpaque];
  // Hidden, STABLE parent for the composition controller (a plain WS_POPUP STATIC,
  // never shown, owned by this module). It survives every dock/undock HWND recreate,
  // so the controller keeps compositing into the visual no matter what the dock does.
  FAnchorWnd := CreateWindowEx(0, PChar('STATIC'), nil, WS_POPUP,
    0, 0, 0, 0, 0, 0, HInstance, nil);
  // Born alive. Any async handler created below shares this token; Destroy kills it
  // FIRST, so a late WebView2 callback becomes a no-op instead of a UAF (C1).
  FLive := TAefosLiveToken.Create;
  TabStop := True;
end;

destructor TAefosLazWebView.Destroy;
begin
  // C1: mark the control dead BEFORE freeing anything, so any handler whose Invoke
  // fires from here on (env/controller creation still in flight) sees IsAlive=False
  // and returns without dereferencing this now-dying instance.
  if FLive <> nil then
    FLive.Kill;
  // Balance the two event registrations before dropping the interfaces, so the
  // runtime is not left holding a handler that points into a freed control
  // (defense in depth -- the liveness gate already neutralises a late callback).
  if Assigned(FWebView) then
  begin
    try
      if FNavToken.value <> 0 then
        FWebView.remove_NavigationCompleted(FNavToken);
      if FMsgToken.value <> 0 then
        FWebView.remove_WebMessageReceived(FMsgToken);
    except
      // teardown must never raise.
    end;
  end;
  if Assigned(FController) then
  begin
    try
      FController.Close;
    except
    end;
  end;
  // Drop the composition pipeline (visual/target/device) + WebView refs. Order is
  // leaf-first; each is an interface, so nil releases it.
  FRootVisual := nil;
  FDCompTarget := nil;
  FDCompDevice := nil;
  FWebView := nil;
  FCompController := nil;
  FController := nil;
  FEnv := nil;
  FNavH := nil;
  FMsgH := nil;
  FCompCtrlH := nil;
  FEnvH := nil;
  // Destroy the hidden anchor window (unload discipline: no IDE-held handle left).
  if FAnchorWnd <> 0 then
  begin
    try
      DestroyWindow(FAnchorWnd);
    except
    end;
    FAnchorWnd := 0;
  end;
  // M3: balance the CoInitializeEx this instance actually performed. Only when we
  // owned the init (S_OK/S_FALSE) -- never on RPC_E_CHANGED_MODE, where the thread
  // was already MTA and we did not initialise it.
  if FStaOwned then
  begin
    try
      CoUninitialize;
    except
    end;
    FStaOwned := False;
  end;
  inherited Destroy;
end;

procedure TAefosLazWebView.Configure(const AConfig: TWebViewConfig);
begin
  FConfig := AConfig;
end;

procedure TAefosLazWebView._EnsureSTA;
var
  LHr: HResult;
begin
  // WebView2 requires an STA; LCL does not CoInitialize. This is best-effort and
  // idempotent: if the apartment was already initialised (the IDE, or the app's
  // .lpr, may have done it first) CoInitializeEx returns S_FALSE / RPC_E_CHANGED_MODE
  // and we simply proceed -- WebView2 delivers callbacks on the LCL message loop.
  // M3: remember whether WE performed the init so Destroy can balance it. S_OK or
  // S_FALSE both mean an init that a matching CoUninitialize must undo;
  // RPC_E_CHANGED_MODE means the thread was already MTA -- we own nothing.
  LHr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  FStaOwned := (LHr = S_OK) or (LHr = S_FALSE);
end;

function TAefosLazWebView._MakeEnvOptions: ICoreWebView2EnvironmentOptions;
var
  LOptions: ICoreWebView2EnvironmentOptions;
  LArgs: UnicodeString;
begin
  // Mirror the Delphi composition host's environment options. GPU compositing is
  // what makes WebView2 render BLACK on some GPUs/drivers/VMs/RDP, and the chat is
  // text/markdown/code where GPU buys nothing -- so disable it by default (opt back
  // in with AEFOS_WEBVIEW_ENABLE_GPU). A NON-EMPTY TargetCompatibleBrowserVersion is
  // mandatory once an options object is passed. All four fields are set to avoid the
  // E_INVALIDARG the Delphi host documents for a partially-filled options object.
  LOptions := TCoreWebView2EnvironmentOptions.Create;
  LArgs := UTF8ToUTF16(Trim(FConfig.AdditionalBrowserArguments));
  if (Pos('--disable-gpu', LowerCase(string(LArgs))) = 0)
     and (Trim(SysUtils.GetEnvironmentVariable('AEFOS_WEBVIEW_ENABLE_GPU')) = '') then
  begin
    if LArgs <> '' then
      LArgs := LArgs + ' ';
    LArgs := LArgs + '--disable-gpu';
  end;
  LOptions.Set_AdditionalBrowserArguments(PWideChar(LArgs));
  LOptions.Set_Language(PWideChar(UnicodeString('')));
  LOptions.Set_TargetCompatibleBrowserVersion(PWideChar(CWebView2TargetVersion));
  LOptions.Set_AllowSingleSignOnUsingOSPrimaryAccount(0);
  Result := LOptions;
end;

procedure TAefosLazWebView._EnsureStarted;
var
  LUserData: string;
  LUserDataW: UnicodeString;
  LHr: HResult;
begin
  if FStarted or (csDesigning in ComponentState) or not HandleAllocated then
    Exit;
  FStarted := True;
  _EnsureSTA;

  LUserData := FConfig.UserDataFolder;
  if LUserData = '' then
    // M4: per-instance-unique so two hosts in one process never collide on the
    // same UserDataFolder. Process id keeps it distinct across processes too.
    LUserData := IncludeTrailingPathDelimiter(GetTempDir)
      + Format('aefos-lazarus-webview-%u-%d',
          [GetCurrentProcessId, InterlockedIncrement(GAefosWvSeq)]);
  ForceDirectories(LUserData);
  LUserDataW := UTF8ToUTF16(LUserData);

  // C1: the gate carries FLive; WebView2 keeps the gate (and thus FLive) alive, so
  // a callback arriving after this control is freed is a safe no-op.
  FEnvH := TAefosEnvGate.Create(Self, FLive);
  LHr := CreateCoreWebView2EnvironmentWithOptions(nil,
    PWideChar(LUserDataW), _MakeEnvOptions, FEnvH);
  if _HrFailed(LHr) then
    _Fail(LHr);
end;

function TAefosLazWebView._EnvCompleted(errorCode: HResult;
  const AEnvironment: ICoreWebView2Environment): HResult;
var
  LEnv3: ICoreWebView2Environment3;
  LHr: HResult;
begin
  Result := S_OK;
  if _HrFailed(errorCode) or (AEnvironment = nil) then
  begin
    _Fail(errorCode);
    Exit;
  end;
  FEnv := AEnvironment;
  // Composition hosting needs the v3 environment (the composition-controller factory).
  if not Supports(AEnvironment, ICoreWebView2Environment3, LEnv3) then
  begin
    _Fail(E_NOINTERFACE);
    Exit;
  end;
  FCompCtrlH := TAefosCompCtrlGate.Create(Self, FLive);
  // The composition controller is parented to the hidden STABLE anchor window, NOT
  // to this control's HWND -- that is what makes it immune to dock/undock recreate.
  LHr := LEnv3.CreateCoreWebView2CompositionController(FAnchorWnd, FCompCtrlH);
  if _HrFailed(LHr) then
    _Fail(LHr);
end;

function TAefosLazWebView._CompCtrlCompleted(errorCode: HResult;
  const AController: ICoreWebView2CompositionController): HResult;
var
  LController2: ICoreWebView2Controller2;
  LColor: COREWEBVIEW2_COLOR;
begin
  Result := S_OK;
  if _HrFailed(errorCode) or (AController = nil) then
  begin
    _Fail(errorCode);
    Exit;
  end;
  FCompController := AController;
  // Every composition controller is also the classic controller (bounds/visible/
  // focus live there); QI for it.
  if not Supports(AController, ICoreWebView2Controller, FController) then
  begin
    _Fail(E_NOINTERFACE);
    Exit;
  end;
  // Build the DirectComposition pipeline (D3D11 -> DXGI -> DComp device/target/
  // visual -> RootVisualTarget). This is what the DWM composites independent of
  // window activation.
  if not _SetupComposition then
  begin
    _Fail(E_FAIL);
    Exit;
  end;
  if _HrFailed(FController.Get_CoreWebView2(FWebView)) or (FWebView = nil) then
  begin
    _Fail(E_FAIL);
    Exit;
  end;

  // Anti-flash background: paint the dark shell colour behind the page from the very
  // first frame, so the WebView2 cold-load looks like a dark->content fade rather
  // than a black flash (ICoreWebView2Controller2.DefaultBackgroundColor).
  LColor.A := Byte(FConfig.DefaultBackgroundColorBGRA shr 24);
  LColor.R := Byte(FConfig.DefaultBackgroundColorBGRA shr 16);
  LColor.G := Byte(FConfig.DefaultBackgroundColorBGRA shr 8);
  LColor.B := Byte(FConfig.DefaultBackgroundColorBGRA);
  if Supports(FController, ICoreWebView2Controller2, LController2) then
    LController2.Set_DefaultBackgroundColor(LColor);

  // Mark the host ready BEFORE asserting bounds. _UpdateBounds only pushes
  // Set_Bounds + Commit to the controller when FReady is set (the same guard the
  // resize path uses), so FReady MUST already be true here -- otherwise the
  // controller keeps its default 0x0 viewport, WebView2 has nothing to render, and
  // the panel stays black on first show until the owner moves/resizes the window
  // (Resize is the only other caller of _UpdateBounds). The Delphi composition host
  // avoids this by calling FController.Set_Bounds unconditionally in
  // _OnControllerCompleted (Aefos.WebView.CompositionHost.pas:365); this is the FPC
  // mirror.
  FReady := True;
  FController.Set_IsVisible(1);
  // First-frame kick: push the REAL client bounds and Commit the DComp device --
  // byte-for-byte what a user resize does (Resize -> _UpdateBounds). It also
  // re-anchors the popup window and notifies the position change. Idempotent and
  // single-shot: it runs once here and once per genuine resize/reparent, never in a
  // loop -- so the first frame presents on show with no manual nudge.
  _UpdateBounds;

  // Wire the JS->Pascal channel and inject the bridge-contract bootstrap BEFORE any
  // navigation, so the very first document already has window.chrome.webview.
  FMsgH := TAefosMsgGate.Create(Self, FLive);
  FWebView.add_WebMessageReceived(FMsgH, FMsgToken);
  _InjectBridgeShim;

  FNavH := TAefosNavGate.Create(Self, FLive);
  FWebView.add_NavigationCompleted(FNavH, FNavToken);

  Invalidate;
  if Assigned(FOnReady) then
    FOnReady();
  _FlushPending;
end;

function TAefosLazWebView._SetupComposition: Boolean;
var
  LFlags: UINT;
  LFeatureLevel: TD3DFeatureLevel;
  LDevice: ID3D11Device;
  LContext: ID3D11DeviceContext;
  LDxgiDevice: IDXGIDevice;
  LHr: HResult;
begin
  Result := False;
  if not HandleAllocated then
    Exit;
  LFlags := D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  LHr := D3D11CreateDevice(nil, D3D_DRIVER_TYPE_HARDWARE, 0, LFlags, nil, 0,
    D3D11_SDK_VERSION, LDevice, LFeatureLevel, LContext);
  if _HrFailed(LHr) then
    // Retry with WARP (software) -- VMs / RDP sessions have no hardware device.
    LHr := D3D11CreateDevice(nil, D3D_DRIVER_TYPE_WARP, 0, LFlags, nil, 0,
      D3D11_SDK_VERSION, LDevice, LFeatureLevel, LContext);
  if _HrFailed(LHr) or (LDevice = nil) then
    Exit;
  if not Supports(LDevice, IDXGIDevice, LDxgiDevice) then
    Exit;
  LHr := DCompositionCreateDevice(LDxgiDevice, IID_IDCompositionDevice, FDCompDevice);
  if _HrFailed(LHr) or (FDCompDevice = nil) then
    Exit;
  // Bind the target to THIS control's HWND (the only HWND-bound piece).
  LHr := FDCompDevice.CreateTargetForHwnd(Handle, True, FDCompTarget);
  if _HrFailed(LHr) then
    Exit;
  FTargetWnd := Handle;
  if _HrFailed(FDCompDevice.CreateVisual(FRootVisual)) then
    Exit;
  if _HrFailed(FDCompTarget.SetRoot(FRootVisual)) then
    Exit;
  if _HrFailed(FCompController.Set_RootVisualTarget(FRootVisual)) then
    Exit;
  FDCompDevice.Commit;
  Result := True;
end;

procedure TAefosLazWebView._InjectBridgeShim;
var
  LHr: HResult;
begin
  if not Assigned(FWebView) then
    Exit;
  // L7: if the postMessage shim fails to register the JS bridge contract is silently
  // absent -- surface it (log + OnFailed) instead of a mysterious dead bridge.
  LHr := FWebView.AddScriptToExecuteOnDocumentCreated(PWideChar(CBridgeShim), nil);
  if _HrFailed(LHr) then
  begin
    DebugLn(Format('[AefosAI] webview: bridge shim registration failed hr=0x%.8x',
      [LHr]));
    _Fail(LHr);
  end;
end;

procedure TAefosLazWebView._FlushPending;
begin
  if FPendingHtml <> '' then
  begin
    NavigateToString(FPendingHtml);
    FPendingHtml := '';
  end
  else if FPendingUrl <> '' then
  begin
    Navigate(FPendingUrl);
    FPendingUrl := '';
  end;
end;

function TAefosLazWebView._NavCompleted(const ASender: ICoreWebView2;
  const AArgs: ICoreWebView2NavigationCompletedEventArgs): HResult;
var
  LIsSuccess: Integer;
begin
  Result := S_OK;
  LIsSuccess := 0;
  if Assigned(AArgs) then
    AArgs.Get_IsSuccess(LIsSuccess);
  if Assigned(FOnNav) then
    FOnNav(LIsSuccess <> 0);
end;

function TAefosLazWebView._WebMessage(const ASender: ICoreWebView2;
  const AArgs: ICoreWebView2WebMessageReceivedEventArgs): HResult;
var
  LRaw: PWideChar;
begin
  Result := S_OK;
  if not Assigned(FOnMsg) or not Assigned(AArgs) then
    Exit;
  LRaw := nil;
  if (AArgs.TryGetWebMessageAsString(LRaw) = S_OK) and (LRaw <> nil) then
  begin
    // UTF-16 (COM) -> UTF-8 (LCL) at the seam.
    FOnMsg(UTF16ToUTF8(UnicodeString(LRaw)));
    CoTaskMemFree(LRaw);
  end;
end;

procedure TAefosLazWebView._Fail(AHResult: HRESULT);
begin
  if Assigned(FOnFailed) then
    FOnFailed(AHResult);
end;

procedure TAefosLazWebView._SyncAnchorToScreen;
var
  LOrigin: Windows.TPoint;
begin
  // WebView2 positions windowed popups (HTML title tooltips, <select> dropdowns,
  // context menus) relative to the controller's parent window (FAnchorWnd, created
  // at 0,0). Move that invisible anchor so its client origin sits at this control's
  // true screen origin; then popups land at the control, not the screen corner. The
  // main WebView frame is composited via the DComp visual and does NOT depend on
  // this -- only popups do.
  if (FAnchorWnd = 0) or not HandleAllocated then
    Exit;
  LOrigin.X := 0;
  LOrigin.Y := 0;
  Windows.ClientToScreen(Handle, LOrigin);
  SetWindowPos(FAnchorWnd, 0, LOrigin.X, LOrigin.Y,
    FBounds.right - FBounds.Left, FBounds.bottom - FBounds.Top,
    SWP_NOZORDER or SWP_NOACTIVATE or SWP_NOREDRAW or SWP_NOOWNERZORDER);
end;

procedure TAefosLazWebView._UpdateBounds;
begin
  FBounds.Left := 0;
  FBounds.Top := 0;
  FBounds.right := ClientWidth;
  FBounds.bottom := ClientHeight;
  if FReady and Assigned(FController) then
  begin
    FController.Set_Bounds(FBounds);
    _SyncAnchorToScreen;
    FController.NotifyParentWindowPositionChanged;
    if Assigned(FDCompDevice) then
      FDCompDevice.Commit;
  end;
end;

procedure TAefosLazWebView._Reparent(ANewHostWnd: HWND);
begin
  // The single, idempotent re-home. Composition survives reparent because the
  // controller's parent is the stable anchor and the visual is HWND-independent --
  // only the DComp TARGET is bound to the host HWND. Rebuild it ONLY when the host
  // HWND actually changed (dock/undock RECREATED it); otherwise this is a cheap
  // no-op, so it cannot flicker or loop no matter how liberally it is called.
  if not (FReady and Assigned(FDCompDevice)) then
    Exit;
  if (ANewHostWnd <> 0) and (ANewHostWnd = FTargetWnd) then
  begin
    // Same host HWND: the target is still valid; just re-assert bounds/anchor.
    _UpdateBounds;
    Exit;
  end;
  if ANewHostWnd = 0 then
    Exit;
  // New host HWND: the old target is dead. Release it and rebuild for the fresh
  // handle, re-attaching the SAME root visual (with the WebView content already in
  // it) -- no re-navigation, no flash.
  FDCompTarget := nil;
  if _HrFailed(FDCompDevice.CreateTargetForHwnd(ANewHostWnd, True, FDCompTarget)) then
  begin
    FTargetWnd := 0;
    Exit;
  end;
  FTargetWnd := ANewHostWnd;
  FDCompTarget.SetRoot(FRootVisual);
  FDCompDevice.Commit;
  _UpdateBounds;
end;

procedure TAefosLazWebView.CreateWnd;
begin
  inherited CreateWnd;
  if FStarted and Assigned(FCompController) then
    // Not the first handle: it was RECREATED (the host form was docked/undocked or
    // the IDE switched layouts). Rebuild the DComp target on the fresh HWND -- the
    // controller and visual are untouched (their parent is the stable anchor).
    _Reparent(Handle)
  else
    _EnsureStarted;
end;

procedure TAefosLazWebView.DestroyWnd;
begin
  // The host HWND is about to die (reparent / dock). Release the DComp target that
  // is bound to it so it never holds a dead handle; CreateWnd rebuilds it on the new
  // HWND. The controller (parented to the stable anchor) and the root visual keep
  // compositing untouched -- nothing to re-create, no navigation lost.
  FDCompTarget := nil;
  FTargetWnd := 0;
  inherited DestroyWnd;
end;

procedure TAefosLazWebView.Resize;
begin
  inherited Resize;
  _UpdateBounds;
end;

procedure TAefosLazWebView.Paint;
begin
  // Dark placeholder behind the DComp visual until the WebView presents its first
  // frame (design time, or the ~1s cold start), so the control is never a blank hole.
  Canvas.Brush.Color := TColor($001E1E1E);
  Canvas.FillRect(ClientRect);
  if (csDesigning in ComponentState) or not FReady then
  begin
    Canvas.Font.Color := clSilver;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(8, 8, 'Aefos WebView');
  end;
end;

procedure TAefosLazWebView.SyncToHostWindow;
begin
  _Reparent(Handle);
end;

procedure TAefosLazWebView.SyncIfHostChanged;
begin
  _Reparent(Handle);
end;

function TAefosLazWebView._ShiftToKeys(
  AShift: TShiftState): COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS;
begin
  Result := 0;
  if ssLeft in AShift then Result := Result or CMkLeftButton;
  if ssRight in AShift then Result := Result or CMkRightButton;
  if ssMiddle in AShift then Result := Result or CMkMiddleButton;
  if ssShift in AShift then Result := Result or CMkShift;
  if ssCtrl in AShift then Result := Result or CMkControl;
end;

procedure TAefosLazWebView._SendMouse(AKind: COREWEBVIEW2_MOUSE_EVENT_KIND;
  AKeys: COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS; AData: Cardinal; AX, AY: Integer);
var
  LPt: tagPOINT;
begin
  // Only forward to a controller that finished creating (Ready). Input arriving
  // while the host is still materialising would touch transient composition state.
  // The try/except is belt-and-suspenders: a dropped mouse event must NEVER crash
  // the IDE (input forwarding is best-effort).
  if not (FReady and Assigned(FCompController)) then
    Exit;
  LPt.x := AX;
  LPt.y := AY;
  try
    FCompController.SendMouseInput(AKind, AKeys, AData, LPt);
  except
  end;
end;

procedure TAefosLazWebView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  LKind: COREWEBVIEW2_MOUSE_EVENT_KIND;
begin
  // Take VCL-side focus and route Win32 keyboard focus into the WebView (composition
  // delivers keys to the controller's parent = the anchor). Mirrors the Delphi
  // control's WM_LBUTTONDOWN handling.
  if CanFocus then
    SetFocus;
  FocusWebView;
  case Button of
    mbRight:  LKind := CMouseRightDown;
    mbMiddle: LKind := CMouseMiddleDown;
  else
    LKind := CMouseLeftDown;
  end;
  _SendMouse(LKind, _ShiftToKeys(Shift), 0, X, Y);
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TAefosLazWebView.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  _SendMouse(CMouseMove, _ShiftToKeys(Shift), 0, X, Y);
  inherited MouseMove(Shift, X, Y);
end;

procedure TAefosLazWebView.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  LKind: COREWEBVIEW2_MOUSE_EVENT_KIND;
begin
  case Button of
    mbRight:  LKind := CMouseRightUp;
    mbMiddle: LKind := CMouseMiddleUp;
  else
    LKind := CMouseLeftUp;
  end;
  _SendMouse(LKind, _ShiftToKeys(Shift), 0, X, Y);
  inherited MouseUp(Button, Shift, X, Y);
end;

function TAefosLazWebView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  // LCL delivers MousePos ALREADY in this control's CLIENT coordinates: the Win32
  // widgetset converts the screen-based WM_MOUSEWHEEL LParam to client space before
  // dispatching LM_MOUSEWHEEL (win32callback.inc DoMsgMouseWheel -> ScreenToClient;
  // TControl.WMMouseWheel/GetMousePosFromMessage forwards those client coords). So we
  // pass MousePos straight through -- exactly like MouseMove/MouseDown above, which
  // also receive client X/Y. A ScreenToClient here would convert TWICE: subtracting
  // the control's screen origin from an already-client point yields a negative,
  // off-surface coordinate, so WebView2 hit-tests nothing and the wheel scrolls
  // nothing (the bug the scrollbar-only symptom pointed at). NB: the Delphi edition's
  // _FwdWheel DOES ScreenToClient because raw WM_MOUSEWHEEL LParam is screen coords in
  // VCL's WndProc; the coordinate convention differs, the mouseData encoding does not.
  // mouseData is the signed wheel delta (WM_MOUSEWHEEL semantics; matches the Delphi
  // host's Cardinal(SmallInt(HiWord(WParam))) encoding).
  _SendMouse(COREWEBVIEW2_MOUSE_EVENT_KIND_WHEEL, _ShiftToKeys(Shift),
    Cardinal(WheelDelta), MousePos.X, MousePos.Y);
  Result := True;
end;

procedure TAefosLazWebView.Navigate(const AUrl: string);
var
  LWide: UnicodeString;
  LHr: HResult;
begin
  if FReady and Assigned(FWebView) then
  begin
    LWide := UTF8ToUTF16(AUrl);
    // M6: fire-and-forget -- log a synchronous failure, do not swallow it silently.
    LHr := FWebView.Navigate(PWideChar(LWide));
    if _HrFailed(LHr) then
      DebugLn(Format('[AefosAI] webview: Navigate failed hr=0x%.8x', [LHr]));
  end
  else
  begin
    FPendingUrl := AUrl;
    FPendingHtml := '';
  end;
end;

procedure TAefosLazWebView.NavigateToString(const AHtml: string);
var
  LWide: UnicodeString;
  LHr: HResult;
begin
  if FReady and Assigned(FWebView) then
  begin
    LWide := UTF8ToUTF16(AHtml);
    LHr := FWebView.NavigateToString(PWideChar(LWide));
    if _HrFailed(LHr) then
      DebugLn(Format('[AefosAI] webview: NavigateToString failed hr=0x%.8x', [LHr]));
  end
  else
  begin
    FPendingHtml := AHtml;
    FPendingUrl := '';
  end;
end;

procedure TAefosLazWebView.ExecuteScript(const AScript: string);
begin
  ExecuteScript(AScript, nil);
end;

procedure TAefosLazWebView.ExecuteScript(const AScript: string;
  const AOnResult: TWebViewScriptResult);
var
  LWide: UnicodeString;
  LHandler: ICoreWebView2ExecuteScriptCompletedHandler;
  LHr: HResult;
begin
  if not (FReady and Assigned(FWebView)) then
  begin
    if Assigned(AOnResult) then
      AOnResult(E_FAIL, '');
    Exit;
  end;
  LWide := UTF8ToUTF16(AScript);
  // The dedicated result handler captures the callback and marshals UTF-16->UTF-8;
  // WebView2 keeps it alive (AddRef) until it Invokes.
  LHandler := TAefosScriptResultHandler.Create(AOnResult);
  LHr := FWebView.ExecuteScript(PWideChar(LWide), LHandler);
  // M6: if the call fails SYNCHRONOUSLY the completion handler will never Invoke, so
  // a result-expecting caller would hang forever -- fire the callback ourselves.
  if _HrFailed(LHr) then
  begin
    if Assigned(AOnResult) then
      AOnResult(LHr, '')
    else
      DebugLn(Format('[AefosAI] webview: ExecuteScript failed hr=0x%.8x', [LHr]));
  end;
end;

procedure TAefosLazWebView.PostWebMessageAsString(const AMessage: string);
var
  LWide: UnicodeString;
  LHr: HResult;
begin
  if FReady and Assigned(FWebView) then
  begin
    LWide := UTF8ToUTF16(AMessage);
    LHr := FWebView.PostWebMessageAsString(PWideChar(LWide));
    if _HrFailed(LHr) then
      DebugLn(Format('[AefosAI] webview: PostWebMessageAsString failed hr=0x%.8x',
        [LHr]));
  end;
end;

procedure TAefosLazWebView.FocusWebView;
begin
  if Assigned(FController) then
    FController.MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
end;

end.
