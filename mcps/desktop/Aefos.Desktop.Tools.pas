unit Aefos.Desktop.Tools;

{
  The READ-ONLY tools of the Aefos "Desktop MCP" (feat/desktop-mcp).

    desktop_ping          — a trivial health check; proves the server is alive.
    desktop_list_windows  — READ enumeration of top-level windows via UI
                            Automation (name / control type / hwnd + count).
    desktop_window_tree   — READ walk of ONE window's UIA element tree (each node
                            carries name, control_type, automation_id, hwnd,
                            and value when the control holds text),
                            depth- and node-capped.
    desktop_element_find  — READ locate: UIA FindAll over ONE window by
                            control_type / automation_id / name criteria; returns
                            the matching elements (locate only — no click/focus).
    desktop_window_capture— CAPTURE (PHASE 4b): a per-window screenshot via
                            PrintWindow (never stealing the foreground — C3),
                            returned as an inline PNG the vision model literally
                            sees. Scope-gated by the guard's dtCapture tier: a
                            deny-listed or out-of-scope window is REFUSED (pixels
                            cannot be redacted like a title can).

    desktop_window_focus  — WRITE (PHASE 5): brings ONE window to the foreground.
    desktop_window_move   — WRITE: moves/resizes ONE window.
    desktop_invoke        — WRITE: invokes ONE element's default action (press a
                            button, expand a node) via UIA InvokePattern — no
                            coordinate mouse click.
    desktop_type_text     — WRITE: sets ONE element's text via UIA
                            ValuePattern.SetValue — focus-race-immune (H5).

    desktop_window_close  — DESTRUCTIVE (PHASE 6): graceful WM_CLOSE of ONE window.
    desktop_process_kill  — DESTRUCTIVE: force-terminate the process behind ONE
                            window. Both are gated by the pure guard AND, on top of
                            it, the KEY-4 human-confirmation consent window
                            (Aefos.Desktop.Consent) — a trusted top-level window
                            that only a physical human keypress can confirm and
                            that rejects injected/synthesised input, so the agent
                            can never self-approve an irreversible action.

  The read/capture tools are tiNeutral and mutate nothing. The WRITE tools
  (PHASE 5) DO act on the live desktop, so each one is GATED by the pure guard
  BEFORE it touches anything: the target is resolved to its exe path (H4), then
  TDesktopGuard.Decide checks deny-list -> forbidden-type-class (M6) -> scope allow-list
  (KEY 3) -> host consent (KEY 1). A refused action returns an ok:false payload
  carrying the kebab reason and does NOTHING. Only when the guard passes does the
  mechanism (Aefos.Desktop.Actions) act -- element-targeted via UIA (never
  synthetic mouse/keyboard, so no focus-race), with a TOCTOU re-check that the
  same pid still owns the hwnd immediately before acting. Every EXECUTED write is
  recorded in the append-only audit (Aefos.Desktop.Audit). The DESTRUCTIVE tools
  (close window / kill process, PHASE 6) additionally require the KEY-4 human-
  confirmation consent window before acting. A standalone OCR tool is NOT
  shipped: the capture rides back as an MCP image block, so a vision model reads
  the text straight from the picture; a WinRT OCR pass would duplicate that at
  heavy cost.

  KEY 1 — host consent — is read here from AEFOS_DESKTOP_ALLOW_INPUT ('1' = on,
  default OFF) as a stand-in. Its REAL origin is the trusted signed binary-
  harness (a future phase): a human enabling input off-LLM, never a value the
  agent can set. The guard consumes the boolean either way (RULE #1: the agent
  can never self-grant a mutation).

  PRIVACY IS ENFORCED HERE (finding M7 — proven live: even ENUMERATING a window
  leaks its private title to the cloud model). Every window a read tool touches is
  resolved to its EXE PATH (finding H4 — the title is spoofable; identity is the
  process image, via QueryFullProcessImageName) and passed through the pure guard
  Aefos.Desktop.Guard's TDesktopGuard.ClassifyRead. When the guard says redact (a deny-
  listed app, or any non-in-scope window without whole-desktop read consent), the
  NAME/TITLE and value text are replaced with '[redacted]' before anything leaves
  this process — the structural shape (control type, automation id, hwnd, process
  base name) is still returned so the agent can navigate, but the private text is
  withheld. The policy (allow/deny lists + read consent) comes from ONE injectable
  point, _DesktopPolicy; in this phase it reads a small set of environment
  variables so a test can exercise every branch. The real origin — the trusted
  signed binary-harness — is a future phase; the guard consumes the config either
  way.

  WHY THIS IS A SEPARATE PROCESS: the ToolsAPI offers nothing for desktop
  automation, and driving UI Automation (a COM ABI on UIAutomationCore.dll) from
  INSIDE the RAD Studio process could freeze or crash the customer's IDE. So this
  runs OUT of process, over stdio, reusing the very same TMCPServer core as the
  in-IDE server — only the transport changes, so the JSON-RPC dialect and error
  codes are identical BY CONSTRUCTION. The window/tree logic is reused from the
  proven read-only UIA probe.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.Server;

type
  // Static, sealed namespace for the Desktop MCP tool registration. Never
  // instantiated (no constructor): the single entry point is a class procedure so
  // it has a named owner (TDesktopTools.RegisterTools) instead of floating free in
  // the unit interface. All the handler wiring stays private in the implementation.
  TDesktopTools = class sealed
  public
    // Registers the desktop tools on AServer. Matches the DbRegisterTools shape.
    // There is no per-call state to own, so no context object is passed.
    class procedure RegisterTools(const AServer: TMCPServer); static;
  end;

implementation

uses
  Winapi.Windows,
  Winapi.ActiveX,
  System.Variants,
  System.Win.ComObj,
  Aefos.Win.UIAutomation,
  Aefos.MCP.ConsentView,
  Aefos.Desktop.Guard,
  Aefos.Desktop.ReadShape,
  Aefos.Desktop.Capture,
  Aefos.Desktop.Actions,
  Aefos.Desktop.Consent,
  Aefos.Desktop.Audit;

const
  DESKTOP_SERVER_NAME = 'aefos-desktop';
  DESKTOP_SERVER_VERSION = '0.4.1';

  // KEY-4 consent outcomes mapped to agent-actionable kebab reasons (desktop-
  // prefixed like the guard's). Returned when a destructive action was NOT
  // confirmed by a physical human on the trusted consent window.
  DESKTOP_REASON_CONFIRM_TIMED_OUT = 'desktop-confirmation-timed-out';
  DESKTOP_REASON_CONFIRM_DECLINED  = 'desktop-confirmation-declined';
  DESKTOP_REASON_NO_SESSION        = 'desktop-no-interactive-session';

  // How long the human has to physically confirm a destructive action before the
  // consent window fails closed (fail-safe: no confirmation => no action).
  // 30s was not enough in the field: a window has to be NOTICED before it can be
  // answered, and the answer must be a PHYSICAL keypress on that window. The
  // timeout is the budget for a human to look up, read and reach the keyboard --
  // not for a machine to respond.
  DESKTOP_CONFIRM_TIMEOUT_MS = 90000;

  // The window sample is capped so a machine with hundreds of top-level windows
  // cannot produce an unbounded frame; the count is always reported in full.
  DESKTOP_MAX_WINDOWS = 200;

  // What a redacted name/value is replaced with before it leaves this process.
  DESKTOP_REDACTED = '[redacted]';

  // The default deny-list (finding M7 + the master plan): password managers and
  // banking apps are ALWAYS redacted on read (and, in a later phase, never
  // written to — deny wins). Built in so the protection cannot be config'd away
  // by omission; the operator can only ADD to it.
  DESKTOP_DEFAULT_DENY =
    '*keepass*;*1password*;*bitwarden*;*lastpass*;*dashlane*;*keeper*;' +
    '*bank*;*banco*;*nubank*;*itau*;*bradesco*;*santander*';

  // QueryFullProcessImageName wants a process handle with this narrow right; it is
  // available to any caller for any process it can see (unlike PROCESS_QUERY_
  // INFORMATION). Declared locally: the RTL's Winapi.Windows does not export it.
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;

