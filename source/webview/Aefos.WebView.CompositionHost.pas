unit Aefos.WebView.CompositionHost;

{
  Composition (visual) WebView2 host — the core of our own WebView2 component.

  Unlike Vcl.Edge.TEdgeBrowser (windowed hosting, blanks when the host top-level
  is deactivated), this renders the WebView2 into a DirectComposition visual that
  the DWM composites independently of window activation/occlusion -> it never goes
  black when the IDE loses the foreground (e.g. to the CLI's terminal).

  Pipeline (built once the composition controller is ready):
    D3D11 device -> IDXGIDevice -> DCompositionCreateDevice -> IDCompositionDevice
    -> CreateTargetForHwnd(parent) -> CreateVisual(root) -> target.SetRoot(root)
    -> compController.RootVisualTarget := root -> device.Commit.

  This first cut handles render + navigate + script + web-message + bounds/visible.
  INPUT forwarding (mouse/keyboard/wheel) is a separate unit added next — without
  it the page renders but is not yet interactive.

  No third-party deps: WebView2 (already used) + Windows system DComp/D3D11/DXGI.
}

interface

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.IOUtils,
  Aefos.Win.WebView2,
  Winapi.D3D11, Winapi.DXGI, Winapi.D3DCommon,
  Aefos.WebView.DComp, Aefos.WebView.Types;

type
  TCompositionWebViewHost = class
  private
    FParentWnd: HWND;     // the VISIBLE host window (FHost panel) — DComp target;
                          // changes on dock/undock (rebound via Reparent).
    FAnchorWnd: HWND;     // a hidden, STABLE window that is the composition
                          // controller's parent. It never dies on dock, so the
                          // controller never stops rendering into the visual.
    FConfig: TWebViewConfig;
    FEnvironment: ICoreWebView2Environment;
    FController: ICoreWebView2Controller;
    FCompController: ICoreWebView2CompositionController;
    FWebView: ICoreWebView2;
    FDCompDevice: IDCompositionDevice;
    FDCompTarget: IDCompositionTarget;
    FRootVisual: IDCompositionVisual;
    FReady: Boolean;
    FFailed: Boolean;
    FBounds: tagRECT;
    FPendingUrl: string;
    FNavToken: EventRegistrationToken;
    FMsgToken: EventRegistrationToken;
    FOnReady: TWebViewReadyEvent;
    FOnNav: TWebViewNavigationCompletedEvent;
    FOnMsg: TWebViewMessageEvent;
    FOnFailed: TWebViewFailedEvent;
    // Signatures MUST match Aefos.Win.WebView2 Callback<>.TStdMethod2 =
    // function(P1; const P2): HResult of object stdcall.
    function _OnEnvironmentCompleted(AResult: HResult;
      const AEnv: ICoreWebView2Environment): HResult; stdcall;
    function _OnControllerCompleted(AResult: HResult;
      const ACtrl: ICoreWebView2CompositionController): HResult; stdcall;
    function _OnNavigationCompleted(ASender: ICoreWebView2;
      const AArgs: ICoreWebView2NavigationCompletedEventArgs): HResult; stdcall;
    function _OnWebMessageReceived(ASender: ICoreWebView2;
      const AArgs: ICoreWebView2WebMessageReceivedEventArgs): HResult; stdcall;
    function _SetupComposition: Boolean;
    procedure _Fail(AResult: HResult);
    // Repositions the hidden composition-anchor window to OVERLAY the visible
    // WebView's screen rectangle, so WebView2's windowed popups (HTML title
    // tooltips, <select> dropdowns, context menus) anchor at the control instead
    // of the screen's top-left (the anchor is created at 0,0). Called on every
    // bounds/move/reparent change, then NotifyParentWindowPositionChanged.
    procedure _SyncAnchorToScreen;
  public
    constructor Create(AParentWnd: HWND; const AConfig: TWebViewConfig);
    destructor Destroy; override;
    // Kicks off the async WebView2 creation. MUST be called by the owner AFTER it has
    // wired OnReady/OnFailed — a SYNCHRONOUS failure here (e.g. runtime missing ->
    // E_FAIL) calls OnFailed, which would be lost if creation ran in the ctor before
    // the callbacks were set (the old bug: env E_FAIL -> stuck on a black "Loading"
    // forever instead of firing OnFailed -> the host's text fallback).
    procedure Start;
    // Starts async creation. Navigate/ExecuteScript before ready are deferred.
    procedure Navigate(const AUrl: string);
    procedure ExecuteScript(const AScript: string); overload;
    procedure ExecuteScript(const AScript: string;
      const AOnResult: TWebViewScriptResult); overload;
    procedure PostWebMessageAsString(const AMessage: string);
    procedure SetBounds(const ARect: TRect);
    procedure SetVisible(const AVisible: Boolean);
    // Call when the parent window moved/resized so the composition re-anchors.
    procedure NotifyParentMoved;
    // Call when the HOST window's HWND was RECREATED (e.g. docking re-parents the
    // panel): the DirectComposition target is bound to the OLD hwnd and renders
    // nowhere on the new one, so rebuild the target for the new handle.
    procedure Reparent(ANewParentWnd: HWND);
    // Input forwarding (no child HWND in composition mode, so the host control
    // must hand input to the controller). AX/AY are CLIENT coords in the host.
    procedure SendMouse(AKind: COREWEBVIEW2_MOUSE_EVENT_KIND;
      AKeys: COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS; AData: Cardinal;
      AX, AY: Integer);
    // Give the WebView keyboard focus (programmatically).
    procedure FocusWebView;
    // The hidden window that is the composition controller's parent. MoveFocus
    // routes the Win32 keyboard focus here, so focus checks must recognise it as
    // "the WebView has focus" (it is NOT in the host control's window tree).
    function AnchorHandle: HWND;
    property Ready: Boolean read FReady;
    property Failed: Boolean read FFailed;
    property OnReady: TWebViewReadyEvent read FOnReady write FOnReady;
    property OnNavigationCompleted: TWebViewNavigationCompletedEvent
      read FOnNav write FOnNav;
    property OnMessageReceived: TWebViewMessageEvent read FOnMsg write FOnMsg;
    property OnFailed: TWebViewFailedEvent read FOnFailed write FOnFailed;
  end;

implementation

const
  // WebView2 SDK target version for D13 (mirrors Vcl.Edge's
  // CORE_WEBVIEW_TARGET_PRODUCT_VERSION, which is a unit-local const we can't
  // reference). An EMPTY target version makes CreateEnvironment return E_INVALIDARG.
  CWebView2TargetVersion = '137.0.3296.44';

// Diagnostic hook — appends the async-creation pipeline trace to
// %TEMP%\aefos_comp.log, but ONLY when AEFOS_WEBVIEW_TRACE is set (so it is a no-op
// in production yet instantly available to diagnose a hang/black, e.g. the Win10 VM:
// set AEFOS_WEBVIEW_TRACE=1, run, read %TEMP%\aefos_comp.log to see exactly which
// step — env / controller / D3D11 / DComp — failed or never fired). Never raises.
procedure _CompLog(const S: string);
begin
  if GetEnvironmentVariable('AEFOS_WEBVIEW_TRACE') = '' then
    Exit;
  try
    TFile.AppendAllText(TPath.Combine(TPath.GetTempPath, 'aefos_comp.log'),
      S + sLineBreak, TEncoding.UTF8);
  except
    // tracing is best-effort; never let it break the pipeline
  end;
end;

// Point the RTL's WebView2 loader at the WebView2Loader.dll we ship NEXT TO THIS BPL,
// by full path. The RTL default is LoadLibrary('WebView2Loader.dll') (bare name), which
// Windows resolves against the PROCESS exe dir (bds.exe) + system32 + PATH — NOT the
// BPL's own folder. On a machine where the loader isn't next to bds.exe, that returns 0
// and the Chat goes BLACK. Shipping it beside the BPL + pointing here makes it found,
// independent of the IDE folder / PATH. No-op if our copy isn't present (keeps the RTL
// default), so it can never make things worse.
procedure _PointWebView2Loader;
var
  LModule: array[0..MAX_PATH] of Char;
  LDir, LDll: string;
begin
  if GetModuleFileName(HInstance, LModule, Length(LModule)) = 0 then
    Exit;
  LDir := ExtractFilePath(LModule);
  LDll := LDir + 'WebView2Loader.dll';
  if FileExists(LDll) then
  begin
    SetWebView2Path(LDll);
    _CompLog('init: SetWebView2Path -> ' + LDll);
  end
  else
    _CompLog('init: bundled WebView2Loader.dll not next to BPL (' + LDir
      + '); using RTL default search');
end;

// Default WebView2 user-data folder. WebView2 needs a WRITABLE folder; passing ''
// makes it default next to the HOST exe (bds.exe, often under Program Files) which
// is not user-writable -> environment creation fails with E_ACCESSDENIED and the
// panel is blank. Anchor it under %LOCALAPPDATA% instead.
function _ResolveUserDataFolder(const AConfigured: string): string;
begin
  Result := AConfigured;
  if Result <> '' then
    Exit;
  Result := GetEnvironmentVariable('LOCALAPPDATA');
  if Result = '' then
    Result := GetEnvironmentVariable('APPDATA');
  if Result = '' then
    Exit; // let WebView2 choose its own default rather than pass a bogus path
  Result := TPath.Combine(Result, 'Aefos\WebView2');
  try
    if not TDirectory.Exists(Result) then
      TDirectory.CreateDirectory(Result);
  except
    // non-fatal: WebView2 will attempt to create it itself
  end;
end;

// Browser args. GPU compositing is what makes WebView2 render BLACK on some GPUs/
// drivers/VMs/RDP — and the Chat content is text/markdown/code, where GPU compositing
// buys nothing. So we DISABLE THE GPU BY DEFAULT: it removes the whole black-screen
// class on odd machines at no perceptible cost for text (validated 2026-06-20 — the
// composition host renders identically with --disable-gpu). Power users who want
// hardware compositing and know their GPU is fine can opt back in with the env var
// AEFOS_WEBVIEW_ENABLE_GPU. Idempotent (never double-adds the flag).
function _ResolveBrowserArgs(const AConfigured: string): string;
begin
  Result := AConfigured;
  if Pos('--disable-gpu', LowerCase(Result)) > 0 then
    Exit;
  if Trim(GetEnvironmentVariable('AEFOS_WEBVIEW_ENABLE_GPU')) <> '' then
    Exit; // explicit opt-in to GPU compositing
  Result := Trim(Result + ' --disable-gpu');
end;

{ TCompositionWebViewHost }

constructor TCompositionWebViewHost.Create(AParentWnd: HWND;
  const AConfig: TWebViewConfig);
begin
  inherited Create;
  FParentWnd := AParentWnd;
  // Hidden, stable parent for the composition controller (a plain STATIC popup,
  // never shown, owned by this BPL). Survives every dock/undock HWND recreate, so
  // the controller keeps compositing into the visual no matter what the dock does.
  FAnchorWnd := CreateWindowEx(0, 'STATIC', nil, WS_POPUP, 0, 0, 0, 0, 0, 0,
    HInstance, nil);
  FConfig := AConfig;
  // NOTE: the WebView2 environment is created in Start (not here) so the owner can
  // wire OnReady/OnFailed first — a synchronous E_FAIL must reach OnFailed.
end;

procedure TCompositionWebViewHost.Start;
var
  LOptions: ICoreWebView2EnvironmentOptions;
  LBrowserFolder, LUserFolder: string;
  LHr: HResult;
begin
  LOptions := TCoreWebView2EnvironmentOptions.Create;
  // Mirror Vcl.Edge exactly (avoids E_INVALIDARG): set ALL option fields and pass
  // PChar('') (not nil) for the browser-executable folder.
  LOptions.Set_AdditionalBrowserArguments(
    PChar(_ResolveBrowserArgs(FConfig.AdditionalBrowserArguments)));
  LOptions.Set_Language(PChar(''));
  LOptions.Set_TargetCompatibleBrowserVersion(PChar(CWebView2TargetVersion));
  LOptions.Set_AllowSingleSignOnUsingOSPrimaryAccount(0);
  LBrowserFolder := '';
  // Force a writable user-data folder (a blank one points at the read-only IDE dir).
  LUserFolder := _ResolveUserDataFolder(FConfig.UserDataFolder);
  LHr := CreateCoreWebView2EnvironmentWithOptions(PChar(LBrowserFolder),
    PChar(LUserFolder), LOptions,
    Callback<HResult, ICoreWebView2Environment>.CreateAs<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
      _OnEnvironmentCompleted));
  _CompLog(Format('Start: CreateEnvironmentWithOptions hr=%.8x', [LHr]));
  if Winapi.Windows.Failed(LHr) then
    _Fail(LHr);
