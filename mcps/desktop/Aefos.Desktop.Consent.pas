unit Aefos.Desktop.Consent;

{
  ============================================================================
  Aefos Desktop MCP - TRUSTED HUMAN-CONSENT WINDOW (feat/desktop-mcp, PHASE 6).
  KEY 4: synchronous physical-human confirmation for the DESTRUCTIVE tier.
  ============================================================================

  THE RECURSION THIS UNIT CLOSES. The Desktop MCP drives Windows apps. Left
  undefended, the agent could point its own automation (desktop_invoke / UIA
  Invoke / SendInput) at THIS consent window and "press Yes" to self-approve an
  irreversible action (close window / kill process). The guard
  (Aefos.Desktop.Guard) already refuses the destructive tier with
  desktop-requires-confirmation unless a boolean AConfirmed is true; this unit is
  the ONLY trusted producer of that boolean, and it produces it ONLY from a REAL
  physical human keypress.

  HOW. Windows flags every SendInput/UIA-synthesised key event with LLKHF_INJECTED
  on the low-level keyboard hook (WH_KEYBOARD_LL). Phase 3's InjectedInputProbe
  PROVED this is reliable. So the consent decision is gated on that flag: an
  injected key is IGNORED, always. A MessageBox is FORBIDDEN here - its buttons
  are UIA-invokable and SendInput-able, defeating the defense - so we build a
  custom top-level window and gate its confirmation on the LL hook.

  FAIL-CLOSED. A non-interactive window station (CI / headless / a service)
  returns immediately with 'no-interactive-session' rather than hanging for the
  timeout. A timeout with no physical confirmation returns Confirmed=False. The
  ONLY path to Confirmed=True is a real human physically pressing Y or Enter.

  Winapi.Windows-bound (console context - no VCL, no ToolsAPI); compiles clean in
  the pure-test console build so TDesktopConsent.ConfirmKeyDecision is unit-testable.
  English only, everywhere.
}

interface

uses
  Winapi.Windows,   // HWND — the confirmation is anchored to a window
  System.SysUtils;

type
  TDesktopKeyAction = (dkaIgnore, dkaConfirm, dkaDecline);

  TDesktopConfirmResult = record
    Confirmed: Boolean;
    Reason: string;   // 'confirmed' | 'declined' | 'timed-out' | 'no-interactive-session'
  end;

type
  // Static, sealed namespace for the KEY-4 human-consent surface. Never
  // instantiated (no constructor): both routines are class functions so they have
  // a named owner (TDesktopConsent.RequestConfirmation) instead of floating free
  // in the unit interface.
  TDesktopConsent = class sealed
  public
    // PURE decision (unit-testable, no Windows calls): given a key event's virtual-key
    // code and whether Windows flagged it INJECTED (LLKHF_INJECTED), decide.
    //   AInjected=True  => dkaIgnore ALWAYS (closes the self-confirmation recursion).
    //   physical Ord('Y') or VK_RETURN => dkaConfirm
    //   physical Ord('N') or VK_ESCAPE => dkaDecline
    //   any other physical key         => dkaIgnore
    class function ConfirmKeyDecision(AVk: Word; AInjected: Boolean): TDesktopKeyAction; static;

    // Shows a trusted, topmost consent window OWNED by THIS process (works while the
    // server serves stdio; needs no IDE UI). ATitle is short; ASummary is the full
    // sentence describing the irreversible action. Returns Confirmed=True ONLY when a
    // real physical human presses the confirm key. Fails CLOSED: a non-interactive
    // window station returns immediately (reason 'no-interactive-session'); a timeout
    // with no physical confirm returns Confirmed=False (reason 'timed-out').
    { AAnchorWnd is the window the action is ABOUT. It is used only to pick the
      MONITOR to appear on: a confirmation centred on the primary display while
      the user is working on the second one is, from their side, a dialog that
      never appeared -- and it times out looking exactly like a refusal. Pass 0
      when there is no anchor and the foreground window is used instead. }
    { AHeading is the question in the user's terms ("Close this window?").
      ASummary is the consequence. ATarget names WHAT is being acted on. Three
      strings rather than one because the old single line gave a user no
      hierarchy: the act, the thing and the key that answers all read the same,
      and the one fact nobody can guess -- that only a physical key counts --
      was not on screen at all. }
    class function RequestConfirmation(const AAnchorWnd: HWND;
      const ATitle, AHeading, ASummary, ATarget, ANote: string;
      ATimeoutMs: Cardinal): TDesktopConfirmResult; static;
  end;