function QueryFullProcessImageNameW(hProcess: THandle; dwFlags: DWORD;
  lpExeName: PWideChar; var lpdwSize: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'QueryFullProcessImageNameW';

// --- MCP result plumbing -----------------------------------------------------

function _TextResult(const AText: string): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  Result.Content := AText;
end;

// Serialises AJson to a compact string and frees it (mirrors the DB frontier's
// _JsonResult ownership contract).
function _JsonResult(const AJson: TJSONObject): TMCPToolResult;
begin
  try
    Result := _TextResult(AJson.ToJSON);
  finally
    AJson.Free;
  end;
end;

// --- param readers -----------------------------------------------------------

// Required integer (accepts a JSON number or a numeric string). Raises when
// absent or not numeric.
function _ReqInt(const AParams: TJSONObject; const AName: string): Int64;
var
  LValue: TJSONValue;
  LTmp: Int64;
begin
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create(AName + ' required (number)');
  LValue := AParams.GetValue(AName);
  if LValue is TJSONNumber then
    Exit(TJSONNumber(LValue).AsInt64);
  if (LValue is TJSONString) and TryStrToInt64(TJSONString(LValue).Value, LTmp) then
    Exit(LTmp);
  raise EMCPInvalidParams.Create(AName + ' required (number)');
end;

// Optional integer with a default (JSON number or numeric string).
function _OptInt(const AParams: TJSONObject; const AName: string;
  ADefault: Integer): Integer;
var
  LValue: TJSONValue;
  LTmp: Integer;
begin
  Result := ADefault;
  if not Assigned(AParams) then
    Exit;
  LValue := AParams.GetValue(AName);
  if LValue is TJSONNumber then
    Result := TJSONNumber(LValue).AsInt
  else if (LValue is TJSONString) and TryStrToInt(TJSONString(LValue).Value, LTmp) then
    Result := LTmp;
end;

// Optional string ('' when absent).
function _OptStr(const AParams: TJSONObject; const AName: string): string;
var
  LValue: TJSONValue;
begin
  Result := '';
  if not Assigned(AParams) then
    Exit;
  LValue := AParams.GetValue(AName);
  if LValue is TJSONString then
    Result := TJSONString(LValue).Value;
end;

// --- the ONE injectable policy point (guard consumes this) -------------------
// Phase 4 sources the config from environment variables so a test can drive
// every branch; the real origin is the trusted binary-harness (a future phase).
//   AEFOS_DESKTOP_ALLOWLIST      ';'-globs the agent may treat as in-scope
//   AEFOS_DESKTOP_DENYLIST       EXTRA ';'-globs, appended to the built-in deny
//   AEFOS_DESKTOP_UNSCOPED_READ  '1' => whole-desktop read consent (titles on)
//   AEFOS_DESKTOP_FORBIDDEN_TYPE EXTRA ';'-globs never allowed typed input
function _DesktopPolicy: TDesktopPolicyConfig;
begin
  Result := Default(TDesktopPolicyConfig);
  Result.AllowList := TDesktopGuard.ParseList(GetEnvironmentVariable('AEFOS_DESKTOP_ALLOWLIST'));
  Result.DenyList := TDesktopGuard.ParseList(DESKTOP_DEFAULT_DENY) +
    TDesktopGuard.ParseList(GetEnvironmentVariable('AEFOS_DESKTOP_DENYLIST'));
  Result.ForbiddenTypeTargets :=
    TDesktopGuard.ParseList(GetEnvironmentVariable('AEFOS_DESKTOP_FORBIDDEN_TYPE'));
  Result.AllowUnscopedRead :=
    Trim(GetEnvironmentVariable('AEFOS_DESKTOP_UNSCOPED_READ')) = '1';
end;

// KEY 1 (host consent) stand-in: whether the human enabled desktop INPUT. Default
// OFF. Real origin is the trusted binary-harness (future); read from the env here
// so a test drives it. The agent cannot set this — it is off-LLM by construction.
function _DesktopHostConsent: Boolean;
begin
  Result := Trim(GetEnvironmentVariable('AEFOS_DESKTOP_ALLOW_INPUT')) = '1';
end;

// The advice to attach when a refusal or a blanket redaction is caused by the
// addon never having been SCOPED, rather than by anything about the target.
//
// Returns '' unless nothing is configured at all, so a normal refusal (this
// window is deny-listed, this one is out of a scope that exists) stays terse.
// One function rather than a string per call site: the first version of this
// shipped on two tools out of six, and the four that were left bare are exactly
// the ones an agent hits AFTER it has already found a window -- so the useful
// half of the answer was missing from the half of the flow that needed it.
{ The extra sentence that is ONLY true when the host draws what we report.

  The IDE gateway sets AEFOS_DESKTOP_HOST_RENDERS when it spawns this server,
  because it is the only party that knows: it renders the live card itself. Any
  other caller -- a terminal agent, another IDE, a script -- gets nothing, and
  the guidance stays true for them. Claiming a watcher that does not exist is the
  same defect as hiding one that does. }
function _HostRendersNote: string;
begin
  if Trim(GetEnvironmentVariable('AEFOS_DESKTOP_HOST_RENDERS')) = '1' then
    Result := ' The person running this is watching a live view built from '
      + 'those two captures, so skipping either leaves them looking at nothing.'
  else
    Result := '';
end;

function _ScopeAdvice: string;
var
  LConfig: TDesktopPolicyConfig;
begin
  Result := '';
  LConfig := _DesktopPolicy;
  if (Length(LConfig.AllowList) > 0) or LConfig.AllowUnscopedRead then
    Exit;
  Result := 'No scope is configured, so NO window is readable and none can be '
    + 'captured or operated -- this is not a decision about this window. Set '
    + 'AEFOS_DESKTOP_ALLOWLIST (semicolon-separated globs on the exe path, e.g. '
    + '*\MyApp.exe) or AEFOS_DESKTOP_UNSCOPED_READ=1, plus '
    + 'AEFOS_DESKTOP_ALLOW_INPUT=1 for clicking and typing, in the env block of '
    + 'this server''s entry in %USERPROFILE%\.aefos\addons\mcp-servers.json '
    + '-- the AGGREGATE. The per-addon %USERPROFILE%\.aefos\addons\<name>'
    + '\mcp.json is NOT read by the host: it is an input to `aefos install`, '
    + 'which regenerates the aggregate. Editing it by hand changes nothing, no '
    + 'matter how many times you restart. The env block is read when this server '
    + 'STARTS, so a correct edit still needs the host that spawns it (the IDE) '
    + 'restarted afterwards.';
end;

// --- exe-path identity (finding H4) ------------------------------------------

// The full image path of a process, via QueryFullProcessImageName. '' when the
// process cannot be opened (never raises — an unresolved path just means the read
// guard treats the window as out-of-scope and redacts it, which is the safe side).
function _ExePathForPid(APid: Cardinal): string;
var
  LProc: THandle;
  LBuf: array[0..1023] of WideChar;
  LSize: DWORD;
begin
  Result := '';
  if APid = 0 then
    Exit;
  LProc := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, APid);
  if LProc = 0 then
    Exit;
  try
    LSize := Length(LBuf);
    if QueryFullProcessImageNameW(LProc, 0, @LBuf[0], LSize) then
      SetString(Result, PWideChar(@LBuf[0]), LSize);
  finally
    CloseHandle(LProc);
  end;
end;

// The owning PID of a top-level window.
function _PidForHwnd(AHwnd: HWND): Cardinal;
var
  LPid: DWORD;
begin
  LPid := 0;
  if AHwnd <> 0 then
    GetWindowThreadProcessId(AHwnd, @LPid);
  Result := LPid;
end;

// --- read-only UIA property helpers (reused from the RO probe) ---------------
// OleVariant means no manual BSTR frees; VarIsNull/Empty guards a missing value.

// The TEXT a control currently holds, via UIA's ValuePattern.
//
// Not the same thing as Name, and the difference is the whole point: a Delphi
// TEdit's Name is empty, so a read that only asks for Name reports a form field
// as blank and the caller has to fall back to reading a screenshot. That made
// every input field unreadable as text -- fine for a calculator, useless for a
// CRUD screen.
//
// '' when the element has no ValuePattern (buttons, panels, most things), which
// is the common case and not an error.
function _ElValue(const AEl: IUIAutomationElement): string;
var
  LUnk: IUnknown;
  LPattern: IUIAutomationValuePattern;
  LBuf: PChar;
begin
  Result := '';
  if AEl = nil then
    Exit;
  if not Succeeded(AEl.GetCurrentPattern(UIA_ValuePatternId, LUnk)) then
    Exit;
  if LUnk = nil then
    Exit;
  if not Supports(LUnk, IUIAutomationValuePattern, LPattern) then
    Exit;
  LBuf := nil;
  if not Succeeded(LPattern.get_CurrentValue(LBuf)) then
    Exit;
  if LBuf = nil then
    Exit;
  try
    Result := string(LBuf);
  finally
    // COM BSTR: the callee allocated it, we own it.
    SysFreeString(PWideChar(LBuf));
  end;
end;

function _ElName(const AEl: IUIAutomationElement): string;
var
  LVar: OleVariant;
begin
  Result := '';
  if AEl = nil then
    Exit;
  if Succeeded(AEl.GetCurrentPropertyValue(UIA_NamePropertyId, LVar)) then
    if not VarIsNull(LVar) and not VarIsEmpty(LVar) then
      Result := VarToStr(LVar);
end;

function _ElAutoId(const AEl: IUIAutomationElement): string;
var
  LVar: OleVariant;
begin
  Result := '';
  if AEl = nil then
    Exit;
  if Succeeded(AEl.GetCurrentPropertyValue(UIA_AutomationIdPropertyId, LVar)) then
    if not VarIsNull(LVar) and not VarIsEmpty(LVar) then
      Result := VarToStr(LVar);
end;

function _ElControlType(const AEl: IUIAutomationElement): Integer;
var
  LVar: OleVariant;
begin
  Result := 0;
  if AEl = nil then
    Exit;
  if Succeeded(AEl.GetCurrentPropertyValue(UIA_ControlTypePropertyId, LVar)) then
    if not VarIsNull(LVar) and not VarIsEmpty(LVar) then
      Result := LVar;
