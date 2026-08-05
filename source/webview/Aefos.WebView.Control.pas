unit Aefos.WebView.Control;

{
  TAefosWebView — VCL control Facade over the composition WebView host.

  Drop it on a form/panel like any control. It owns a TCompositionWebViewHost and:
   * creates it once the control's HWND exists (CreateWnd), and RE-binds it on every
     HWND recreate (dock/undock) via Reparent — so docking never blanks it;
   * forwards input to the WebView via the control's OWN WndProc (composition mode
     has no child HWND, so input must be relayed). This is teardown-safe: it is the
     control's own WndProc, not an external hook (the unbalanced-hook unload AV is
     not possible here).

  This first cut forwards MOUSE + WHEEL. Keyboard is added next (it is the trickier
  part of composition hosting).
}

interface

uses
  Winapi.Windows, Winapi.Messages, System.Classes, System.SysUtils,
  System.Types, Vcl.Controls, Vcl.Graphics, Aefos.Win.WebView2, Aefos.WebView.Types,
  Aefos.WebView.CompositionHost;

type
  TAefosWebView = class(TCustomControl)
  private
    FHost: TCompositionWebViewHost;
    FConfig: TWebViewConfig;
    FConfigured: Boolean;
    FPendingUrl: string;
    FOnReady: TWebViewReadyEvent;
    FOnNav: TWebViewNavigationCompletedEvent;
    FOnMsg: TWebViewMessageEvent;
    FOnFailed: TWebViewFailedEvent;
    procedure _EnsureHost;
    procedure _FwdMouse(AKind: COREWEBVIEW2_MOUSE_EVENT_KIND;
      const AMsg: TMessage);
    procedure _FwdWheel(const AMsg: TMessage);
  protected
    procedure CreateWnd; override;
    procedure Resize; override;
    procedure Paint; override;
    procedure WndProc(var Message: TMessage); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Set creation options BEFORE the control is shown (before the HWND exists).
    procedure Configure(const AConfig: TWebViewConfig);
    procedure Navigate(const AUrl: string);
    procedure ExecuteScript(const AScript: string); overload;
    procedure ExecuteScript(const AScript: string;
      const AOnResult: TWebViewScriptResult); overload;
    procedure PostWebMessageAsString(const AMessage: string);
    // Give the WebView keyboard focus programmatically.
    procedure FocusWebView;
    // The composition controller's hidden focus-host window (MoveFocus routes the
    // Win32 focus there). Focus checks must treat it as "this WebView has focus".
    function AnchorHandle: HWND;
    // True when the Win32 keyboard focus is on this control or its focus anchor
    // (or a child of either). Lets callers avoid a re-focus loop.
    function OwnsFocus: Boolean;
    property OnReady: TWebViewReadyEvent read FOnReady write FOnReady;
    property OnNavigationCompleted: TWebViewNavigationCompletedEvent
      read FOnNav write FOnNav;
    property OnMessageReceived: TWebViewMessageEvent read FOnMsg write FOnMsg;
    property OnFailed: TWebViewFailedEvent read FOnFailed write FOnFailed;
  published
    // Surface the standard control props for the designer + host code (OnEnter/
    // OnExit are protected on TControl; the chat tracks focus through them).
    property Align;
    property Anchors;
    property TabStop default True;
    property Visible;
    property OnEnter;
    property OnExit;
  end;

implementation

{ TAefosWebView }

constructor TAefosWebView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FConfig := TWebViewConfig.Default;
  // Composition paints everything; let the control accept focus + clicks.
  ControlStyle := ControlStyle - [csOpaque];
  TabStop := True;
end;

destructor TAefosWebView.Destroy;
begin
  FreeAndNil(FHost);
  inherited;
end;

procedure TAefosWebView.Configure(const AConfig: TWebViewConfig);
begin
  FConfig := AConfig;
  FConfigured := True;
end;

procedure TAefosWebView._EnsureHost;
begin
  // Never spin up a real WebView2 inside the form designer — just paint a
  // placeholder (see Paint). Keeps the component droppable without freezing the IDE.
  if (csDesigning in ComponentState) or not HandleAllocated then
    Exit;
  if Assigned(FHost) then
  begin
    FHost.Reparent(Handle);
    FHost.SetBounds(ClientRect);
    Exit;
  end;
  FHost := TCompositionWebViewHost.Create(Handle, FConfig);
  FHost.OnReady := procedure
    begin
      Invalidate; // clear the "Loading…" placeholder; the WebView frame takes over
      if Assigned(FOnReady) then FOnReady();
    end;
  FHost.OnNavigationCompleted := procedure(const ASuccess: Boolean)
    begin
      if Assigned(FOnNav) then FOnNav(ASuccess);
    end;
  FHost.OnMessageReceived := procedure(const AMessage: string)
    begin
      if Assigned(FOnMsg) then FOnMsg(AMessage);
    end;
  FHost.OnFailed := procedure(const AHResult: HRESULT)
    begin
      if Assigned(FOnFailed) then FOnFailed(AHResult);
    end;
  // Start AFTER the callbacks are wired: a synchronous failure (e.g. WebView2 runtime
  // missing -> E_FAIL) must reach OnFailed so the host can show its text fallback
  // instead of hanging on a black panel forever.
  FHost.Start;
  FHost.SetBounds(ClientRect);
  if FPendingUrl <> '' then
  begin
    FHost.Navigate(FPendingUrl);
    FPendingUrl := '';
  end;
end;

procedure TAefosWebView.CreateWnd;
begin
  inherited CreateWnd;
  // Created on first show; on later recreates (dock/undock) this re-binds the host.
  _EnsureHost;
end;

procedure TAefosWebView.Resize;
begin
  inherited Resize;
  if Assigned(FHost) then
    FHost.SetBounds(ClientRect);