end;

destructor TCompositionWebViewHost.Destroy;
begin
  if Assigned(FWebView) then
  begin
    if FNavToken.value <> 0 then
      FWebView.remove_NavigationCompleted(FNavToken);
    if FMsgToken.value <> 0 then
      FWebView.remove_WebMessageReceived(FMsgToken);
  end;
  if Assigned(FController) then
    FController.Close;
  FRootVisual := nil;
  FDCompTarget := nil;
  FDCompDevice := nil;
  FWebView := nil;
  FCompController := nil;
  FController := nil;
  FEnvironment := nil;
  if FAnchorWnd <> 0 then
  begin
    DestroyWindow(FAnchorWnd);
    FAnchorWnd := 0;
  end;
  inherited;
end;

procedure TCompositionWebViewHost._Fail(AResult: HResult);
begin
  FFailed := True;
  if Assigned(FOnFailed) then
    FOnFailed(AResult);
end;

function TCompositionWebViewHost._OnEnvironmentCompleted(AResult: HResult;
  const AEnv: ICoreWebView2Environment): HResult; stdcall;
var
  LEnv3: ICoreWebView2Environment3;
  LHr: HResult;
begin
  Result := S_OK;
  _CompLog(Format('_OnEnvironmentCompleted hr=%.8x env=%d', [AResult, Ord(Assigned(AEnv))]));
  if Winapi.Windows.Failed(AResult) or not Assigned(AEnv) then
  begin
    _Fail(AResult);
    Exit;
  end;
  FEnvironment := AEnv;
  if not Supports(AEnv, ICoreWebView2Environment3, LEnv3) then
  begin
    _CompLog('  env3 QI FAILED');
    _Fail(E_NOINTERFACE);
    Exit;
  end;
  LHr := LEnv3.CreateCoreWebView2CompositionController(FAnchorWnd,
    Callback<HResult, ICoreWebView2CompositionController>.CreateAs<ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler>(
      _OnControllerCompleted));
  _CompLog(Format('  CreateCompositionController hr=%.8x', [LHr]));
  if Winapi.Windows.Failed(LHr) then
    _Fail(LHr);