end;

function _ElProcessId(const AEl: IUIAutomationElement): Cardinal;
var
  LPid: Integer;
begin
  Result := 0;
  if AEl = nil then
    Exit;
  LPid := 0;
  if Succeeded(AEl.get_CurrentProcessId(LPid)) then
    Result := Cardinal(LPid);
end;

function _ElNativeHwnd(const AEl: IUIAutomationElement): NativeInt;
var
  LHandle: HWND;
begin
  Result := 0;
  if AEl = nil then
    Exit;
  if Succeeded(AEl.get_CurrentNativeWindowHandle(LHandle)) then
    Result := NativeInt(LHandle);
end;

// Applies the M7 privacy gate to a single name/title/value string.
function _MaybeRedact(const AText: string; ARedact: Boolean): string;
begin
  if ARedact then
    Result := DESKTOP_REDACTED
  else
    Result := AText;
end;

// The UIA root, freshly resolved. Raised as an MCP error when UIA is unavailable.
function _NewUia: IUIAutomation;
begin
  Result := CreateComObject(CLSID_CUIAutomation) as IUIAutomation;
  if Result = nil then
    raise EMCPError.Create(MCP_ERR_SERVER,
      'UI Automation is not available on this machine (CoCreateInstance of ' +
      'CLSID_CUIAutomation failed).');
end;

// Resolves the exe-path identity of a window and asks the guard whether its
// title/contents must be redacted (M7). AExePath returns the resolved path.
function _RedactForHwnd(AHwnd: HWND; out AExePath: string): Boolean;
var
  LTarget: TDesktopTarget;
  LVerdict: TDesktopVerdict;
  LPid: Cardinal;
begin
  LPid := _PidForHwnd(AHwnd);
  LTarget := TDesktopTarget.Create(NativeInt(AHwnd), LPid, _ExePathForPid(LPid));
  AExePath := LTarget.ExePath;
  LVerdict := TDesktopGuard.ClassifyRead(LTarget, _DesktopPolicy);
  Result := LVerdict.RedactTitle;
end;

// --- desktop_list_windows ----------------------------------------------------

// Enumerates every top-level window from the UIA root, with per-window M7
// redaction: {"server":..,"count":N,"truncated":bool,"windows":[
//   {"name":"..|[redacted]","control_type":"Window","hwnd":123,"process":"x.exe",
//    "redacted":bool}, ...]}
function _EnumerateWindows: TJSONObject;
var
  LUia: IUIAutomation;
  LRoot, LChild: IUIAutomationElement;
  LTrue: IUIAutomationCondition;
  LArr: IUIAutomationElementArray;
  LCount, LIndex, LEmitted, LRedacted: Integer;
  LWindows: TJSONArray;
  LEntry: TJSONObject;
  LConfig: TDesktopPolicyConfig;
  LTarget: TDesktopTarget;
  LRedact: Boolean;
  LPid: Cardinal;
begin
  Result := TJSONObject.Create;
  LWindows := TJSONArray.Create;
  Result.AddPair('server', DESKTOP_SERVER_NAME);
  Result.AddPair('windows', LWindows);
  LConfig := _DesktopPolicy;

  // COM is initialised for the whole process at startup, but a tool handler may
  // run on a worker thread that was never initialised — do it per call, STA-safe.
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    LUia := _NewUia;
    if Failed(LUia.GetRootElement(LRoot)) or (LRoot = nil) then
      raise EMCPError.Create(MCP_ERR_SERVER, 'UI Automation returned no root element.');
    if Failed(LUia.CreateTrueCondition(LTrue)) then
      raise EMCPError.Create(MCP_ERR_SERVER,
        'UI Automation could not create the enumeration condition.');
    if Failed(LRoot.FindAll(TreeScope_Children, LTrue, LArr)) or (LArr = nil) then
      raise EMCPError.Create(MCP_ERR_SERVER,
        'UI Automation could not enumerate the top-level windows.');

    LArr.get_Length(LCount);
    LEmitted := 0;
    LRedacted := 0;
    for LIndex := 0 to LCount - 1 do
    begin
      if Failed(LArr.GetElement(LIndex, LChild)) or (LChild = nil) then
        Continue;
      if LEmitted >= DESKTOP_MAX_WINDOWS then
        Break;

      // Identity by exe path (H4), redaction by the pure guard (M7).
      LPid := _ElProcessId(LChild);
      LTarget := TDesktopTarget.Create(_ElNativeHwnd(LChild), LPid, _ExePathForPid(LPid));
      LRedact := TDesktopGuard.ClassifyRead(LTarget, LConfig).RedactTitle;

      LEntry := TJSONObject.Create;
      LEntry.AddPair('name', _MaybeRedact(_ElName(LChild), LRedact));
      // The control's TEXT, when it has any. Emitted only when non-empty so a tree of
  // buttons does not grow a 'value':'' on every node. It goes through the SAME
  // redaction gate as the name -- a field's contents are strictly more sensitive
  // than its label, and letting the value out of a window whose title we refuse
  // to say would defeat the whole privacy rule.
      if _ElValue(LChild) <> '' then
        LEntry.AddPair('value', _MaybeRedact(_ElValue(LChild), LRedact));
      LEntry.AddPair('control_type', TDesktopReadShape.ControlTypeName(_ElControlType(LChild)));
      LEntry.AddPair('hwnd', TJSONNumber.Create(LTarget.HWnd));
      LEntry.AddPair('process', ExtractFileName(LTarget.ExePath));
      LEntry.AddPair('redacted', TJSONBool.Create(LRedact));
      LWindows.AddElement(LEntry);
      Inc(LEmitted);
      if LRedact then
        Inc(LRedacted);
    end;

    Result.AddPair('count', TJSONNumber.Create(LCount));
    Result.AddPair('truncated', TJSONBool.Create(LEmitted < LCount));
    // The plan, handed over at the moment it is needed.
    //
    // The tool DESCRIPTIONS carry the same rule, but a description is read once
    // when the catalogue loads and competes with a hundred others. This arrives
    // in the answer to the first call of the flow -- an agent that just asked
    // "which windows are there" is, by definition, about to start. Same idea as
    // the IDE tools' FlowGuide next-prompt.
    //
    // Advisory, never enforcing: the guard still decides what is allowed, and an
    // agent free to ignore this is an agent whose refusals still make sense.
    Result.AddPair('next_steps',
      '1) desktop_window_capture on the target hwnd -- do this BEFORE touching '
      + 'anything. 2) desktop_window_tree to read the REAL control names; never '
      + 'guess one. 3) desktop_invoke / desktop_type_text to act. '
      + '4) desktop_window_capture again. Read results from a control''s "value" '
      + 'field, not from a screenshot. The captures in 1 and 4 are your PROOF of '
      + 'what actually changed -- without the before one you cannot tell your '
      + 'own effect from what was already there. STEP 3 IS NOT OPTIONAL: reading '
      + 'the tree tells you what the app CONTAINS, never what it would DO. If you '
      + 'answer from your own reasoning instead of operating and re-reading, you '
      + 'have reported your arithmetic and called it the program -- and the user '
      + 'is looking at a screen that says otherwise.'
      + _HostRendersNote);
    // Say WHY when the answer is uniformly useless.
    //
    // An unconfigured install redacts every title and refuses every capture, and
    // said nothing about it: an agent got a list of '[redacted]' with no way to
    // learn that a scope was never set, and a user got an addon that installs
    // cleanly and does nothing. Silence is the defect -- the same shape as a menu
    // item that vanishes without a word. Only emitted when NOTHING was in scope,
    // so a normal answer stays clean.
    if (LEmitted > 0) and (LRedacted = LEmitted) and (_ScopeAdvice <> '') then
      Result.AddPair('scope_notice', _ScopeAdvice);
  finally
    LUia := nil;
    CoUninitialize;
  end;
end;

// --- desktop_window_tree -----------------------------------------------------

// One element as a JSON node; recurses into children while within the depth and
// node budget. The NAME is redacted when ARedact (M7); the structural fields
// (control_type, automation_id, hwnd) are always kept so the agent can navigate.
function _BuildTreeNode(const AWalker: IUIAutomationTreeWalker;
  const AEl: IUIAutomationElement; ADepth: Integer;
  const ALimits: TDesktopTreeLimits; ARedact: Boolean;
  var ACount: Integer): TJSONObject;