implementation

uses
  Winapi.Messages;

const
  // The LLKHF_INJECTED bit on the WH_KEYBOARD_LL flags field. Declared locally
  // (same single-source discipline as the InjectedInputProbe) because not every
  // supported RTL exposes it. This is the load-bearing bit: it distinguishes a
  // real physical key from any SendInput/UIA-synthesised one.
  LLKHF_INJECTED_BIT = $00000010;

  // GetUserObjectInformation info class + the WSF_VISIBLE flag of a window
  // station. A non-visible (non-interactive) station means no human can see or
  // reach the window - fail closed rather than hang.
  UOI_FLAGS_LOCAL   = 1;
  WSF_VISIBLE_LOCAL = $0001;

  // SetWindowDisplayAffinity: exclude the consent window from screen capture, so
  // the agent's own desktop_window_capture cannot photograph the dialog to read
  // (or OCR) what it is confirming. Best-effort hardening.
  WDA_EXCLUDEFROMCAPTURE_LOCAL = $00000011;

  CConsentClassName = 'AefosDesktopConsentWnd';

type
  // The WH_KEYBOARD_LL payload. Declared locally (single-source discipline) -
  // only `flags` (LLKHF_INJECTED) and `vkCode` are read.
  TKbdLLHookStruct = record
    vkCode: DWORD;
    scanCode: DWORD;
    flags: DWORD;
    time: DWORD;
    dwExtraInfo: ULONG_PTR;
  end;
  PKbdLLHookStruct = ^TKbdLLHookStruct;

  // The USEROBJECTFLAGS struct filled by GetUserObjectInformation(UOI_FLAGS).
  // Declared locally because the RTL does not surface it.
  TUserObjectFlags = record
    fInherit: BOOL;
    fReserved: BOOL;
    dwFlags: DWORD;
  end;

// Unicode GetUserObjectInformation, imported locally.
function GetUserObjectInformationW(hObj: THandle; nIndex: Integer;
  pvInfo: Pointer; nLength: DWORD; lpnLengthNeeded: PDWORD): BOOL; stdcall;
  external 'user32.dll' name 'GetUserObjectInformationW';

function SetWindowDisplayAffinity(hWnd: HWND; dwAffinity: DWORD): BOOL; stdcall;
  external 'user32.dll' name 'SetWindowDisplayAffinity';

const
  // Dark window chrome (Win10 1809+). Without it the OS paints a LIGHT title bar
  // over a dark body, which was the one thing still visibly out of place. 20 is
  // the documented attribute; 19 was the pre-20H1 value and is tried as a
  // fallback. Best-effort by design: an older Windows simply keeps light chrome.
  DWMWA_USE_IMMERSIVE_DARK_MODE     = 20;
  DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;

function DwmSetWindowAttribute(hwnd: HWND; dwAttribute: DWORD;
  pvAttribute: Pointer; cbAttribute: DWORD): HRESULT; stdcall;
  external 'dwmapi.dll' name 'DwmSetWindowAttribute';

// Asks the OS for dark chrome. Never raises and never fails the caller: a light
// title bar is cosmetic, and this window must open no matter what.
procedure _UseDarkChrome(const AWnd: HWND);
var
  LOn: BOOL;
begin
  LOn := True;
  try
    if Failed(DwmSetWindowAttribute(AWnd, DWMWA_USE_IMMERSIVE_DARK_MODE,
      @LOn, SizeOf(LOn))) then
      DwmSetWindowAttribute(AWnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD,
        @LOn, SizeOf(LOn));
  except
    // dwmapi missing on an ancient Windows: keep the light chrome.
  end;
end;

const
  // Multi-monitor placement. Declared inline for the same reason the affinity
  // constants above are: this unit's namespace set does not surface MultiMon, and
  // an inline frozen-ABI declaration beats widening the unit path for two calls.
  MONITOR_DEFAULTTONEAREST = $00000002;