end;

function TCompositionWebViewHost._OnControllerCompleted(AResult: HResult;
  const ACtrl: ICoreWebView2CompositionController): HResult; stdcall;
var
  LColor: COREWEBVIEW2_COLOR;
  LController2: ICoreWebView2Controller2;
begin
  Result := S_OK;
  _CompLog(Format('_OnControllerCompleted hr=%.8x ctrl=%d', [AResult, Ord(Assigned(ACtrl))]));
  if Winapi.Windows.Failed(AResult) or not Assigned(ACtrl) then
  begin
    _Fail(AResult);
    Exit;
  end;
  FCompController := ACtrl;
  if not Supports(ACtrl, ICoreWebView2Controller, FController) then
  begin
    _CompLog('  controller QI FAILED');
    _Fail(E_NOINTERFACE);
    Exit;
  end;
  if not _SetupComposition then
  begin
    _CompLog('  _SetupComposition FAILED');
    _Fail(E_FAIL);
    Exit;
  end;
  _CompLog('  _SetupComposition OK');
  FController.Get_CoreWebView2(FWebView);
  if not Assigned(FWebView) then
  begin
    _Fail(E_FAIL);
    Exit;
  end;
  // anti-flash background — APPLY the computed color. It used to be computed and
  // then DROPPED (Set_DefaultBackgroundColor was never called), so the panel flashed
  // BLACK during the WebView2 cold-load until the page painted. DefaultBackgroundColor
  // (ICoreWebView2Controller2) paints the dark shell colour behind the page from the
  // first frame, so the load looks like a quick dark->content fade, not a black flash.
  LColor.A := Byte(FConfig.DefaultBackgroundColorBGRA shr 24);
  LColor.R := Byte(FConfig.DefaultBackgroundColorBGRA shr 16);
  LColor.G := Byte(FConfig.DefaultBackgroundColorBGRA shr 8);
  LColor.B := Byte(FConfig.DefaultBackgroundColorBGRA);
  if Supports(FController, ICoreWebView2Controller2, LController2) then
    LController2.Set_DefaultBackgroundColor(LColor);
  // events
  FWebView.add_NavigationCompleted(
    Callback<ICoreWebView2, ICoreWebView2NavigationCompletedEventArgs>.CreateAs<ICoreWebView2NavigationCompletedEventHandler>(
      _OnNavigationCompleted), FNavToken);
  FWebView.add_WebMessageReceived(
    Callback<ICoreWebView2, ICoreWebView2WebMessageReceivedEventArgs>.CreateAs<ICoreWebView2WebMessageReceivedEventHandler>(
      _OnWebMessageReceived), FMsgToken);
  FController.Set_IsVisible(1);
  FController.Set_Bounds(FBounds);
  FReady := True;
  // Anchor windowed popups (tooltips/dropdowns) at the control now that the
  // controller exists and FBounds is known (SetBounds ran before ready).
  _SyncAnchorToScreen;
  FController.NotifyParentWindowPositionChanged;
  if Assigned(FOnReady) then
    FOnReady();
  if FPendingUrl <> '' then
  begin
    FWebView.Navigate(PChar(FPendingUrl));
    FPendingUrl := '';
  end;
