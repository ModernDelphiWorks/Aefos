unit Aefos.Desktop.Actions;

{
  The WRITE mechanism of the Aefos Desktop MCP (feat/desktop-mcp, PHASE 5).

  This unit is the HANDS. The pure guard (Aefos.Desktop.Guard) is the JUDGE: the
  tool layer asks it whether an action is allowed and only then calls in here.
  So this unit performs NO policy of its own — by the time control reaches it the
  scope / deny-list / host-consent / forbidden-class decision has already passed.
  What it owns is doing the deed SAFELY, which on a live desktop means two things
  the plan's security review pinned down:

  H4 — TOCTOU. The guard reasoned about a target resolved from a LIVE enumeration
  a moment ago; between that decision and the act, the window could have closed
  and its hwnd been RECYCLED onto a different process. Acting on a recycled hwnd
  is exactly the "wrong window" class the Notepad incident banned. So every action
  re-verifies, IMMEDIATELY before touching anything, that the SAME pid the guard
  cleared still owns the hwnd (AExpectedPid). A mismatch aborts with
  desktop-target-changed — no action taken.

  H5 — focus race on typed input. Raw SendInput lands wherever focus happens to
  be at the instant it fires; a toast or Alt-Tab stealing focus would drop the
  agent's keystrokes into the user's password field. So typed input goes through
  UIA ValuePattern.SetValue — ELEMENT-TARGETED, delivered to the specific control
  regardless of focus, race-immune by construction. There is deliberately NO raw
  SendInput fallback in this phase: a gated coordinate/keystroke path is a later,
  separately-reviewed increment. Likewise click/invoke uses UIA InvokePattern
  (the element's own "default action"), never a synthesised mouse move+click at
  screen coordinates — element-targeted, so it cannot miss and hit a neighbour.

  DESTRUCTIVE actions (PHASE 6) now live here too: TDesktopActions.CloseWindow (a
  graceful, RECOVERABLE WM_CLOSE — the app can still prompt "save?") and KillProcess
  (a hard TerminateProcess of the guard-cleared pid). They are STILL only the
  hands: the irreversible ones are gated in the tool layer by the KEY-4 human-
  confirmation consent window (Aefos.Desktop.Consent — a trusted top-level window
  that rejects injected input and fails closed headless), so the agent can never
  self-approve them. Both re-verify (H4/TOCTOU) that the same pid still owns the
  hwnd immediately before acting, and the kill targets the EXACT AExpectedPid the
  guard cleared (never a fresh lookup), so a recycled pid is never terminated.
  The non-destructive tools — invoke/click, type/set_value, focus, move — are
  within-scope actions on the app the human allow-listed, all recoverable.

  Winapi + UIA (COM) bound, so it is exercised by the live action probe, not the
  headless pure suite. The decision half it depends on (the guard) and the shapes
  it returns are pure/tested; this is the irreducible Windows plumbing.
}

interface

uses
  System.SysUtils;

type
  // The outcome of one write action. Ok=False carries a kebab Reason the tool
  // layer hands to the agent (same vocabulary as the guard's verdicts). Detail
  // is a short human summary of what happened, for the audit log.
  TDesktopActionResult = record
    Ok: Boolean;
    Reason: string;   // kebab code when not Ok; '' when Ok
    Detail: string;   // audit summary (e.g. 'clicked "OK"'); '' when not Ok
  end;

const
  // Kebab failure codes specific to the act (the guard owns the policy ones).
  DESKTOP_ACTION_TARGET_CHANGED = 'desktop-target-changed';   // TOCTOU (H4)
  DESKTOP_ACTION_WINDOW_GONE    = 'desktop-window-gone';
  DESKTOP_ACTION_ELEMENT_NOT_FOUND = 'desktop-element-not-found';
  DESKTOP_ACTION_NO_PATTERN     = 'desktop-element-not-actionable';
  DESKTOP_ACTION_FAILED         = 'desktop-action-failed';

type
  // Static, sealed namespace for the WRITE/DESTRUCTIVE mechanism (the HANDS). Never
  // instantiated (no constructor): every routine is a class function so it has a
  // named owner (e.g. TDesktopActions.KillProcess) instead of floating free in the
  // unit interface. Policy lives in TDesktopGuard; this class only acts.
  TDesktopActions = class sealed
  public
    // Re-verifies (H4/TOCTOU) that AExpectedPid still owns AHwnd. False when the
    // window is gone or a different process now owns that handle. Exposed so a test
    // can drive it; the action fns below call it themselves.
    class function StillOwns(AHwnd: NativeInt; AExpectedPid: Cardinal): Boolean; static;

    // Brings AHwnd to the foreground. (A focus change IS a mutation — that is why it
    // is a write-tier action gated by scope + host consent, not a read.)
    class function FocusWindow(AHwnd: NativeInt; AExpectedPid: Cardinal): TDesktopActionResult; static;

    // Moves/resizes AHwnd. AWidth/AHeight <= 0 keep the current size (move only).
    class function MoveWindow(AHwnd: NativeInt; AExpectedPid: Cardinal;
      AX, AY, AWidth, AHeight: Integer): TDesktopActionResult; static;

    // Invokes ONE element inside AHwnd, located by the AND of the given criteria
    // (control_type / automation_id / name — at least one required). Uses UIA
    // InvokePattern (the element's default action), never a coordinate click.
    class function InvokeElement(AHwnd: NativeInt; AExpectedPid: Cardinal;
      const AControlType, AAutomationId, AName: string): TDesktopActionResult; static;

    // Sets the value of ONE element inside AHwnd (located as above) via UIA
    // ValuePattern.SetValue — element-targeted, focus-race-immune (H5).
    class function SetElementValue(AHwnd: NativeInt; AExpectedPid: Cardinal;
      const AControlType, AAutomationId, AName, AValue: string): TDesktopActionResult; static;

    // DESTRUCTIVE (PHASE 6), gated in the tool layer by the KEY-4 consent window.
    // GRACEFUL close: TOCTOU re-check, then post WM_CLOSE — a RECOVERABLE request the
    // app can still answer (it may prompt "save changes?"). NOT forced.
    class function CloseWindow(AHwnd: NativeInt; AExpectedPid: Cardinal): TDesktopActionResult; static;

    // DESTRUCTIVE (PHASE 6): HARD kill. TOCTOU re-check that AExpectedPid still owns
    // AHwnd, then OpenProcess(PROCESS_TERMINATE)+TerminateProcess on that EXACT pid
    // (never a fresh lookup — a recycled pid is never terminated). Unsaved data lost.
    class function KillProcess(AHwnd: NativeInt; AExpectedPid: Cardinal): TDesktopActionResult; static;
  end;

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.ActiveX,
  System.Variants,
  System.Win.ComObj,
  Aefos.Win.UIAutomation,
  Aefos.Desktop.ReadShape;

// --- TOCTOU (H4) -------------------------------------------------------------

class function TDesktopActions.StillOwns(AHwnd: NativeInt; AExpectedPid: Cardinal): Boolean;
var
  LWnd: HWND;
  LPid: DWORD;
begin
  Result := False;
  LWnd := HWND(AHwnd);
  if (AHwnd = 0) or (not IsWindow(LWnd)) then
    Exit;
  // A pid of 0 was never a resolved identity (the guard would have refused it),
  // so treat "expected 0" as a failed re-check rather than a wildcard match.
  if AExpectedPid = 0 then
    Exit;
  LPid := 0;
  GetWindowThreadProcessId(LWnd, @LPid);
  Result := LPid = AExpectedPid;
end;

// A uniform "the window/handle is no longer our target" result.
function _TargetChanged: TDesktopActionResult;
begin
  Result := Default(TDesktopActionResult);
  Result.Reason := DESKTOP_ACTION_TARGET_CHANGED;
end;

// --- window-level actions (Win32) --------------------------------------------

// Robustly brings AWnd to the foreground. Windows refuses a bare
// SetForegroundWindow when the caller does not own the current foreground (the
// SPI_GETFOREGROUNDLOCKTIMEOUT rule), so this uses the canonical AttachThreadInput
// workaround: attach our input queue to the current foreground thread's so
// SetForegroundWindow is honoured, then detach. Success is confirmed by the
// ACTUAL result (GetForegroundWindow == target), not the BOOL — SetForegroundWindow
// is documented to return misleading values under the lock.
function _ForceForeground(AWnd: HWND): Boolean;
var
  LFore: HWND;
  LForeThread, LTargetThread: DWORD;
  LAttached: Boolean;
begin
  if GetForegroundWindow = AWnd then
    Exit(True);

  LFore := GetForegroundWindow;
  LForeThread := GetWindowThreadProcessId(LFore, nil);
  LTargetThread := GetWindowThreadProcessId(AWnd, nil);

  LAttached := (LForeThread <> 0) and (LForeThread <> LTargetThread) and
    AttachThreadInput(LForeThread, LTargetThread, True);
  try
    BringWindowToTop(AWnd);
    SetForegroundWindow(AWnd);
  finally
    if LAttached then
      AttachThreadInput(LForeThread, LTargetThread, False);
  end;
  // Trust the observed state, not the API's return value.
  Result := GetForegroundWindow = AWnd;
end;

class function TDesktopActions.FocusWindow(AHwnd: NativeInt; AExpectedPid: Cardinal): TDesktopActionResult;
var
  LWnd: HWND;
begin
  Result := Default(TDesktopActionResult);
  if not StillOwns(AHwnd, AExpectedPid) then
    Exit(_TargetChanged);
  LWnd := HWND(AHwnd);
  // A minimised window must be restored before it can take the foreground.
  if IsIconic(LWnd) then
    ShowWindow(LWnd, SW_RESTORE);
  if _ForceForeground(LWnd) then
  begin
    Result.Ok := True;
    Result.Detail := 'focused window';
  end
  else
    // The OS still refused (rare — e.g. a full-screen exclusive app holds the
    // foreground). Report honestly rather than pretend it worked.
    Result.Reason := DESKTOP_ACTION_FAILED;
end;

class function TDesktopActions.MoveWindow(AHwnd: NativeInt; AExpectedPid: Cardinal;
  AX, AY, AWidth, AHeight: Integer): TDesktopActionResult;
var
  LWnd: HWND;
  LRect: TRect;
  LW, LH: Integer;
  LFlags: UINT;
begin
  Result := Default(TDesktopActionResult);
  if not StillOwns(AHwnd, AExpectedPid) then
    Exit(_TargetChanged);
  LWnd := HWND(AHwnd);
  if not GetWindowRect(LWnd, LRect) then
    Exit(_TargetChanged);

  // <=0 width/height keeps the current extent (a pure move). SWP_NOSIZE would do
  // the same, but keeping explicit numbers makes the audit summary exact.
  if AWidth > 0 then LW := AWidth else LW := LRect.Right - LRect.Left;
  if AHeight > 0 then LH := AHeight else LH := LRect.Bottom - LRect.Top;
  LFlags := SWP_NOZORDER or SWP_NOACTIVATE;

  if SetWindowPos(LWnd, 0, AX, AY, LW, LH, LFlags) then
  begin
    Result.Ok := True;
    Result.Detail := Format('moved to (%d,%d) size %dx%d', [AX, AY, LW, LH]);
  end
  else
    Result.Reason := DESKTOP_ACTION_FAILED;
end;

// --- destructive window/process actions (PHASE 6, KEY-4 gated) ---------------

class function TDesktopActions.CloseWindow(AHwnd: NativeInt; AExpectedPid: Cardinal): TDesktopActionResult;
var
  LWnd: HWND;
begin
  Result := Default(TDesktopActionResult);
  if not StillOwns(AHwnd, AExpectedPid) then
    Exit(_TargetChanged);
  LWnd := HWND(AHwnd);
  // A RECOVERABLE request, not a force: WM_CLOSE lets the app run its own
  // shutdown (it can still pop "save changes?"). We deliberately do NOT
  // TerminateProcess here — that is the separate, harder KillProcess.
  if PostMessage(LWnd, WM_CLOSE, 0, 0) then
  begin
    Result.Ok := True;
    Result.Detail := 'requested window close';
  end
  else
    Result.Reason := DESKTOP_ACTION_FAILED;
end;

class function TDesktopActions.KillProcess(AHwnd: NativeInt; AExpectedPid: Cardinal): TDesktopActionResult;
var
  LProc: THandle;
  LOk: Boolean;
begin
  Result := Default(TDesktopActionResult);
  // TOCTOU (H4): terminate the guard-cleared pid ONLY while it still owns the
  // hwnd. This is what makes killing a RECYCLED pid impossible — if the window
  // died and its handle was reassigned to another process, StillOwns is
  // False and we abort without touching anything.
  if not StillOwns(AHwnd, AExpectedPid) then
    Exit(_TargetChanged);

  // Kill by the EXACT AExpectedPid the guard cleared, never a fresh lookup.
  LProc := OpenProcess(PROCESS_TERMINATE, False, AExpectedPid);
  if LProc = 0 then
  begin
    Result.Reason := DESKTOP_ACTION_FAILED;
    Exit;
  end;
  try
    LOk := TerminateProcess(LProc, 1);
  finally
    CloseHandle(LProc);
  end;

  if LOk then
  begin
    Result.Ok := True;
    Result.Detail := Format('terminated process %d', [AExpectedPid]);
  end
  else
    Result.Reason := DESKTOP_ACTION_FAILED;
end;

// --- element resolution (shared by invoke + set_value) -----------------------

// Fresh UIA root. nil on failure (the caller maps that to a kebab reason).
function _NewUia: IUIAutomation;
begin
  Result := nil;
  try
    Result := CreateComObject(CLSID_CUIAutomation) as IUIAutomation;
  except
    Result := nil;
  end;
end;

// Builds the AND of the supplied criteria. nil when no criterion is given (the
// caller refuses that) or a control_type names nothing known.
function _BuildCondition(const AUia: IUIAutomation;
  const AControlType, AAutomationId, AName: string): IUIAutomationCondition;

  procedure _Fold(const ANext: IUIAutomationCondition; var ACur: IUIAutomationCondition);
  var
    LCombined: IUIAutomationCondition;
  begin
    if ACur = nil then
      ACur := ANext
    else if Succeeded(AUia.CreateAndCondition(ACur, ANext, LCombined)) then
      ACur := LCombined;
  end;

var
  LCond: IUIAutomationCondition;
  LVar: OleVariant;
  LCtId: Integer;
begin
  Result := nil;
  if Trim(AControlType) <> '' then
  begin
    if not TDesktopReadShape.ControlTypeIdFromName(AControlType, LCtId) then
      Exit(nil);
    LVar := LCtId;
    if Succeeded(AUia.CreatePropertyCondition(UIA_ControlTypePropertyId, LVar, LCond)) then
      _Fold(LCond, Result);
  end;
  if Trim(AAutomationId) <> '' then
  begin
    LVar := AAutomationId;
    if Succeeded(AUia.CreatePropertyCondition(UIA_AutomationIdPropertyId, LVar, LCond)) then
      _Fold(LCond, Result);
  end;
  if AName <> '' then
  begin
    LVar := AName;
    if Succeeded(AUia.CreatePropertyCondition(UIA_NamePropertyId, LVar, LCond)) then
      _Fold(LCond, Result);
  end;
end;

// The element-resolving core, reused by invoke + set_value. Returns a kebab
// reason ('' on success) and yields the matched element + its name.
function _ResolveElement(AHwnd: NativeInt;
  const AControlType, AAutomationId, AName: string;
  out AElement: IUIAutomationElement; out AMatchedName: string): string;
var
  LUia: IUIAutomation;
  LRoot: IUIAutomationElement;
  LCond: IUIAutomationCondition;
  LVar: OleVariant;
begin
  AElement := nil;
  AMatchedName := '';

  LUia := _NewUia;
  if LUia = nil then
    Exit(DESKTOP_ACTION_FAILED);
  if Failed(LUia.ElementFromHandle(HWND(AHwnd), LRoot)) or (LRoot = nil) then
    Exit(DESKTOP_ACTION_WINDOW_GONE);

  LCond := _BuildCondition(LUia, AControlType, AAutomationId, AName);
  if LCond = nil then
    Exit(DESKTOP_ACTION_ELEMENT_NOT_FOUND);

  if Failed(LRoot.FindFirst(TreeScope_Subtree, LCond, AElement)) or (AElement = nil) then
    Exit(DESKTOP_ACTION_ELEMENT_NOT_FOUND);

  if Succeeded(AElement.GetCurrentPropertyValue(UIA_NamePropertyId, LVar)) and
     not VarIsNull(LVar) and not VarIsEmpty(LVar) then
    AMatchedName := VarToStr(LVar);
  Result := '';
end;

// --- element-targeted actions (UIA) ------------------------------------------

class function TDesktopActions.InvokeElement(AHwnd: NativeInt; AExpectedPid: Cardinal;
  const AControlType, AAutomationId, AName: string): TDesktopActionResult;
var
  LElement: IUIAutomationElement;
  LMatchedName, LReason: string;
  LPatternUnk: IUnknown;
  LInvoke: IUIAutomationInvokePattern;
begin
  Result := Default(TDesktopActionResult);
  if not StillOwns(AHwnd, AExpectedPid) then
    Exit(_TargetChanged);

  LReason := _ResolveElement(AHwnd, AControlType, AAutomationId, AName,
    LElement, LMatchedName);
  if LReason <> '' then
  begin
    Result.Reason := LReason;
    Exit;
  end;

  // The element's DEFAULT action (press a button, expand a node, ...). No mouse.
  if Failed(LElement.GetCurrentPattern(UIA_InvokePatternId, LPatternUnk)) or
     (LPatternUnk = nil) then
  begin
    Result.Reason := DESKTOP_ACTION_NO_PATTERN;
    Exit;
  end;
  if not Supports(LPatternUnk, IUIAutomationInvokePattern, LInvoke) then
  begin
    Result.Reason := DESKTOP_ACTION_NO_PATTERN;
    Exit;
  end;

  // Re-check ownership one last time right before the act (TOCTOU window as
  // small as we can make it).
  if not StillOwns(AHwnd, AExpectedPid) then
    Exit(_TargetChanged);
  if Failed(LInvoke.Invoke) then
  begin
    Result.Reason := DESKTOP_ACTION_FAILED;
    Exit;
  end;

  Result.Ok := True;
  if LMatchedName <> '' then
    Result.Detail := 'invoked "' + LMatchedName + '"'
  else
    Result.Detail := 'invoked element';
end;

class function TDesktopActions.SetElementValue(AHwnd: NativeInt; AExpectedPid: Cardinal;
  const AControlType, AAutomationId, AName, AValue: string): TDesktopActionResult;
var
  LElement: IUIAutomationElement;
  LMatchedName, LReason: string;
  LPatternUnk: IUnknown;
  LValue: IUIAutomationValuePattern;
  LReadOnly: BOOL;
  LWide: WideString;
begin
  Result := Default(TDesktopActionResult);
  if not StillOwns(AHwnd, AExpectedPid) then
    Exit(_TargetChanged);

  LReason := _ResolveElement(AHwnd, AControlType, AAutomationId, AName,
    LElement, LMatchedName);
  if LReason <> '' then
  begin
    Result.Reason := LReason;
    Exit;
  end;

  if Failed(LElement.GetCurrentPattern(UIA_ValuePatternId, LPatternUnk)) or
     (LPatternUnk = nil) then
  begin
    Result.Reason := DESKTOP_ACTION_NO_PATTERN;
    Exit;
  end;
  if not Supports(LPatternUnk, IUIAutomationValuePattern, LValue) then
  begin
    Result.Reason := DESKTOP_ACTION_NO_PATTERN;
    Exit;
  end;
  // A read-only control cannot take a value — report it rather than fail opaquely.
  if Succeeded(LValue.get_CurrentIsReadOnly(LReadOnly)) and LReadOnly then
  begin
    Result.Reason := DESKTOP_ACTION_NO_PATTERN;
    Exit;
  end;

  if not StillOwns(AHwnd, AExpectedPid) then
    Exit(_TargetChanged);
  LWide := AValue;
  if Failed(LValue.SetValue(PChar(LWide))) then
  begin
    Result.Reason := DESKTOP_ACTION_FAILED;
    Exit;
  end;

  Result.Ok := True;
  if LMatchedName <> '' then
    Result.Detail := 'set value of "' + LMatchedName + '"'
  else
    Result.Detail := 'set element value';
end;

end.