var
  LChild, LNext: IUIAutomationElement;
  LChildren: TJSONArray;
  LAuto: string;
  LHwnd: NativeInt;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', _MaybeRedact(_ElName(AEl), ARedact));
  // The control's TEXT, when it has any. Emitted only when non-empty so a tree of
  // buttons does not grow a 'value':'' on every node. It goes through the SAME
  // redaction gate as the name -- a field's contents are strictly more sensitive
  // than its label, and letting the value out of a window whose title we refuse
  // to say would defeat the whole privacy rule.
  if _ElValue(AEl) <> '' then
    Result.AddPair('value', _MaybeRedact(_ElValue(AEl), ARedact));
  Result.AddPair('control_type', TDesktopReadShape.ControlTypeName(_ElControlType(AEl)));
  LAuto := _ElAutoId(AEl);
  if LAuto <> '' then
    Result.AddPair('automation_id', LAuto);
  LHwnd := _ElNativeHwnd(AEl);
  if LHwnd <> 0 then
    Result.AddPair('hwnd', TJSONNumber.Create(LHwnd));

  if ADepth >= ALimits.MaxDepth then
    Exit;

  LChildren := TJSONArray.Create;
  if Succeeded(AWalker.GetFirstChildElement(AEl, LChild)) then
    while (LChild <> nil) and (ACount < ALimits.MaxNodes) do
    begin
      Inc(ACount);
      LChildren.AddElement(
        _BuildTreeNode(AWalker, LChild, ADepth + 1, ALimits, ARedact, ACount));
      if Failed(AWalker.GetNextSiblingElement(LChild, LNext)) then
        Break;
      LChild := LNext;
    end;
  if LChildren.Count > 0 then
    Result.AddPair('children', LChildren)
  else
    LChildren.Free;
end;

function _WindowTree(AHwnd: NativeInt; AReqDepth, AReqNodes: Integer): TJSONObject;
var
  LUia: IUIAutomation;
  LRoot: IUIAutomationElement;
  LWalker: IUIAutomationTreeWalker;
  LLimits: TDesktopTreeLimits;
  LRedact: Boolean;
  LExePath: string;
  LCount: Integer;
begin
  if AHwnd = 0 then
    raise EMCPInvalidParams.Create('hwnd required (number) — obtain it from desktop_list_windows');
  Result := TJSONObject.Create;
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    LUia := _NewUia;
    if Failed(LUia.ElementFromHandle(HWND(AHwnd), LRoot)) or (LRoot = nil) then
      raise EMCPInvalidParams.Create(
        'no UI Automation element for that hwnd (window gone or not automatable)');
    if Failed(LUia.get_ControlViewWalker(LWalker)) or (LWalker = nil) then
      raise EMCPError.Create(MCP_ERR_SERVER,
        'UI Automation could not create the control-view tree walker.');

    LRedact := _RedactForHwnd(HWND(AHwnd), LExePath);
    LLimits := TDesktopReadShape.ClampTreeLimits(AReqDepth, AReqNodes);
    LCount := 0;

    Result.AddPair('server', DESKTOP_SERVER_NAME);
    Result.AddPair('hwnd', TJSONNumber.Create(AHwnd));
    Result.AddPair('process', ExtractFileName(LExePath));
    Result.AddPair('redacted', TJSONBool.Create(LRedact));
    Result.AddPair('max_depth', TJSONNumber.Create(LLimits.MaxDepth));
    Result.AddPair('max_nodes', TJSONNumber.Create(LLimits.MaxNodes));
    Result.AddPair('tree',
      _BuildTreeNode(LWalker, LRoot, 0, LLimits, LRedact, LCount));
    Result.AddPair('node_count', TJSONNumber.Create(LCount));
    Result.AddPair('truncated', TJSONBool.Create(LCount >= LLimits.MaxNodes));
    // A redacted tree/find is STRUCTURALLY fine and semantically useless: the
    // shape is there (24 buttons) but not which one is '7' or '/'. Reporting
    // success and nothing else is the description/behaviour mismatch -- the
    // caller cannot tell "this window has no names" from "you were never given
    // a scope". Say which, when it is the second.
    if LRedact and (_ScopeAdvice <> '') then
      Result.AddPair('scope_notice', _ScopeAdvice);
  finally
    LUia := nil;
    CoUninitialize;
  end;
end;

// --- desktop_element_find ----------------------------------------------------

// Builds the AND of the supplied property criteria. Raises when no criterion is
// given (a find with no criteria would dump the whole tree — use window_tree) or
// when control_type names no known type.
function _BuildFindCondition(const AUia: IUIAutomation;
  const AControlType, AAutomationId, AName: string): IUIAutomationCondition;

  procedure _Fold(const ANext: IUIAutomationCondition);
  var
    LCombined: IUIAutomationCondition;
  begin
    if Result = nil then
      Result := ANext
    else if Succeeded(AUia.CreateAndCondition(Result, ANext, LCombined)) then
      Result := LCombined;
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
      raise EMCPInvalidParams.Create(
        'unknown control_type "' + AControlType + '" (try Button, Edit, MenuItem, ' +
        'Window, Pane, Text, or a numeric UIA control-type id)');
    LVar := LCtId;
    if Succeeded(AUia.CreatePropertyCondition(UIA_ControlTypePropertyId, LVar, LCond)) then
      _Fold(LCond);
  end;

  if Trim(AAutomationId) <> '' then
  begin
    LVar := AAutomationId;
    if Succeeded(AUia.CreatePropertyCondition(UIA_AutomationIdPropertyId, LVar, LCond)) then
      _Fold(LCond);
  end;

  if AName <> '' then
  begin
    LVar := AName;
    if Succeeded(AUia.CreatePropertyCondition(UIA_NamePropertyId, LVar, LCond)) then
      _Fold(LCond);
  end;

  if Result = nil then
    raise EMCPInvalidParams.Create(
      'provide at least one of control_type / automation_id / name to match');
end;

function _ElementFind(AHwnd: NativeInt; const AControlType, AAutomationId,
  AName: string; AReqMax: Integer): TJSONObject;
var
  LUia: IUIAutomation;
  LRoot, LMatch: IUIAutomationElement;
  LCond: IUIAutomationCondition;
  LArr: IUIAutomationElementArray;
  LMatches: TJSONArray;
  LEntry: TJSONObject;
  LCount, LIndex, LEmitted, LMax: Integer;
  LRedact: Boolean;
  LExePath, LAuto: string;
  LMatchHwnd: NativeInt;
begin
  if AHwnd = 0 then
    raise EMCPInvalidParams.Create('hwnd required (number) — obtain it from desktop_list_windows');
  Result := TJSONObject.Create;
  LMatches := TJSONArray.Create;
  Result.AddPair('matches', LMatches);
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    LUia := _NewUia;
    if Failed(LUia.ElementFromHandle(HWND(AHwnd), LRoot)) or (LRoot = nil) then
      raise EMCPInvalidParams.Create(
        'no UI Automation element for that hwnd (window gone or not automatable)');

    LCond := _BuildFindCondition(LUia, AControlType, AAutomationId, AName);
    // TreeScope_Subtree includes the root itself + all descendants, so a match on
    // the window element is found too.
    if Failed(LRoot.FindAll(TreeScope_Subtree, LCond, LArr)) or (LArr = nil) then
      raise EMCPError.Create(MCP_ERR_SERVER,
        'UI Automation could not run the element search.');

    LRedact := _RedactForHwnd(HWND(AHwnd), LExePath);
    LMax := TDesktopReadShape.ClampFindMax(AReqMax);

    LArr.get_Length(LCount);
    LEmitted := 0;
    for LIndex := 0 to LCount - 1 do
    begin
      if LEmitted >= LMax then
        Break;
      if Failed(LArr.GetElement(LIndex, LMatch)) or (LMatch = nil) then
        Continue;
      LEntry := TJSONObject.Create;
      LEntry.AddPair('name', _MaybeRedact(_ElName(LMatch), LRedact));
      // The control's TEXT, when it has any. Emitted only when non-empty so a tree of
  // buttons does not grow a 'value':'' on every node. It goes through the SAME
  // redaction gate as the name -- a field's contents are strictly more sensitive
  // than its label, and letting the value out of a window whose title we refuse
  // to say would defeat the whole privacy rule.
      if _ElValue(LMatch) <> '' then
        LEntry.AddPair('value', _MaybeRedact(_ElValue(LMatch), LRedact));
      LEntry.AddPair('control_type', TDesktopReadShape.ControlTypeName(_ElControlType(LMatch)));
      LAuto := _ElAutoId(LMatch);
      if LAuto <> '' then
        LEntry.AddPair('automation_id', LAuto);
      LMatchHwnd := _ElNativeHwnd(LMatch);
      if LMatchHwnd <> 0 then
        LEntry.AddPair('hwnd', TJSONNumber.Create(LMatchHwnd));
      LMatches.AddElement(LEntry);
      Inc(LEmitted);
    end;

    Result.AddPair('server', DESKTOP_SERVER_NAME);
    Result.AddPair('hwnd', TJSONNumber.Create(AHwnd));
    Result.AddPair('process', ExtractFileName(LExePath));
    Result.AddPair('redacted', TJSONBool.Create(LRedact));
    Result.AddPair('match_count', TJSONNumber.Create(LCount));
    Result.AddPair('returned', TJSONNumber.Create(LEmitted));
    Result.AddPair('truncated', TJSONBool.Create(LEmitted < LCount));
    // A redacted tree/find is STRUCTURALLY fine and semantically useless: the
    // shape is there (24 buttons) but not which one is '7' or '/'. Reporting
    // success and nothing else is the description/behaviour mismatch -- the
    // caller cannot tell "this window has no names" from "you were never given
    // a scope". Say which, when it is the second.
    if LRedact and (_ScopeAdvice <> '') then
      Result.AddPair('scope_notice', _ScopeAdvice);
  finally
    LUia := nil;
    CoUninitialize;
  end;