end;

function TCompositionWebViewHost._SetupComposition: Boolean;
var
  LFlags: UINT;
  LFeatureLevel: TD3D_FEATURE_LEVEL;
  LDevice: ID3D11Device;
  LContext: ID3D11DeviceContext;
  LDxgiDevice: IDXGIDevice;
  LHr: HResult;
begin
  Result := False;
  LFlags := D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  LHr := D3D11CreateDevice(nil, D3D_DRIVER_TYPE_HARDWARE, 0, LFlags, nil, 0,
    D3D11_SDK_VERSION, LDevice, LFeatureLevel, LContext);
  if Winapi.Windows.Failed(LHr) then
    // retry with WARP (software) — VMs/RDP have no hardware device
    LHr := D3D11CreateDevice(nil, D3D_DRIVER_TYPE_WARP, 0, LFlags, nil, 0,
      D3D11_SDK_VERSION, LDevice, LFeatureLevel, LContext);
  _CompLog(Format('    D3D11CreateDevice hr=%.8x dev=%d', [LHr, Ord(Assigned(LDevice))]));
  if Winapi.Windows.Failed(LHr) or not Assigned(LDevice) then
    Exit;
  if not Supports(LDevice, IDXGIDevice, LDxgiDevice) then
  begin
    _CompLog('    IDXGIDevice QI FAILED');
    Exit;
  end;
  LHr := DCompositionCreateDevice(LDxgiDevice, IID_IDCompositionDevice, FDCompDevice);
  _CompLog(Format('    DCompositionCreateDevice hr=%.8x', [LHr]));
  if Winapi.Windows.Failed(LHr) then
    Exit;
  LHr := FDCompDevice.CreateTargetForHwnd(FParentWnd, True, FDCompTarget);
  _CompLog(Format('    CreateTargetForHwnd hr=%.8x', [LHr]));
  if Winapi.Windows.Failed(LHr) then
    Exit;
  LHr := FDCompDevice.CreateVisual(FRootVisual);
  _CompLog(Format('    CreateVisual hr=%.8x', [LHr]));
  if Winapi.Windows.Failed(LHr) then
    Exit;
  LHr := FDCompTarget.SetRoot(FRootVisual);
  _CompLog(Format('    SetRoot hr=%.8x', [LHr]));
  if Winapi.Windows.Failed(LHr) then
    Exit;
  LHr := FCompController.Set_RootVisualTarget(FRootVisual);
  _CompLog(Format('    Set_RootVisualTarget hr=%.8x', [LHr]));
  if Winapi.Windows.Failed(LHr) then
    Exit;
  FDCompDevice.Commit;
  Result := True;