end;

procedure TAefosWebView.Paint;
const
  CLabel   = 'Aefos WebView (composition)';
  CLoading = 'Loading Aefos' + #$2026; // ellipsis
var
  LRect: TRect;
begin
  // At design time (or before the host renders) the DComp visual isn't there, so
  // paint a dark placeholder so the control is visible in the form designer.
  Canvas.Brush.Color := $001E1E1E;
  Canvas.FillRect(ClientRect);
  if csDesigning in ComponentState then
  begin
    Canvas.Font.Color := clSilver;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(8, 8, CLabel);
    Exit;
  end;
  // Runtime: the WebView2 cold-start (spawn the Edge runtime + composition
  // controller + first frame) takes ~1s on first open, during which the DComp
  // visual hasn't presented yet — so paint a branded "loading" hint centered on the
  // dark shell. The open then looks intentional instead of a black freeze; once the
  // host is Ready, the WebView frame composites over this (we Invalidate on ready).
  if (not Assigned(FHost)) or (not FHost.Ready) then
  begin
    Canvas.Font.Color := $00808080;
    Canvas.Brush.Style := bsClear;
    LRect := ClientRect;
    Winapi.Windows.DrawText(Canvas.Handle, CLoading, -1, LRect,
      DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
  end;
end;

procedure TAefosWebView.Navigate(const AUrl: string);
begin
  if Assigned(FHost) then
    FHost.Navigate(AUrl)
  else
    FPendingUrl := AUrl;
end;

procedure TAefosWebView.ExecuteScript(const AScript: string);
begin
  if Assigned(FHost) then
    FHost.ExecuteScript(AScript);
end;

procedure TAefosWebView.ExecuteScript(const AScript: string;
  const AOnResult: TWebViewScriptResult);
begin
  if Assigned(FHost) then
    FHost.ExecuteScript(AScript, AOnResult)
  else if Assigned(AOnResult) then
    AOnResult(E_FAIL, '');
end;

procedure TAefosWebView.FocusWebView;
begin
  if Assigned(FHost) then
    FHost.FocusWebView;
end;

function TAefosWebView.AnchorHandle: HWND;
begin
  if Assigned(FHost) then
    Result := FHost.AnchorHandle
  else
    Result := 0;
end;

function TAefosWebView.OwnsFocus: Boolean;
var
  LFocus, LAnchor, LSelf: HWND;
begin
  Result := False;
  LFocus := GetFocus;
  if LFocus = 0 then
    Exit;
  LAnchor := AnchorHandle;
  if HandleAllocated then
    LSelf := Handle
  else
    LSelf := 0;
  // Walk up so a child of either the control or the anchor still counts.
  while LFocus <> 0 do
  begin
    if ((LSelf <> 0) and (LFocus = LSelf)) or
       ((LAnchor <> 0) and (LFocus = LAnchor)) then
      Exit(True);
    LFocus := GetParent(LFocus);
  end;
end;

procedure TAefosWebView.PostWebMessageAsString(const AMessage: string);
begin
  if Assigned(FHost) then
    FHost.PostWebMessageAsString(AMessage);
end;

procedure TAefosWebView._FwdMouse(AKind: COREWEBVIEW2_MOUSE_EVENT_KIND;
  const AMsg: TMessage);
begin
  // Only forward to a host that finished creating (Ready). A mouse message arriving
  // while the host is still materialising / re-docking (e.g. a double-click right
  // after the panel opens) would otherwise touch transient composition state and
  // raise inside the IDE message loop (System.Error in _FwdMouse). The try/except is
  // belt-and-suspenders: a dropped mouse event must NEVER crash the IDE.
  if not (Assigned(FHost) and FHost.Ready) then
    Exit;
  try
    // mouse messages: WParam lo = MK_ flags; LParam = client x/y (signed).
    FHost.SendMouse(AKind, LoWord(AMsg.WParam), 0,
      SmallInt(LoWord(AMsg.LParam)), SmallInt(HiWord(AMsg.LParam)));
  except
    // swallow: input forwarding is best-effort, never fatal.
  end;
end;

procedure TAefosWebView._FwdWheel(const AMsg: TMessage);
var
  LPt: TPoint;
begin
  if not (Assigned(FHost) and FHost.Ready) then
    Exit;
  try
    // WM_MOUSEWHEEL: LParam = SCREEN coords -> convert to client; WParam hi = delta.
    LPt := ScreenToClient(Point(SmallInt(LoWord(AMsg.LParam)),
      SmallInt(HiWord(AMsg.LParam))));
    FHost.SendMouse(COREWEBVIEW2_MOUSE_EVENT_KIND_WHEEL, LoWord(AMsg.WParam),
      Cardinal(SmallInt(HiWord(AMsg.WParam))), LPt.X, LPt.Y);
  except
    // swallow: input forwarding is best-effort, never fatal.
  end;
end;

procedure TAefosWebView.WndProc(var Message: TMessage);
begin
  case Message.Msg of
    WM_MOUSEMOVE,
    WM_LBUTTONUP, WM_LBUTTONDBLCLK,
    WM_RBUTTONDOWN, WM_RBUTTONUP, WM_RBUTTONDBLCLK,
    WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MBUTTONDBLCLK:
      _FwdMouse(Message.Msg, Message);
    WM_LBUTTONDOWN:
      begin
        if CanFocus then
          SetFocus;            // VCL focus to this control
        if Assigned(FHost) then
          FHost.FocusWebView;  // and the WebView content
        _FwdMouse(WM_LBUTTONDOWN, Message);
      end;
    WM_MOUSEWHEEL:
      _FwdWheel(Message);
  end;
  inherited WndProc(Message);
end;

end.