type
  HMONITOR = THandle;
  TAefosMonitorInfo = record
    cbSize: DWORD;
    rcMonitor: TRect;
    rcWork: TRect;
    dwFlags: DWORD;
  end;

function MonitorFromWindow(hWnd: HWND; dwFlags: DWORD): HMONITOR; stdcall;
  external 'user32.dll' name 'MonitorFromWindow';
function GetMonitorInfoW(hMonitor: HMONITOR;
  var lpmi: TAefosMonitorInfo): BOOL; stdcall;
  external 'user32.dll' name 'GetMonitorInfoW';

var
  // Single-confirmation-at-a-time state, shared with the LL hook (which is a
  // global stdcall callback delivered to the installing thread).
  GKbdHook: HHOOK = 0;
  GConsentWnd: HWND = 0;       // the trusted dialog; a key counts ONLY when it is foreground
  GDecided: Boolean = False;   // a physical Y/N/Enter/Esc has resolved the dialog
  GConfirmed: Boolean = False; // ... and it was a confirm (Y/Enter)
  GSummaryText: string = '';   // painted body text
  // NOT a repeat of the key caps drawn right above it -- that line used to say
  // "Press Y to ALLOW - N or Esc to DENY", which the caps already show. This is
  // the one fact a user cannot deduce from looking, and the reason this window
  // is a hand-built popup instead of a normal dialog.
  // Seeded from the shared model at request time (see RequestConfirmation), so
  // the sentence lives in ONE place with the rest of the consent wording.
  GInstruction: string = '';
  GHeadingText: string = '';
  GTargetText: string = '';
  GDeadline: Cardinal = 0;

const
  // The window's own geometry, in DESIGN pixels at 96 DPI. Everything is scaled
  // by the target monitor's DPI at creation time -- the old fixed 460x200 shrank
  // to a postage stamp on a high-DPI screen, on a dialog whose entire job is to
  // be noticed.
  CDesignW   = 520;
  CDesignH   = 260;
  CDesignPad = 22;
  CCountdownTimerId = 1;

class function TDesktopConsent.ConfirmKeyDecision(AVk: Word; AInjected: Boolean): TDesktopKeyAction;
begin
  // The whole defense: a synthesised key (SendInput / UIA) is NEVER a valid
  // confirmation. This is what makes the agent unable to approve itself.
  if AInjected then
    Exit(dkaIgnore);

  if (AVk = Ord('Y')) or (AVk = VK_RETURN) then
    Result := dkaConfirm
  else if (AVk = Ord('N')) or (AVk = VK_ESCAPE) then
    Result := dkaDecline
  else
    Result := dkaIgnore;
end;