end;

function TCompositionWebViewHost._OnNavigationCompleted(ASender: ICoreWebView2;
  const AArgs: ICoreWebView2NavigationCompletedEventArgs): HResult; stdcall;
var
  LSuccess: Integer;
begin
  Result := S_OK;
  LSuccess := 0;
  if Assigned(AArgs) then
    AArgs.Get_IsSuccess(LSuccess);
  if Assigned(FOnNav) then
    FOnNav(LSuccess <> 0);
end;

function TCompositionWebViewHost._OnWebMessageReceived(ASender: ICoreWebView2;
  const AArgs: ICoreWebView2WebMessageReceivedEventArgs): HResult; stdcall;
var
  LRaw: PWideChar;
begin
  Result := S_OK;
  if not Assigned(FOnMsg) or not Assigned(AArgs) then
    Exit;
  LRaw := nil;
  if Succeeded(AArgs.TryGetWebMessageAsString(LRaw)) and (LRaw <> nil) then
  begin
    FOnMsg(string(LRaw));
    CoTaskMemFree(LRaw);
  end;
end;

procedure TCompositionWebViewHost.Navigate(const AUrl: string);
begin
  if FReady and Assigned(FWebView) then
    FWebView.Navigate(PChar(AUrl))
  else
    FPendingUrl := AUrl;