end;

// --- desktop_window_capture (PHASE 4b) ---------------------------------------

// Screenshots ONE window (by hwnd) after the guard's dtCapture tier clears it.
// The scope gate is a HARD refusal, not a redaction (C3): a window's pixels are
// all of its content at once, so a deny-listed/out-of-scope target is denied
// outright. On success the PNG rides back as an inline MCP image block (the
// vision model sees it) plus a small JSON summary in the text content.
function _CaptureWindow(AHwnd: NativeInt; AReqMaxDim: Integer): TMCPToolResult;
var
  LTarget: TDesktopTarget;
  LVerdict: TDesktopVerdict;
  LCap: TDesktopCaptureResult;
  LJson: TJSONObject;
  LPid: Cardinal;
begin
  Result := Default(TMCPToolResult);
  if AHwnd = 0 then
    raise EMCPInvalidParams.Create('hwnd required (number) — obtain it from desktop_list_windows');

  // Resolve identity by exe path (H4) and ask the guard's CAPTURE tier. Note the
  // whole check is exe-path based: no title, no attach-by-name.
  LPid := _PidForHwnd(HWND(AHwnd));
  LTarget := TDesktopTarget.Create(AHwnd, LPid, _ExePathForPid(LPid));
  LVerdict := TDesktopGuard.ClassifyCapture(LTarget, _DesktopPolicy);

  // Refused by scope/deny: return the kebab verdict as a normal tool result (the
  // agent reads the reason and self-corrects), NOT an image and NOT an exception.
  if not LVerdict.Allowed then
  begin
    LJson := TJSONObject.Create;
    LJson.AddPair('server', DESKTOP_SERVER_NAME);
    LJson.AddPair('ok', TJSONBool.Create(False));
    LJson.AddPair('reason', LVerdict.Reason);
    LJson.AddPair('hwnd', TJSONNumber.Create(AHwnd));
    LJson.AddPair('process', ExtractFileName(LTarget.ExePath));
    // 'desktop-out-of-scope' on an install that has NO scope at all is not a
    // decision about this window -- nothing would ever be in scope. Saying which
    // one it is turns a dead end into something the user can fix; the bare kebab
    // code reads like the window was rejected on its merits.
    if (LVerdict.Reason = DESKTOP_REASON_OUT_OF_SCOPE) and (_ScopeAdvice <> '') then
      LJson.AddPair('detail', _ScopeAdvice);
    Exit(_JsonResult(LJson));
  end;

  // Cleared: perform the actual PrintWindow capture (never steals foreground).
  LCap := TDesktopCapture.CaptureWindow(AHwnd, AReqMaxDim);

  LJson := TJSONObject.Create;
  LJson.AddPair('server', DESKTOP_SERVER_NAME);
  LJson.AddPair('ok', TJSONBool.Create(LCap.Ok));
  LJson.AddPair('hwnd', TJSONNumber.Create(AHwnd));
  LJson.AddPair('process', ExtractFileName(LTarget.ExePath));
  if not LCap.Ok then
  begin
    // An honest capture failure (blank surface, minimised, encode error): report
    // the kebab reason; the agent falls back to the UIA read tools.
    LJson.AddPair('reason', LCap.Reason);
    Exit(_JsonResult(LJson));
  end;

  LJson.AddPair('width', TJSONNumber.Create(LCap.Width));
  LJson.AddPair('height', TJSONNumber.Create(LCap.Height));
  LJson.AddPair('source_width', TJSONNumber.Create(LCap.SourceWidth));
  LJson.AddPair('source_height', TJSONNumber.Create(LCap.SourceHeight));
  LJson.AddPair('scaled', TJSONBool.Create(LCap.Scaled));
  Result.Content := LJson.ToJSON;
  LJson.Free;
  // The picture: the core appends this as an MCP `image` block so the model SEES
  // the window (the point of capture for a vision model).
  Result.ImageBase64 := LCap.PngBase64;
  Result.ImageMimeType := 'image/png';
end;

// --- write tools (PHASE 5) ---------------------------------------------------

// Resolves AHwnd to a guard target (exe-path identity, H4) and asks the guard
// whether AToolName may act on it (deny/scope/M6/host-consent, all pure). On a
// REFUSAL, returns False and fills ARefusal with {"ok":false,"reason":..}; the
// caller returns that as-is and does nothing. On a PASS, returns True with
// ATarget filled for the mechanism (which does the TOCTOU re-check + acts).
function _GuardWrite(const AToolName: string; AHwnd: NativeInt;
  out ATarget: TDesktopTarget; out ARefusal: TMCPToolResult): Boolean;
var
  LVerdict: TDesktopVerdict;
  LJson: TJSONObject;
  LPid: Cardinal;
begin
  if AHwnd = 0 then
    raise EMCPInvalidParams.Create('hwnd required (number) — obtain it from desktop_list_windows');
  LPid := _PidForHwnd(HWND(AHwnd));
  ATarget := TDesktopTarget.Create(AHwnd, LPid, _ExePathForPid(LPid));

  // Write pack: no destructive tools here, so AConfirmed is always False (a
  // destructive tier would additionally require the KEY-4 confirmation window).
  LVerdict := TDesktopGuard.Decide(AToolName, ATarget, _DesktopPolicy,
    _DesktopHostConsent, False);
  Result := LVerdict.Allowed;
  if Result then
    Exit;

  LJson := TJSONObject.Create;
  LJson.AddPair('server', DESKTOP_SERVER_NAME);
  LJson.AddPair('ok', TJSONBool.Create(False));
  LJson.AddPair('reason', LVerdict.Reason);
  LJson.AddPair('hwnd', TJSONNumber.Create(AHwnd));
  LJson.AddPair('process', ExtractFileName(ATarget.ExePath));
  if (LVerdict.Reason = DESKTOP_REASON_OUT_OF_SCOPE) and (_ScopeAdvice <> '') then
    LJson.AddPair('detail', _ScopeAdvice);
  ARefusal := _JsonResult(LJson);
end;

// Turns a mechanism result into the tool result, and audits an EXECUTED write.
function _WriteResult(const AToolName: string; const ATarget: TDesktopTarget;
  const AAction: TDesktopActionResult): TMCPToolResult;
var
  LJson: TJSONObject;
begin
  LJson := TJSONObject.Create;
  LJson.AddPair('server', DESKTOP_SERVER_NAME);
  LJson.AddPair('ok', TJSONBool.Create(AAction.Ok));
  LJson.AddPair('hwnd', TJSONNumber.Create(ATarget.HWnd));
  LJson.AddPair('process', ExtractFileName(ATarget.ExePath));
  if AAction.Ok then
  begin
    LJson.AddPair('detail', AAction.Detail);
    // Only EXECUTED writes are audited (the guard passed AND the act ran).
    TDesktopAudit.AuditWrite(AToolName, ATarget.ExePath, AAction.Detail);
  end
  else
    LJson.AddPair('reason', AAction.Reason);
  Result := _JsonResult(LJson);
end;

// --- destructive tools (PHASE 6, KEY-4 human confirmation) -------------------

// The title of a top-level window (used ONLY to make the human consent prompt
// legible; identity is still the exe path, never this spoofable title). '' when
// the window has no title.
function _WindowTitle(AHwnd: HWND): string;
var
  LBuf: array[0..511] of Char;
  LLen: Integer;
begin
  Result := '';
  if AHwnd = 0 then
    Exit;
  LLen := GetWindowText(AHwnd, LBuf, Length(LBuf));
  if LLen > 0 then
    SetString(Result, LBuf, LLen);
end;

// Maps a TDesktopConfirmResult.Reason to a desktop-prefixed kebab code so the
// agent learns WHY a destructive action did not proceed.
function _ConsentReasonToKebab(const AReason: string): string;
begin
  if AReason = 'timed-out' then
    Result := DESKTOP_REASON_CONFIRM_TIMED_OUT
  else if AReason = 'declined' then
    Result := DESKTOP_REASON_CONFIRM_DECLINED
  else if AReason = 'no-interactive-session' then
    Result := DESKTOP_REASON_NO_SESSION
  else
    // 'confirmed' but the guard still refused (scope/consent changed between
    // passes): fall back to the guard's own requires-confirm code.
    Result := DESKTOP_REASON_REQUIRES_CONFIRM;
end;

// A destructive-tier refusal payload. AConsentReason (when non-empty) is included
// verbatim so the agent sees the human's consent outcome, not just the kebab.
function _DestructiveRefusal(AHwnd: NativeInt; const ATarget: TDesktopTarget;
  const AReason, AConsentReason: string): TMCPToolResult;
var
  LJson: TJSONObject;