// The low-level keyboard hook. On a key-DOWN it reads the injected flag and the
// vkCode and defers ENTIRELY to the pure ConfirmKeyDecision - the logic is
// never duplicated here. A resolved (confirm/decline) physical key is swallowed
// so it does not leak to the window behind; everything else passes through.
function LLKeyboardProc(nCode: Integer; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  LInfo: PKbdLLHookStruct;
  LInjected: Boolean;
  LAction: TDesktopKeyAction;
begin
  if (nCode = HC_ACTION) and
     ((wParam = WM_KEYDOWN) or (wParam = WM_SYSKEYDOWN)) then
  begin
    LInfo := PKbdLLHookStruct(lParam);
    LInjected := (LInfo.flags and LLKHF_INJECTED_BIT) <> 0;
    LAction := TDesktopConsent.ConfirmKeyDecision(Word(LInfo.vkCode), LInjected);
    // Scope the decision to the TRUSTED dialog: a physical Y/N/Enter/Esc counts
    // ONLY while the consent window itself holds the foreground. WH_KEYBOARD_LL is
    // system-wide, so without this an ordinary Enter/Y the human types into ANOTHER
    // app during the wait would both silently resolve the pending action AND be
    // swallowed from the app they were really using. Requiring foreground = the
    // consent window means the key must be aimed AT the dialog the human is looking
    // at. Fails safe: if the dialog is not foreground we neither decide nor consume.
    if (LAction <> dkaIgnore) and (GConsentWnd <> 0) and
       (GetForegroundWindow = GConsentWnd) then
    begin
      GConfirmed := (LAction = dkaConfirm);
      GDecided := True;
      // Consume the decision key so it never reaches the app behind the dialog.
      Result := 1;
      Exit;
    end;
  end;
  Result := CallNextHookEx(0, nCode, wParam, lParam);
end;

// Fail-closed headless check: is THIS process's window station interactive
// (visible)? A service / CI / headless station is not, and a human could never
// see or answer the dialog - so return False and let the caller refuse
// immediately instead of hanging for the full timeout. Not forgeable by the
// agent (it is a property of the OS session, not a file/flag).
function _WindowStationIsInteractive: Boolean;
var
  LStation: HWINSTA;
  LFlags: TUserObjectFlags;
  LNeeded: DWORD;
begin
  LStation := GetProcessWindowStation;
  if LStation = 0 then
    Exit(False);
  FillChar(LFlags, SizeOf(LFlags), 0);
  LNeeded := 0;
  if not GetUserObjectInformationW(LStation, UOI_FLAGS_LOCAL, @LFlags,
    SizeOf(LFlags), @LNeeded) then
    Exit(False);
  Result := (LFlags.dwFlags and WSF_VISIBLE_LOCAL) <> 0;
end;

// Robustly brings AWnd to the foreground using the canonical AttachThreadInput
// workaround (the SPI_GETFOREGROUNDLOCKTIMEOUT rule refuses a bare
// SetForegroundWindow from a non-foreground caller). Mirrors _ForceForeground in
// Aefos.Desktop.Actions.
procedure _ForceForeground(AWnd: HWND);
var
  LFore: HWND;
  LForeThread, LTargetThread: DWORD;
  LAttached: Boolean;
begin
  LFore := GetForegroundWindow;
  LForeThread := 0;
  if LFore <> 0 then
    LForeThread := GetWindowThreadProcessId(LFore, nil);
  LTargetThread := GetWindowThreadProcessId(AWnd, nil);

  LAttached := (LForeThread <> 0) and (LForeThread <> LTargetThread) and
    AttachThreadInput(LForeThread, LTargetThread, True);
  try
    BringWindowToTop(AWnd);
    SetForegroundWindow(AWnd);
    SetFocus(AWnd);
  finally
    if LAttached then
      AttachThreadInput(LForeThread, LTargetThread, False);
  end;
end;

// The consent window's WndProc: paints the summary + the instruction line. No
// buttons (buttons would be UIA-invokable - the very vector we defend against);
{ TRect literal. Winapi.Windows' Rect() helper is not in scope in this unit and
  the alternative is four assignments at every use site. }
function _R(const ALeft, ATop, ARight, ABottom: Integer): TRect;
begin
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Right := ARight;
  Result.Bottom := ABottom;
end;

// The DPI of the monitor a window will be placed on, BEFORE that window exists.
// _WindowDpi needs an HWND; this is the same question asked of the anchor.
function _MonitorDpi(const AAnchorWnd: HWND): Integer;
var
  LDC: HDC;
begin
  LDC := GetDC(AAnchorWnd);
  try
    Result := GetDeviceCaps(LDC, LOGPIXELSX);
  finally
    ReleaseDC(AAnchorWnd, LDC);
  end;
  if Result <= 0 then
    Result := 96;
end;

// A UI font at the window's DPI. Windows paints with the stock BITMAP font when
// nothing is selected into the DC -- that, and nothing else, is why this dialog
// looked like it came from another decade.
function _UiFont(const ADpi: Integer; const APtSize: Integer;
  const ABold: Boolean): HFONT;
var
  LHeight, LWeight: Integer;
begin
  LHeight := -MulDiv(APtSize, ADpi, 72);
  if ABold then
    LWeight := FW_SEMIBOLD
  else
    LWeight := FW_NORMAL;
  Result := CreateFont(LHeight, 0, 0, 0, LWeight, 0, 0, 0, DEFAULT_CHARSET,
    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
    VARIABLE_PITCH or FF_SWISS, 'Segoe UI');
end;

// The DPI of the monitor this window is on. GetDpiForWindow is Win10 1607+; the
// device-caps read is the floor that works everywhere.
function _WindowDpi(const AWnd: HWND): Integer;
var
  LDC: HDC;
begin
  LDC := GetDC(AWnd);
  try
    Result := GetDeviceCaps(LDC, LOGPIXELSX);
  finally
    ReleaseDC(AWnd, LDC);
  end;
  if Result <= 0 then
    Result := 96;
end;

// The warning badge the chat card and the VCL modal both wear beside their
// heading. Same shape, same amber, so the three surfaces read as one product --
// the mechanisms differ, the family should not.
procedure _DrawBadge(const ADC: HDC; const AX, AY, ASize: Integer);
var
  LBrush, LOldBrush: HBRUSH;
  LPen, LOldPen: HPEN;
  LRect: TRect;
  LFont, LOldFont: HFONT;
begin
  LBrush := CreateSolidBrush(RGB($E8, $B8, $4B));
  LPen := CreatePen(PS_SOLID, 1, RGB($E8, $B8, $4B));
  LOldBrush := SelectObject(ADC, LBrush);
  LOldPen := SelectObject(ADC, LPen);
  try
    Ellipse(ADC, AX, AY, AX + ASize, AY + ASize);
    LRect := _R(AX, AY, AX + ASize, AY + ASize);
    LFont := CreateFont(-MulDiv(ASize * 2 div 3, 1, 1), 0, 0, 0, FW_BOLD, 0, 0, 0,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, VARIABLE_PITCH or FF_SWISS, 'Segoe UI');
    LOldFont := SelectObject(ADC, LFont);
    try
      SetTextColor(ADC, RGB($16, $18, $1C));
      DrawText(ADC, '!', 1, LRect,
        DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
    finally
      SelectObject(ADC, LOldFont);
      DeleteObject(LFont);
    end;
  finally
    SelectObject(ADC, LOldBrush);
    SelectObject(ADC, LOldPen);
    DeleteObject(LBrush);
    DeleteObject(LPen);
  end;
end;

// Draws one key cap ("Y", "Esc") and returns the x to continue at.
function _DrawKeyCap(const ADC: HDC; const AX, AY, AH: Integer;
  const AText: string): Integer;
var
  LSize: TSize;
  LRect: TRect;
  LPen, LOldPen: HPEN;
  LBrush, LOldBrush: HBRUSH;
begin
  GetTextExtentPoint32(ADC, PChar(AText), Length(AText), LSize);
  LRect.Left := AX;
  LRect.Top := AY;
  LRect.Right := AX + LSize.cx + (AH div 2);
  LRect.Bottom := AY + AH;
  LPen := CreatePen(PS_SOLID, 1, RGB($46, $4C, $55));
  LBrush := CreateSolidBrush(RGB($2A, $2E, $34));
  LOldPen := SelectObject(ADC, LPen);
  LOldBrush := SelectObject(ADC, LBrush);
  try
    RoundRect(ADC, LRect.Left, LRect.Top, LRect.Right, LRect.Bottom, 6, 6);
    SetTextColor(ADC, RGB($E8, $EB, $EF));
    DrawText(ADC, PChar(AText), Length(AText), LRect,
      DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
  finally
    SelectObject(ADC, LOldPen);
    SelectObject(ADC, LOldBrush);
    DeleteObject(LPen);
    DeleteObject(LBrush);
  end;
  Result := LRect.Right;
end;

// the ONLY way to answer is a physical key, seen by the LL hook.
function ConsentWndProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM): LRESULT; stdcall;
var
  LPaint: TPaintStruct;
  LDC: HDC;
  LRect, LBody: TRect;
  LBrush: HBRUSH;
  LPen, LOldPen: HPEN;
  LFontHead, LFontBody, LFontSmall, LOldFont: HFONT;
  LDpi, LPad, LY, LX, LCapH, LBadge: Integer;
  LLeft: Cardinal;
  LCountdown: string;
begin
  case AMsg of
    WM_PAINT:
      begin
        LDC := BeginPaint(AWnd, LPaint);
        try
          GetClientRect(AWnd, LRect);
          LDpi := _WindowDpi(AWnd);
          LPad := MulDiv(CDesignPad, LDpi, 96);
          LBrush := CreateSolidBrush(RGB($1B, $1D, $21));
          try
            FillRect(LDC, LRect, LBrush);
          finally
            DeleteObject(LBrush);
          end;
          SetBkMode(LDC, TRANSPARENT);

          LFontHead := _UiFont(LDpi, 12, True);
          LFontBody := _UiFont(LDpi, 10, False);
          LFontSmall := _UiFont(LDpi, 8, False);
          LOldFont := SelectObject(LDC, LFontHead);
          try
            LY := LPad;

            // The badge, then the QUESTION beside it -- the same pairing the
            // chat card and the VCL modal use. Largest thing on the window,
            // because "what am I being asked" must land before anything else.
            LBadge := MulDiv(22, LDpi, 96);
            _DrawBadge(LDC, LPad, LY + MulDiv(2, LDpi, 96), LBadge);
            LBody := _R(LPad + LBadge + MulDiv(9, LDpi, 96), LY,
              LRect.Right - LPad, LY + MulDiv(28, LDpi, 96));
            SetTextColor(LDC, RGB($FF, $FF, $FF));
            DrawText(LDC, PChar(GHeadingText), Length(GHeadingText), LBody,
              DT_LEFT or DT_TOP or DT_SINGLELINE or DT_NOPREFIX);
            Inc(LY, MulDiv(30, LDpi, 96));

            // The consequence, wrapped.
            SelectObject(LDC, LFontBody);
            LBody := _R(LPad, LY, LRect.Right - LPad, LY + MulDiv(44, LDpi, 96));
            SetTextColor(LDC, RGB($D6, $D9, $DE));
            DrawText(LDC, PChar(GSummaryText), Length(GSummaryText), LBody,
              DT_LEFT or DT_TOP or DT_WORDBREAK or DT_NOPREFIX);
            Inc(LY, MulDiv(46, LDpi, 96));

            // WHAT is being acted on, on its own line so it cannot be skimmed
            // past -- this is the field a user checks before pressing a key.
            LBody := _R(LPad, LY, LRect.Right - LPad, LY + MulDiv(20, LDpi, 96));
            SetTextColor(LDC, RGB($8B, $90, $99));
            DrawText(LDC, PChar(GTargetText), Length(GTargetText), LBody,
              DT_LEFT or DT_TOP or DT_END_ELLIPSIS or DT_SINGLELINE or DT_NOPREFIX);
            Inc(LY, MulDiv(30, LDpi, 96));

            // Separator, then the keys drawn AS keys.
            LPen := CreatePen(PS_SOLID, 1, RGB($2A, $2E, $34));
            LOldPen := SelectObject(LDC, LPen);
            MoveToEx(LDC, LPad, LY, nil);
            LineTo(LDC, LRect.Right - LPad, LY);
            SelectObject(LDC, LOldPen);
            DeleteObject(LPen);
            Inc(LY, MulDiv(14, LDpi, 96));

            LCapH := MulDiv(22, LDpi, 96);
            LX := _DrawKeyCap(LDC, LPad, LY, LCapH, 'Y');
            Inc(LX, MulDiv(8, LDpi, 96));
            LBody := _R(LX, LY, LX + MulDiv(70, LDpi, 96), LY + LCapH);
            SetTextColor(LDC, RGB($AE, $B4, $BD));
            DrawText(LDC, 'allow', 5, LBody,
              DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);

            LX := _DrawKeyCap(LDC, LX + MulDiv(78, LDpi, 96), LY, LCapH, 'N');
            Inc(LX, MulDiv(6, LDpi, 96));
            LX := _DrawKeyCap(LDC, LX, LY, LCapH, 'Esc');
            Inc(LX, MulDiv(8, LDpi, 96));
            LBody := _R(LX, LY, LX + MulDiv(70, LDpi, 96), LY + LCapH);
            DrawText(LDC, 'deny', 4, LBody,
              DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
            Inc(LY, LCapH + MulDiv(12, LDpi, 96));

            // The one fact a user cannot guess, and the reason this window is a
            // hand-built popup instead of a normal dialog. It belongs ON SCREEN,
            // not only in the documentation.
            SelectObject(LDC, LFontSmall);
            LBody := _R(LPad, LY, LRect.Right - LPad, LY + MulDiv(18, LDpi, 96));
            SetTextColor(LDC, RGB($7B, $81, $8A));
            DrawText(LDC, PChar(GInstruction), Length(GInstruction), LBody,
              DT_LEFT or DT_TOP or DT_SINGLELINE or DT_NOPREFIX);
            Inc(LY, MulDiv(22, LDpi, 96));

            // A silent wait that ends in a refusal is indistinguishable from a
            // refusal. Show the clock.
            LLeft := 0;
            if GDeadline > GetTickCount then
              LLeft := (GDeadline - GetTickCount) div 1000;
            LCountdown := Format('Denies automatically in %ds', [LLeft]);
            LBody := _R(LPad, LY, LRect.Right - LPad, LY + MulDiv(18, LDpi, 96));
            DrawText(LDC, PChar(LCountdown), Length(LCountdown), LBody,
              DT_LEFT or DT_TOP or DT_SINGLELINE or DT_NOPREFIX);
          finally
            SelectObject(LDC, LOldFont);
            DeleteObject(LFontHead);
            DeleteObject(LFontBody);
            DeleteObject(LFontSmall);
          end;
        finally
          EndPaint(AWnd, LPaint);
        end;
        Result := 0;
      end;
    WM_TIMER:
      begin
        if AWParam = CCountdownTimerId then
          InvalidateRect(AWnd, nil, False);
        Result := 0;
      end;
    WM_CLOSE:
      begin
        // Closing the window without a physical key = deny (fail closed).
        GConfirmed := False;
        GDecided := True;
        Result := 0;
      end;
  else
    Result := DefWindowProc(AWnd, AMsg, AWParam, ALParam);
  end;
end;

// Message pump for the modal wait: LL hooks are delivered to the installing
// thread via messages, so we must pump. Stops when ADone holds or the timeout
// elapses (GetTickCount, wrap-safe via unsigned subtraction).
procedure _PumpUntil(const ATimeoutMs: Cardinal; const ADone: TFunc<Boolean>);
var
  LMsg: TMsg;
  LStart: Cardinal;
begin
  LStart := GetTickCount;
  while (not ADone()) and ((GetTickCount - LStart) < ATimeoutMs) do
  begin
    while PeekMessage(LMsg, 0, 0, 0, PM_REMOVE) do
    begin
      TranslateMessage(LMsg);
      DispatchMessage(LMsg);
    end;
    Sleep(5);
  end;
end;

// The rect to centre the consent window inside: the work area of the monitor
// that owns AAnchorWnd (or the foreground window, or the primary as the last
// resort). Never SM_CXSCREEN alone -- that is the PRIMARY monitor, which on a
// two-monitor desk is a coin flip whether the user is even looking at it.
function _AnchorWorkArea(const AAnchorWnd: HWND): TRect;
var
  LWnd: HWND;
  LMon: HMONITOR;
  LInfo: TAefosMonitorInfo;
begin
  Result.Left := 0;
  Result.Top := 0;
  Result.Right := GetSystemMetrics(SM_CXSCREEN);
  Result.Bottom := GetSystemMetrics(SM_CYSCREEN);
  LWnd := AAnchorWnd;
  if (LWnd = 0) or not IsWindow(LWnd) then
    LWnd := GetForegroundWindow;
  if (LWnd = 0) or not IsWindow(LWnd) then
    Exit;
  LMon := MonitorFromWindow(LWnd, MONITOR_DEFAULTTONEAREST);
  if LMon = 0 then
    Exit;
  FillChar(LInfo, SizeOf(LInfo), 0);
  LInfo.cbSize := SizeOf(LInfo);
  if GetMonitorInfoW(LMon, LInfo) then
    Result := LInfo.rcWork;
end;

function _CreateConsentWindow(const AAnchorWnd: HWND;
  const ATitle: string): HWND;
var
  LClass: TWndClass;
  LArea: TRect;
  LW, LH, LX, LY, LDpi: Integer;
begin
  FillChar(LClass, SizeOf(LClass), 0);
  LClass.lpfnWndProc := @ConsentWndProc;
  LClass.hInstance := HInstance;
  LClass.lpszClassName := CConsentClassName;
  LClass.hCursor := LoadCursor(0, IDC_ARROW);
  LClass.hbrBackground := 0;  // we paint the background ourselves in WM_PAINT
  // RegisterClass may fail if a previous run leaked the class; tolerate that and
  // proceed - CreateWindowEx will still work with the already-registered class.
  RegisterClass(LClass);

  // Design pixels scaled to the DPI of the monitor this will appear on. A dialog
  // whose whole job is to be noticed must not shrink on a high-DPI screen.
  LDpi := _MonitorDpi(AAnchorWnd);
  LW := MulDiv(CDesignW, LDpi, 96);
  LH := MulDiv(CDesignH, LDpi, 96);
  LArea := _AnchorWorkArea(AAnchorWnd);
  LX := LArea.Left + ((LArea.Right - LArea.Left) - LW) div 2;
  LY := LArea.Top + ((LArea.Bottom - LArea.Top) - LH) div 2;

  Result := CreateWindowEx(WS_EX_TOPMOST or WS_EX_TOOLWINDOW,
    CConsentClassName, PChar(ATitle),
    WS_POPUP or WS_BORDER or WS_CAPTION or WS_SYSMENU,
    LX, LY, LW, LH, 0, 0, HInstance, nil);
end;

class function TDesktopConsent.RequestConfirmation(const AAnchorWnd: HWND;
  const ATitle, AHeading, ASummary, ATarget, ANote: string;
  ATimeoutMs: Cardinal): TDesktopConfirmResult;
var
  LWnd: HWND;
begin
  Result.Confirmed := False;
  Result.Reason := 'timed-out';

  // Fail-closed FIRST - before creating any window - so a headless/CI session
  // returns instantly instead of hanging for ATimeoutMs.
  if not _WindowStationIsInteractive then
  begin
    Result.Reason := 'no-interactive-session';
    Exit;
  end;

  // Reset the shared decision state for this run.
  GDecided := False;
  GConfirmed := False;
  GHeadingText := AHeading;
  GInstruction := ANote;
  GSummaryText := ASummary;
  GTargetText := ATarget;
  GDeadline := GetTickCount + ATimeoutMs;

  LWnd := _CreateConsentWindow(AAnchorWnd, ATitle);
  if LWnd = 0 then
  begin
    // Could not present a trusted window => cannot obtain trusted consent.
    Result.Reason := 'no-interactive-session';
    Exit;
  end;
  try
    // Publish the trusted window so the LL hook only honours keys aimed at IT.
    GConsentWnd := LWnd;
    // Best-effort: keep the agent's own capture tool from reading the dialog.
    SetWindowDisplayAffinity(LWnd, WDA_EXCLUDEFROMCAPTURE_LOCAL);
    _UseDarkChrome(LWnd);

    ShowWindow(LWnd, SW_SHOWNORMAL);
    UpdateWindow(LWnd);
    _ForceForeground(LWnd);
    // Repaint once a second, or the countdown on screen would be frozen at the
    // value it had when the window opened -- worse than showing none at all.
    SetTimer(LWnd, CCountdownTimerId, 1000, nil);

    GKbdHook := SetWindowsHookEx(WH_KEYBOARD_LL, @LLKeyboardProc, HInstance, 0);
    // If the hook cannot be installed we CANNOT distinguish physical from
    // injected input - fail closed rather than trust an ungated key.
    if GKbdHook = 0 then
    begin
      Result.Reason := 'no-interactive-session';
      Exit;
    end;
    try
      _PumpUntil(ATimeoutMs,
        function: Boolean
        begin
          Result := GDecided;
        end);
    finally
      // Minimum-lifetime: unhook the global LL hook the instant we are done.
      if GKbdHook <> 0 then
      begin
        UnhookWindowsHookEx(GKbdHook);
        GKbdHook := 0;
      end;
    end;

    if GDecided then
    begin
      Result.Confirmed := GConfirmed;
      if GConfirmed then
        Result.Reason := 'confirmed'
      else
        Result.Reason := 'declined';
    end
    else
    begin
      Result.Confirmed := False;
      Result.Reason := 'timed-out';
    end;
  finally
    GConsentWnd := 0;
    // Explicit, in the same spirit as the unhook above: never leave a timer
    // pointing at a window proc we are about to destroy.
    KillTimer(LWnd, CCountdownTimerId);
    DestroyWindow(LWnd);
    UnregisterClass(CConsentClassName, HInstance);
  end;
end;

end.