end;

procedure TCompositionWebViewHost.ExecuteScript(const AScript: string);
begin
  if FReady and Assigned(FWebView) then
    FWebView.ExecuteScript(PChar(AScript),
      Callback<HResult, PWideChar>.CreateAs<ICoreWebView2ExecuteScriptCompletedHandler>(
        function(AErrorCode: HResult; AResultObjectAsJson: PWideChar): HResult stdcall
        begin
          Result := S_OK;
        end));
end;

procedure TCompositionWebViewHost.ExecuteScript(const AScript: string;
  const AOnResult: TWebViewScriptResult);
var
  LOnResult: TWebViewScriptResult;
begin
  LOnResult := AOnResult;
  if FReady and Assigned(FWebView) then
    FWebView.ExecuteScript(PChar(AScript),
      Callback<HResult, PWideChar>.CreateAs<ICoreWebView2ExecuteScriptCompletedHandler>(
        function(AErrorCode: HResult; AResultObjectAsJson: PWideChar): HResult stdcall
        begin
          if Assigned(LOnResult) then
            LOnResult(AErrorCode, string(AResultObjectAsJson));
          Result := S_OK;
        end))
  else if Assigned(LOnResult) then
    LOnResult(E_FAIL, '');
end;

procedure TCompositionWebViewHost.PostWebMessageAsString(const AMessage: string);
begin
  if FReady and Assigned(FWebView) then
    FWebView.PostWebMessageAsString(PChar(AMessage));
end;

procedure TCompositionWebViewHost._SyncAnchorToScreen;
var
  LOrigin: TPoint;