begin
  LJson := TJSONObject.Create;
  LJson.AddPair('server', DESKTOP_SERVER_NAME);
  LJson.AddPair('ok', TJSONBool.Create(False));
  LJson.AddPair('reason', AReason);
  LJson.AddPair('hwnd', TJSONNumber.Create(AHwnd));
  LJson.AddPair('process', ExtractFileName(ATarget.ExePath));
  if (AReason = DESKTOP_REASON_OUT_OF_SCOPE) and (_ScopeAdvice <> '') then
    LJson.AddPair('detail', _ScopeAdvice);
  // A timeout here does NOT mean the human refused. It means nobody answered a
  // window that was put on screen -- and in the field that turned out to be a
  // window the user never saw, centred on the primary monitor while they worked
  // on the second one. Saying what was shown, and that the answer has to be a
  // physical keypress on that window, is the difference between a dead end and
  // something the user can go look for.
  if AConsentReason = 'timed-out' then
    LJson.AddPair('detail',
      'A confirmation window titled "Aefos Desktop - confirm action" was shown '
      + 'and nobody answered it within the timeout. It is deliberately answered '
      + 'ONLY by a PHYSICAL keypress on that window (injected input is refused '
      + 'by design), so it cannot be confirmed by any tool -- a human has to '
      + 'press the key. It opens centred on the monitor holding the target '
      + 'window. If no window was seen at all, that is the bug to report, not '
      + 'this refusal.');
  if AConsentReason <> '' then
    LJson.AddPair('consent', AConsentReason);
  Result := _JsonResult(LJson);
end;

// The two-pass destructive gate (do NOT reuse _GuardWrite — that hardcodes
// AConfirmed=False and never asks a human). We NEVER pop the human dialog for an
// action that would be refused anyway:
//   1. Resolve the target (hwnd->pid->exe-path), exactly like _GuardWrite.
//   2. FIRST PASS with AConfirmed=False. A refusal for ANY reason other than
//      desktop-requires-confirmation (out-of-scope / denied-app / input-disabled)
//      is returned immediately — no dialog.
//   3. If the ONLY thing missing is confirmation, show the trusted KEY-4 consent
//      window (rejects injected input, fails closed headless), then SECOND PASS
//      with the real human outcome. Allowed => act; still refused => map the
//      consent reason to a kebab.
// AActionVerb is a short imperative phrase naming the exact act (e.g. 'Close the
// window', 'Kill the process behind the window') for the consent prompt.
function _GuardDestructive(const AToolName, AActionVerb: string; AHwnd: NativeInt;
  out ATarget: TDesktopTarget; out ARefusal: TMCPToolResult): Boolean;
var
  LVerdict: TDesktopVerdict;
  LConfirm: TDesktopConfirmResult;
  LTitle, LExeName, LSummary, LHeading, LTargetLine: string;
  LView: TAefosConsentView;
  LPid: Cardinal;
begin
  if AHwnd = 0 then
    raise EMCPInvalidParams.Create('hwnd required (number) — obtain it from desktop_list_windows');
  LPid := _PidForHwnd(HWND(AHwnd));
  ATarget := TDesktopTarget.Create(AHwnd, LPid, _ExePathForPid(LPid));

  // FIRST PASS — no confirmation yet.
  LVerdict := TDesktopGuard.Decide(AToolName, ATarget, _DesktopPolicy,
    _DesktopHostConsent, False);
  if LVerdict.Allowed then
    // The guard cleared it outright (the destructive tier always needs KEY 4, so
    // this is defensive — honour it if a future guard change makes it possible).
    Exit(True);
  if LVerdict.Reason <> DESKTOP_REASON_REQUIRES_CONFIRM then
  begin
    // Refused for a reason a human confirmation cannot cure — return it, NO dialog.
    ARefusal := _DestructiveRefusal(AHwnd, ATarget, LVerdict.Reason, '');
    Exit(False);
  end;

  // Only human confirmation is missing. Present the trusted consent window.
  LTitle := _WindowTitle(HWND(AHwnd));
  LExeName := ExtractFileName(ATarget.ExePath);
  // Three lines, not one: the QUESTION, the CONSEQUENCE, and WHAT is being acted
  // on. The window used to render all of it as a single grey sentence, which is
  // how a user ends up pressing a key without having read which window it was
  // about.
  // Same model the IDE-side surfaces render. This process cannot share their
  // WIDGETS -- it has no VCL and must not gain one -- but it can and does share
  // their WORDS, which is what stops two windows reading as two products.
  if LTitle <> '' then
    LTargetLine := Format('%s - %s (pid %d, hwnd %d)',
      [LTitle, LExeName, ATarget.Pid, AHwnd])
  else
    LTargetLine := Format('%s (pid %d, hwnd %d)',
      [LExeName, ATarget.Pid, AHwnd]);
  LView := TAefosConsentModel.ForDesktopAction(AActionVerb, LTargetLine);
  LHeading := LView.Heading;
  LSummary := LView.Summary;
  // Anchor on the TARGET window so the confirmation appears on the monitor the
  // user is actually looking at.
  LConfirm := TDesktopConsent.RequestConfirmation(HWND(AHwnd),
    'Aefos AI - confirm a desktop action',
    LHeading, LSummary, LTargetLine, LView.Note, DESKTOP_CONFIRM_TIMEOUT_MS);

  // SECOND PASS — re-decide with the REAL human outcome.
  LVerdict := TDesktopGuard.Decide(AToolName, ATarget, _DesktopPolicy,
    _DesktopHostConsent, LConfirm.Confirmed);
  if LVerdict.Allowed then
    Exit(True);

  // Still refused. If the HUMAN confirmed but the guard now says no, the cause is
  // something that changed between passes (host consent revoked, scope/deny edited
  // mid-prompt) — surface the guard's OWN fresh reason so the agent learns
  // re-prompting is futile, not a misleading "confirmation required". Only when
  // consent itself failed (declined/timed-out/no-session) do we map that.
  if LConfirm.Confirmed then
    ARefusal := _DestructiveRefusal(AHwnd, ATarget, LVerdict.Reason, LConfirm.Reason)
  else
    ARefusal := _DestructiveRefusal(AHwnd, ATarget,
      _ConsentReasonToKebab(LConfirm.Reason), LConfirm.Reason);
  Result := False;
end;

// --- registration ------------------------------------------------------------

function _EmptyObjectSchema: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

// A JSON string array of required-property names (TJSONArray.Create takes at most
// one element inline, so a multi-name "required" is built here).
function _RequiredArray(const ANames: array of string): TJSONArray;
var
  LName: string;
begin
  Result := TJSONArray.Create;
  for LName in ANames do
    Result.Add(LName);
end;