begin
  // WebView2 positions windowed popups relative to the controller's parent window
  // (FAnchorWnd) — created at (0,0). Move that invisible anchor so its client
  // origin sits at the WebView's true screen origin; then popups land at the
  // control, not the screen corner. ClientToScreen on FParentWnd (the control's
  // HWND) gives that origin; FBounds.TopLeft cancels out (applied to both the
  // controller Bounds and the desired position), so the anchor goes to the
  // control's client-area screen origin, sized to the WebView rect.
  if (FAnchorWnd = 0) or (FParentWnd = 0) then
    Exit;
  LOrigin.X := 0;
  LOrigin.Y := 0;
  Winapi.Windows.ClientToScreen(FParentWnd, LOrigin);
  SetWindowPos(FAnchorWnd, 0, LOrigin.X, LOrigin.Y,
    FBounds.right - FBounds.left, FBounds.bottom - FBounds.top,
    SWP_NOZORDER or SWP_NOACTIVATE or SWP_NOREDRAW or SWP_NOOWNERZORDER);
end;

procedure TCompositionWebViewHost.SetBounds(const ARect: TRect);
begin
  // TRect (System.Types) -> tagRECT (Winapi.WebView2): same layout, distinct types.
  FBounds.left := ARect.Left;
  FBounds.top := ARect.Top;
  FBounds.right := ARect.Right;
  FBounds.bottom := ARect.Bottom;
  if FReady and Assigned(FController) then
  begin
    FController.Set_Bounds(FBounds);
    _SyncAnchorToScreen;
    FController.NotifyParentWindowPositionChanged;
    if Assigned(FDCompDevice) then
      FDCompDevice.Commit;
  end;
end;

procedure TCompositionWebViewHost.SetVisible(const AVisible: Boolean);
begin
  if FReady and Assigned(FController) then
    FController.Set_IsVisible(Ord(AVisible));
end;

procedure TCompositionWebViewHost.NotifyParentMoved;
begin
  if FReady and Assigned(FController) then
  begin
    _SyncAnchorToScreen;
    FController.NotifyParentWindowPositionChanged;
  end;
end;

procedure TCompositionWebViewHost.SendMouse(AKind: COREWEBVIEW2_MOUSE_EVENT_KIND;
  AKeys: COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS; AData: Cardinal; AX, AY: Integer);
var
  LPt: tagPOINT;
begin
  if not (FReady and Assigned(FCompController)) then
    Exit;
  LPt.x := AX;
  LPt.y := AY;
  FCompController.SendMouseInput(AKind, AKeys, AData, LPt);
end;

procedure TCompositionWebViewHost.FocusWebView;
begin
  if FReady and Assigned(FController) then
    FController.MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
end;

function TCompositionWebViewHost.AnchorHandle: HWND;
begin
  Result := FAnchorWnd;
end;

procedure TCompositionWebViewHost.Reparent(ANewParentWnd: HWND);
var
  LHr: HResult;
begin
  _CompLog(Format('Reparent: new=%x old=%x ready=%d', [ANewParentWnd, FParentWnd, Ord(FReady)]));
  if not FReady or not Assigned(FDCompDevice) then
    Exit;
  FParentWnd := ANewParentWnd;
  // Rebuild the DComp target on the new hwnd (the old one is dead after the
  // recreate). The root visual (with the WebView content) is re-attached, so no
  // re-navigation / no flash.
  FDCompTarget := nil;
  LHr := FDCompDevice.CreateTargetForHwnd(ANewParentWnd, True, FDCompTarget);
  _CompLog(Format('  CreateTargetForHwnd hr=%.8x', [LHr]));
  if Winapi.Windows.Succeeded(LHr) then
  begin
    FDCompTarget.SetRoot(FRootVisual);
    FDCompDevice.Commit;
  end;
  if Assigned(FController) then
  begin
    FController.Set_Bounds(FBounds);
    _SyncAnchorToScreen;
    FController.NotifyParentWindowPositionChanged;
  end;
end;

initialization
  // Resolve the WebView2 loader from beside this BPL (if shipped) before any WebView2
  // call — must run once at BPL load. See _PointWebView2Loader.
  _PointWebView2Loader;

end.