procedure _RegisterPing(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_ping';
  LTool.Title := 'Desktop MCP health check';
  LTool.Description :=
    'Trivial health check for the Aefos Desktop MCP server. Takes no arguments ' +
    'and has NO side effects. Returns {"ok":true,"server":"aefos-desktop",' +
    '"version":"..."}. Call it to confirm the server is alive and responding.';
  LTool.InputSchema := _EmptyObjectSchema;
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LJson: TJSONObject;
    begin
      LJson := TJSONObject.Create;
      LJson.AddPair('ok', TJSONBool.Create(True));
      LJson.AddPair('server', DESKTOP_SERVER_NAME);
      LJson.AddPair('version', DESKTOP_SERVER_VERSION);
      Result := _JsonResult(LJson);
    end;
  AServer.RegisterTool(LTool);
end;

procedure _RegisterListWindows(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_list_windows';
  LTool.Title := 'List top-level desktop windows';
  LTool.Description :=
    'READ-ONLY. Enumerates the top-level windows currently open on the desktop ' +
    'via Windows UI Automation and returns, per window, its name, control type, ' +
    'native window handle (hwnd) and process image name, plus the total count. ' +
    'PRIVACY: a window belonging to a sensitive app (password manager, banking) ' +
    'or, by default, any window that is not the app you were asked to work on, ' +
    'comes back with "redacted":true and its name replaced by "[redacted]" — the ' +
    'hwnd and control type are still returned so you can navigate. It ONLY reads: ' +
    'it never clicks, types, focuses, moves, resizes, closes or kills anything. ' +
    'Takes no arguments. Use the hwnd it returns with desktop_window_tree / ' +
    'desktop_element_find.';
  LTool.InputSchema := _EmptyObjectSchema;
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _JsonResult(_EnumerateWindows);
    end;
  AServer.RegisterTool(LTool);
end;

procedure _RegisterWindowTree(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
  LProps: TJSONObject;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_window_tree';
  LTool.Title := 'Walk one window''s UI element tree';
  LTool.Description :=
    'READ-ONLY. Given a target window''s hwnd (from desktop_list_windows), walks ' +
    'its Windows UI Automation element tree and returns it nested as JSON: each ' +
    'node has {name, control_type, automation_id?, hwnd?, value?} with a ' +
    '"children" array. "value" is the TEXT the control currently HOLDS (UIA ' +
    'ValuePattern) and is present only on controls that have one — an Edit, a ' +
    'combo, a title bar. READ A FIELD''S CONTENTS FROM "value", NOT from a ' +
    'screenshot: "name" is the control''s LABEL and is empty on a Delphi TEdit, ' +
    'so a field whose "name" is "" is not blank, it just has no label. ' +
    'Use it to see a window''s structure so you can locate controls. "max_depth" ' +
    '(default 4, max 12) and "max_nodes" (default 500, max 5000) bound the walk; ' +
    '"truncated":true means the node cap was hit. PRIVACY: if the target is a ' +
    'sensitive/out-of-scope window, every node name AND value comes back ' +
    '"[redacted]" and "redacted":true (structure is still shown) — a field''s ' +
    'contents are gated exactly like its label. It ONLY reads — it never clicks, ' +
    'types, focuses, moves, closes or kills anything. THEREFORE: reading this ' +
    'tree is NOT doing the task. If the user asked the APPLICATION to do ' +
    'something, you have not done it until desktop_invoke / desktop_type_text ' +
    'has run and you have re-read the result here. Working the answer out ' +
    'yourself from what you see is a statement about your own arithmetic, not ' +
    'about the program, and it is wrong the moment the program disagrees.';
  LProps := TJSONObject.Create;
  LProps.AddPair('hwnd', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LProps.AddPair('max_depth', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LProps.AddPair('max_nodes', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LTool.InputSchema := TJSONObject.Create;
  LTool.InputSchema.AddPair('type', 'object');
  LTool.InputSchema.AddPair('properties', LProps);
  LTool.InputSchema.AddPair('required', TJSONArray.Create(TJSONString.Create('hwnd')));
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _JsonResult(_WindowTree(
        NativeInt(_ReqInt(AParams, 'hwnd')),
        _OptInt(AParams, 'max_depth', 0),
        _OptInt(AParams, 'max_nodes', 0)));
    end;
  AServer.RegisterTool(LTool);
end;

procedure _RegisterElementFind(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
  LProps: TJSONObject;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_element_find';
  LTool.Title := 'Find matching elements in one window';
  LTool.Description :=
    'READ-ONLY. Given a target window''s hwnd (from desktop_list_windows) and at ' +
    'least one criterion — "control_type" (e.g. Button, Edit, MenuItem, Window, ' +
    'Pane, Text, or a numeric UIA id), "automation_id", "name" — runs a Windows ' +
    'UI Automation search over that window''s subtree and returns the matching ' +
    'elements as {name, control_type, automation_id?, hwnd?, value?}. "value" is ' +
    'the TEXT the control currently HOLDS (UIA ValuePattern), present only on ' +
    'controls that have one. To READ what a field contains, find it (e.g. ' +
    'control_type "Edit") and read its "value" — do not screenshot it. An empty ' +
    '"name" means the control has no LABEL, not that it is empty. ' +
    'This is how you ' +
    'LOCATE "the OK button", "the email field", etc. "max_results" (default 100, ' +
    'max 1000) caps the list. PRIVACY: for a sensitive/out-of-scope window, match ' +
    'names AND values come back "[redacted]" with "redacted":true. It ONLY ' +
    'locates — it does ' +
    'NOT click, focus or type (those are a later, separately guarded phase).';
  LProps := TJSONObject.Create;
  LProps.AddPair('hwnd', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LProps.AddPair('control_type', TJSONObject.Create(TJSONPair.Create('type', 'string')));
  LProps.AddPair('automation_id', TJSONObject.Create(TJSONPair.Create('type', 'string')));
  LProps.AddPair('name', TJSONObject.Create(TJSONPair.Create('type', 'string')));
  LProps.AddPair('max_results', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LTool.InputSchema := TJSONObject.Create;
  LTool.InputSchema.AddPair('type', 'object');
  LTool.InputSchema.AddPair('properties', LProps);
  LTool.InputSchema.AddPair('required', TJSONArray.Create(TJSONString.Create('hwnd')));
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _JsonResult(_ElementFind(
        NativeInt(_ReqInt(AParams, 'hwnd')),
        _OptStr(AParams, 'control_type'),
        _OptStr(AParams, 'automation_id'),
        _OptStr(AParams, 'name'),
        _OptInt(AParams, 'max_results', 0)));
    end;
  AServer.RegisterTool(LTool);
end;

procedure _RegisterWindowCapture(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
  LProps: TJSONObject;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_window_capture';
  LTool.Title := 'Screenshot one window (as an image you can see)';
  LTool.Description :=
    'ALWAYS capture BEFORE you touch a window, and again AFTER you are done. ' +
    'The pair is your evidence: with only an after shot you cannot tell your own ' +
    'effect from what the window already looked like. Some hosts also render the ' +
    'pair live for the person watching. '+
    'Captures a screenshot of ONE window (by its hwnd from desktop_list_windows) ' +
    'and returns it as an image you can directly see and read text from. It uses ' +
    'PrintWindow, so it does NOT bring the window to the front, steal focus, move ' +
    'or change anything — the desktop is untouched, and the window is captured ' +
    'even if it is behind others. "max_dim" (default 1280, max 2560) bounds the ' +
    'longest edge; the image is downscaled to fit, aspect preserved (a smaller ' +
    'window is 1:1). SCOPE: unlike the text read tools, a screenshot cannot be ' +
    'partially redacted, so a sensitive (deny-listed) or out-of-scope window is ' +
    'REFUSED with {"ok":false,"reason":"desktop-denied-app"|"desktop-out-of-' +
    'scope"} rather than returned — capture only the app you were asked to work ' +
    'on. If the window cannot be rendered (e.g. minimised, or a blank GPU ' +
    'surface) it returns {"ok":false,"reason":"desktop-capture-..."}; fall back ' +
    'to desktop_window_tree / desktop_element_find to read it via UI Automation.';
  LProps := TJSONObject.Create;
  LProps.AddPair('hwnd', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LProps.AddPair('max_dim', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LTool.InputSchema := TJSONObject.Create;
  LTool.InputSchema.AddPair('type', 'object');
  LTool.InputSchema.AddPair('properties', LProps);
  LTool.InputSchema.AddPair('required', TJSONArray.Create(TJSONString.Create('hwnd')));
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _CaptureWindow(
        NativeInt(_ReqInt(AParams, 'hwnd')),
        _OptInt(AParams, 'max_dim', 0));
    end;
  AServer.RegisterTool(LTool);
end;

procedure _RegisterWindowFocus(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
  LProps: TJSONObject;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_window_focus';
  LTool.Title := 'Bring a window to the foreground';
  LTool.Description :=
    'WRITE. Brings ONE window (by hwnd) to the foreground. This changes the ' +
    'desktop, so it is gated: it only acts on an app you were allow-listed to ' +
    'control AND when desktop input is enabled by the human — otherwise it ' +
    'returns {"ok":false,"reason":"desktop-out-of-scope"|"desktop-input-' +
    'disabled"|"desktop-denied-app"} and does nothing. On success it restores a ' +
    'minimised window and focuses it.';
  LProps := TJSONObject.Create;
  LProps.AddPair('hwnd', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LTool.InputSchema := TJSONObject.Create;
  LTool.InputSchema.AddPair('type', 'object');
  LTool.InputSchema.AddPair('properties', LProps);
  LTool.InputSchema.AddPair('required', TJSONArray.Create(TJSONString.Create('hwnd')));
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LTarget: TDesktopTarget;
      LRefusal: TMCPToolResult;
    begin
      if not _GuardWrite('window_focus', NativeInt(_ReqInt(AParams, 'hwnd')),
        LTarget, LRefusal) then
        Exit(LRefusal);
      Result := _WriteResult('window_focus', LTarget,
        TDesktopActions.FocusWindow(LTarget.HWnd, LTarget.Pid));
    end;
  AServer.RegisterTool(LTool);
end;

procedure _RegisterWindowMove(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
  LProps: TJSONObject;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_window_move';
  LTool.Title := 'Move / resize a window';
  LTool.Description :=
    'WRITE. Moves ONE window (by hwnd) to screen position "x","y" and, if ' +
    '"width"/"height" are given (>0), resizes it; omit them to keep the current ' +
    'size. Gated exactly like desktop_window_focus (scope + host input consent); ' +
    'a refused call returns {"ok":false,"reason":...} and moves nothing. Z-order ' +
    'and activation are left untouched.';
  LProps := TJSONObject.Create;
  LProps.AddPair('hwnd', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LProps.AddPair('x', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LProps.AddPair('y', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LProps.AddPair('width', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LProps.AddPair('height', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LTool.InputSchema := TJSONObject.Create;
  LTool.InputSchema.AddPair('type', 'object');
  LTool.InputSchema.AddPair('properties', LProps);
  LTool.InputSchema.AddPair('required', _RequiredArray(['hwnd', 'x', 'y']));
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LTarget: TDesktopTarget;
      LRefusal: TMCPToolResult;
    begin
      if not _GuardWrite('window_move', NativeInt(_ReqInt(AParams, 'hwnd')),
        LTarget, LRefusal) then
        Exit(LRefusal);
      Result := _WriteResult('window_move', LTarget,
        TDesktopActions.MoveWindow(LTarget.HWnd, LTarget.Pid,
          _OptInt(AParams, 'x', 0), _OptInt(AParams, 'y', 0),
          _OptInt(AParams, 'width', 0), _OptInt(AParams, 'height', 0)));
    end;
  AServer.RegisterTool(LTool);
end;

procedure _RegisterInvoke(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
  LProps: TJSONObject;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_invoke';
  LTool.Title := 'Invoke an element (press a button, etc.)';
  LTool.Description :=
    'WRITE. Performs the DEFAULT action of ONE element inside a window — presses ' +
    'a button, expands a tree node, selects a menu item. Locate the element the ' +
    'same way as desktop_element_find: a "hwnd" plus at least one of ' +
    '"control_type"/"automation_id"/"name" (the FIRST match is invoked). It uses ' +
    'UI Automation''s InvokePattern, NOT a mouse click at coordinates, so it ' +
    'cannot miss and hit a neighbour. Gated by scope + host input consent; a ' +
    'refused call returns {"ok":false,"reason":...} and does nothing. If the ' +
    'element has no invokable action it returns "desktop-element-not-actionable"; ' +
    'if nothing matches, "desktop-element-not-found". AFTER invoking, re-read the ' +
    'relevant control with desktop_window_tree and report the value YOU READ ' +
    'BACK — never a value you computed. The app is the authority on what the app ' +
    'did; if the two differ, the app is right and you are reporting a bug.';
  LProps := TJSONObject.Create;
  LProps.AddPair('hwnd', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LProps.AddPair('control_type', TJSONObject.Create(TJSONPair.Create('type', 'string')));
  LProps.AddPair('automation_id', TJSONObject.Create(TJSONPair.Create('type', 'string')));
  LProps.AddPair('name', TJSONObject.Create(TJSONPair.Create('type', 'string')));
  LTool.InputSchema := TJSONObject.Create;
  LTool.InputSchema.AddPair('type', 'object');
  LTool.InputSchema.AddPair('properties', LProps);
  LTool.InputSchema.AddPair('required', TJSONArray.Create(TJSONString.Create('hwnd')));
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LTarget: TDesktopTarget;
      LRefusal: TMCPToolResult;
    begin
      if not _GuardWrite('invoke', NativeInt(_ReqInt(AParams, 'hwnd')),
        LTarget, LRefusal) then
        Exit(LRefusal);
      Result := _WriteResult('invoke', LTarget,
        TDesktopActions.InvokeElement(LTarget.HWnd, LTarget.Pid,
          _OptStr(AParams, 'control_type'),
          _OptStr(AParams, 'automation_id'),
          _OptStr(AParams, 'name')));
    end;
  AServer.RegisterTool(LTool);
end;

procedure _RegisterTypeText(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
  LProps: TJSONObject;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_type_text';
  LTool.Title := 'Set an element''s text';
  LTool.Description :=
    'WRITE. Sets the text of ONE editable element (a text box / edit field) ' +
    'inside a window. Locate it like desktop_element_find: a "hwnd" plus at ' +
    'least one of "control_type"/"automation_id"/"name"; "text" is the value to ' +
    'set. It uses UI Automation''s ValuePattern.SetValue — delivered to that ' +
    'specific control regardless of focus, so it is immune to a focus race (it ' +
    'never leaks keystrokes into another window). Gated by scope + host input ' +
    'consent, AND typing into a shell/terminal/browser address bar is REFUSED ' +
    'outright ("desktop-forbidden-target-class") since that would be arbitrary ' +
    'command execution. A read-only or non-editable element returns ' +
    '"desktop-element-not-actionable".';
  LProps := TJSONObject.Create;
  LProps.AddPair('hwnd', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LProps.AddPair('text', TJSONObject.Create(TJSONPair.Create('type', 'string')));
  LProps.AddPair('control_type', TJSONObject.Create(TJSONPair.Create('type', 'string')));
  LProps.AddPair('automation_id', TJSONObject.Create(TJSONPair.Create('type', 'string')));
  LProps.AddPair('name', TJSONObject.Create(TJSONPair.Create('type', 'string')));
  LTool.InputSchema := TJSONObject.Create;
  LTool.InputSchema.AddPair('type', 'object');
  LTool.InputSchema.AddPair('properties', LProps);
  LTool.InputSchema.AddPair('required', _RequiredArray(['hwnd', 'text']));
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LTarget: TDesktopTarget;
      LRefusal: TMCPToolResult;
    begin
      if not _GuardWrite('type_text', NativeInt(_ReqInt(AParams, 'hwnd')),
        LTarget, LRefusal) then
        Exit(LRefusal);
      Result := _WriteResult('type_text', LTarget,
        TDesktopActions.SetElementValue(LTarget.HWnd, LTarget.Pid,
          _OptStr(AParams, 'control_type'),
          _OptStr(AParams, 'automation_id'),
          _OptStr(AParams, 'name'),
          _OptStr(AParams, 'text')));
    end;
  AServer.RegisterTool(LTool);
end;

procedure _RegisterWindowClose(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
  LProps: TJSONObject;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_window_close';
  LTool.Title := 'Close a window (requires a live human to confirm)';
  LTool.Description :=
    'WRITE / DESTRUCTIVE. Closes ONE window (by hwnd) by posting WM_CLOSE — a ' +
    'RECOVERABLE request the app can still answer (it may prompt "save changes?"; ' +
    'it does NOT force-kill). Because it is destructive it requires, ON TOP of ' +
    'scope + host input consent, a LIVE HUMAN to physically confirm on a trusted ' +
    'Aefos window that REJECTS synthesized/automated input — so you cannot ' +
    'self-approve it. A refused call returns {"ok":false,"reason":...} and does ' +
    'NOTHING; reasons include desktop-out-of-scope, desktop-denied-app, ' +
    'desktop-input-disabled, desktop-confirmation-declined, ' +
    'desktop-confirmation-timed-out and desktop-no-interactive-session.';
  LProps := TJSONObject.Create;
  LProps.AddPair('hwnd', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LTool.InputSchema := TJSONObject.Create;
  LTool.InputSchema.AddPair('type', 'object');
  LTool.InputSchema.AddPair('properties', LProps);
  LTool.InputSchema.AddPair('required', TJSONArray.Create(TJSONString.Create('hwnd')));
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LTarget: TDesktopTarget;
      LRefusal: TMCPToolResult;
    begin
      if not _GuardDestructive('window_close', 'Close the window',
        NativeInt(_ReqInt(AParams, 'hwnd')), LTarget, LRefusal) then
        Exit(LRefusal);
      Result := _WriteResult('window_close', LTarget,
        TDesktopActions.CloseWindow(LTarget.HWnd, LTarget.Pid));
    end;
  AServer.RegisterTool(LTool);
end;

procedure _RegisterProcessKill(const AServer: TMCPServer);
var
  LTool: TMCPToolDescriptor;
  LProps: TJSONObject;
begin
  LTool := Default(TMCPToolDescriptor);
  LTool.Name := 'desktop_process_kill';
  LTool.Title := 'Force-terminate the process owning a window (human-confirmed)';
  LTool.Description :=
    'WRITE / DESTRUCTIVE. Forcibly TERMINATES the process that owns ONE window ' +
    '(by hwnd) — there is no "save?" prompt and unsaved data is LOST. It kills ' +
    'ONLY the exact process that still owns the window (never a recycled pid). ' +
    'Same gate as desktop_window_close: on top of scope + host input consent, a ' +
    'LIVE HUMAN must physically confirm on a trusted Aefos window that REJECTS ' +
    'synthesized input, so you cannot self-approve it. A refused call returns ' +
    '{"ok":false,"reason":...} and does NOTHING; reasons include ' +
    'desktop-out-of-scope, desktop-denied-app, desktop-input-disabled, ' +
    'desktop-confirmation-declined, desktop-confirmation-timed-out and ' +
    'desktop-no-interactive-session.';
  LProps := TJSONObject.Create;
  LProps.AddPair('hwnd', TJSONObject.Create(TJSONPair.Create('type', 'integer')));
  LTool.InputSchema := TJSONObject.Create;
  LTool.InputSchema.AddPair('type', 'object');
  LTool.InputSchema.AddPair('properties', LProps);
  LTool.InputSchema.AddPair('required', TJSONArray.Create(TJSONString.Create('hwnd')));
  LTool.Intent := tiNeutral;
  LTool.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LTarget: TDesktopTarget;
      LRefusal: TMCPToolResult;
    begin
      if not _GuardDestructive('process_kill', 'Kill the process behind the window',
        NativeInt(_ReqInt(AParams, 'hwnd')), LTarget, LRefusal) then
        Exit(LRefusal);
      Result := _WriteResult('process_kill', LTarget,
        TDesktopActions.KillProcess(LTarget.HWnd, LTarget.Pid));
    end;
  AServer.RegisterTool(LTool);
end;

class procedure TDesktopTools.RegisterTools(const AServer: TMCPServer);
begin
  _RegisterPing(AServer);
  _RegisterListWindows(AServer);
  _RegisterWindowTree(AServer);
  _RegisterElementFind(AServer);
  _RegisterWindowCapture(AServer);
  // PHASE 5 write pack (each gated by the pure guard before it acts).
  _RegisterWindowFocus(AServer);
  _RegisterWindowMove(AServer);
  _RegisterInvoke(AServer);
  _RegisterTypeText(AServer);
  // PHASE 6 destructive pack (each gated by the pure guard AND the KEY-4
  // human-confirmation consent window before it acts).
  _RegisterWindowClose(AServer);
  _RegisterProcessKill(AServer);
end;

end.
