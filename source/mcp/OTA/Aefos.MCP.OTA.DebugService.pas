unit Aefos.MCP.OTA.DebugService;

{
  OTA facade for the agent debug tools (future plan:
  .local-readonly\ota-agent-debug-plan.md, Phase 1+2).

  This is the ONLY OTA-bound part of the debug feature - the pure decisions
  (guards, state vocabulary, breakable-line snap) live in
  Aefos.MCP.OTA.DebugPolicy and are unit-tested headless. Everything here
  marshals to the IDE main thread via TThread.Synchronize (OTA is main-thread
  only, BR-7) exactly like Aefos.MCP.OTA.RunService, reads/acts on demand (no
  persistent debugger notifier - GetDebugState POLLS current state, the proven
  pattern; the ONLY notifier is the transient, non-refcounted eval notifier a
  deferred Evaluate registers and removes within one marshaled block), and
  re-resolves IOTADebuggerServices/CurrentProcess/CurrentThread inside each
  block (never caches a stale interface - a cached ref to a destroyed process
  is a dead-VMT read).

  Stepping wires the THREE paths the study de-risked (plan 6b): first the
  direct IOTAEditActions methods (proven-accessible in CnPack), then
  IOTAProcess.Run(step mode), then firing the IDE's own step action by name -
  so a live Phase-0 run just picks whichever advances execution.

  NOT verified at runtime yet - compiles against the installed ToolsAPI; the
  live behavior (does a programmatic step actually advance? evaluate at a
  breakpoint?) is exactly what the maintainer confirms next.
}

interface

uses
  Aefos.MCP.OTA.DebugPolicy;

type
  TDebugStepKind = (dskOver, dskInto, dskOut);

  // OTA facade for the agent debug tools, shaped like the 10 sibling
  // IMCPXxxService services (interface + class + factory). Single consumer:
  // Aefos.MCP.Tools.Debug. Bodies are byte-identical to the former free
  // functions — only the FORM (a named owner) changed.
  IMCPDebugService = interface
    ['{2F5A9C41-7B38-4D6E-9A02-6C1B8E5D3A70}']

    // Live debugger snapshot (marshaled). Fills the pure TDebugState the tools then
    // guard/format with DebugPolicy.
    function DebugReadState: TDebugState;

    // Create a source breakpoint (design-time capable: nil process). True on
    // success. The line is used as given - snap-to-breakable is the tool's job via
    // DebugPolicy.SnapBreakableLine once a process exposes GetSourceLines.
    // ACondition/APassCount are optional: non-empty/positive values are written
    // onto the created breakpoint IN PLACE (IOTABreakpoint40 Expression/PassCount
    // are writable - the GExperts edit-in-place precedent; no delete+recreate).
    // Empty condition + zero pass count = the unconditional breakpoint of old.
    function DebugSetBreakpoint(const AFileName: string; const ALine: Integer;
      const ACondition: string; const APassCount: Integer;
      out AReason: string): Boolean;

    // Create a TRACEPOINT: a log-and-continue breakpoint (IOTABreakpoint50
    // DoBreak=False + LogMessage) at unit:line - the message lands in the IDE
    // Event Log each pass WITHOUT stopping. AEvalExpr (optional) additionally
    // evaluates an expression on each pass and logs its result (EvalExpression +
    // LogResult=True). Design-time capable exactly like DebugSetBreakpoint -
    // agent-grade printf with no recompile.
    function DebugSetTracepoint(const AFileName: string; const ALine: Integer;
      const ALogMessage: string; const AEvalExpr: string;
      out AReason: string): Boolean;

    // Run to unit:line: plants a plain breakpoint there (DebugSetBreakpoint) and
    // dispatches Continue (DebugContinue). True when BOTH the breakpoint was
    // created and the run was dispatched; the caller polls DebugReadState. NOTE:
    // the ToolsAPI has NO one-shot/temporary breakpoint flag (verified across
    // IOTABreakpoint40/50/80/120), so the breakpoint PERSISTS after the stop -
    // the caller removes it with DebugRemoveBreakpoint when it was temporary.
    function DebugRunToLine(const AFileName: string; const ALine: Integer): Boolean;

    // Exception info at an exception stop: evaluates ExceptObject.ClassName and
    // Exception(ExceptObject).Message via DebugEvaluate (each marshals on its
    // own, like DebugInspectLocals) and returns them unquoted. True with
    // AClass/AMessage filled; when the message read fails on a valid exception
    // object, still True with AMessage='' and ANote='message-unavailable'. False
    // with ANote='not-an-exception-stop' when ExceptObject does not evaluate to
    // a live object (a plain breakpoint stop). NOT live-verified yet - the
    // psException evaluate behavior is exactly what the maintainer confirms next.
    function DebugGetExceptionInfo(out AClass, AMessage, ANote: string): Boolean;

    // Remove the first source breakpoint matching file+line. True if one was found.
    function DebugRemoveBreakpoint(const AFileName: string;
      const ALine: Integer): Boolean;

    // Enumerate source breakpoints via the pure FormatBreakpointLine:
    // 'file:line[ disabled][ if <expr>][ pass <n>][ log "<msg>"][ (tracepoint)]'.
    function DebugListBreakpoints: TArray<string>;

    // Dispatch a step (over/into/out) via the first available of the three paths.
    // Returns True if a step was dispatched (the actual advance is async - the
    // caller polls DebugReadState). False when no path applied (e.g. no session).
    function DebugStep(const AKind: TDebugStepKind): Boolean;

    // Continue the stopped process (Run) / pause a running one. True on dispatch.
    function DebugContinue: Boolean;
    function DebugPause: Boolean;

    // Evaluate an expression in the current thread's scope. Synchronous erOK
    // answers directly; erDeferred registers a (non-refcounted) IOTAThreadNotifier
    // and pumps ProcessDebugEvents until the deferred result lands - BOUNDED by a
    // ~3 s deadline + iteration cap + debuggee-alive checks (CnPack's unbounded
    // pump hangs the IDE; we never copy that). erBusy pumps once and retries the
    // whole Evaluate a few times. Returns True with the value in AResult; False
    // with the reason ('error: ...', 'busy', 'deferred-timeout', 'thread-gone',
    // 'no-thread').
    function DebugEvaluate(const AExpr: string; out AResult: string): Boolean;

    // Call stack of the CURRENT thread (SetCurrentThread first to target another).
    // Brackets StartCallStackAccess/EndCallStackAccess; csWait is pumped+retried
    // under the same bounded-deadline discipline as DebugEvaluate. Frames render
    // via the pure FormatCallFrame ('header  file:line'; header only when the
    // frame has no source). Capped at 200 frames. Empty when no stopped process.
    function DebugGetCallStack: TArray<string>;

    // One line per debugged-process thread via the pure FormatThreadLine:
    // 'thread <osid> <state>[ name=".."][ at file:line][ (current)]'.
    function DebugListThreads: TArray<string>;

    // Selects the thread with the given OS id as the process' current thread, so
    // subsequent DebugEvaluate / DebugGetCallStack / locals target it. True when
    // a thread with that id was found.
    function DebugSetCurrentThread(const AOSThreadId: Cardinal): Boolean;

    // The Locals-window emulation (the OTA has no locals API): reads the stopped
    // file's SOURCE, extracts the enclosing routine's names via the pure
    // DebugLocals parser, evaluates each, and returns 'name = value' lines
    // (unevaluable names are reported with their reason, not dropped - the agent
    // should see "LObj = error: ..." rather than silence).
    function DebugInspectLocals: TArray<string>;
  end;

// Factory — the single consumer (Tools.Debug) resolves the service once and
// then calls through the interface (mirrors NewMCPXxxService in the siblings).
function NewMCPDebugService: IMCPDebugService;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  Vcl.ActnList,
  ToolsAPI,
  Aefos.MCP.OTA.DebugLocals,
  Aefos.MCP.OTA.FacadeShared;  // FindUnitPath: unit-name -> full source path

type
  // The single debug service (form-only extraction — the 15 method bodies are
  // unchanged). Each call still marshals to the IDE main thread and re-resolves
  // IOTADebuggerServices/CurrentProcess/CurrentThread inside its own block.
  TMCPDebugService = class(TInterfacedObject, IMCPDebugService)
  public
    function DebugReadState: TDebugState;
    function DebugSetBreakpoint(const AFileName: string; const ALine: Integer;
      const ACondition: string; const APassCount: Integer;
      out AReason: string): Boolean;
    function DebugSetTracepoint(const AFileName: string; const ALine: Integer;
      const ALogMessage: string; const AEvalExpr: string;
      out AReason: string): Boolean;
    function DebugRunToLine(const AFileName: string; const ALine: Integer): Boolean;
    function DebugGetExceptionInfo(out AClass, AMessage, ANote: string): Boolean;
    function DebugRemoveBreakpoint(const AFileName: string;
      const ALine: Integer): Boolean;
    function DebugListBreakpoints: TArray<string>;
    function DebugStep(const AKind: TDebugStepKind): Boolean;
    function DebugContinue: Boolean;
    function DebugPause: Boolean;
    function DebugEvaluate(const AExpr: string; out AResult: string): Boolean;
    function DebugGetCallStack: TArray<string>;
    function DebugListThreads: TArray<string>;
    function DebugSetCurrentThread(const AOSThreadId: Cardinal): Boolean;
    function DebugInspectLocals: TArray<string>;
  end;

const
  // Hard bound for every debug-event pump (deferred evaluate, csWait call
  // stack): a deadline, an iteration cap, and debuggee-alive checks together.
  // CnPack's 'while not FCompleted do ProcessDebugEvents' is UNBOUNDED and
  // hangs the IDE when the completion never arrives - never copy that.
  CDebugPumpDeadlineMs = 3000;
  CDebugPumpMaxIterations = 300;
  CDebugEvalBusyRetries = 3;
  CDebugMaxStackFrames = 200;

type
  // Thread notifier for the bounded deferred Evaluate.
  //
  // CRITICAL AV GOTCHA (proven in CnPack CnWizDebuggerNotifier.pas): the
  // object handed to IOTAThread.AddNotifier MUST NOT be refcount-freed. The
  // debugger keeps/releases notifier references on its own schedule - it can
  // Release AFTER RemoveNotifier (and again while the thread dies), so a plain
  // TInterfacedObject gets destroyed under the IDE's feet and the next
  // Release reads a dead VMT. _AddRef/_Release therefore return a constant
  // and never free; DebugEvaluate frees the instance deterministically after
  // RemoveNotifier (CnPack's TCnSingletonInterfacedObject idiom).
  //
  // Both EvaluateComplete shapes are implemented: the IDE calls the
  // IOTAThreadNotifier160 (TOTAAddress) one on modern debuggers; the legacy
  // 32-bit (LongWord) one upcasts and forwards so either path completes us.
  // Destroyed ALSO completes: a thread dying mid-eval must break the pump
  // (CnPack leaves Destroyed empty - that is exactly its hang/AV bug).
  TDebugEvalNotifier = class(TObject, IInterface, IOTANotifier,
    IOTAThreadNotifier, IOTAThreadNotifier160)
  private
    FCompleted: Boolean;
    FThreadGone: Boolean;
    FReturnCode: Integer;
    FResultText: string;
  protected
    { IInterface - non-refcounted on purpose (see class comment). }
    function QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;
    function _AddRef: Integer; stdcall;
    function _Release: Integer; stdcall;
    { IOTANotifier }
    procedure AfterSave;
    procedure BeforeSave;
    procedure Destroyed;
    procedure Modified;
    { IOTAThreadNotifier }
    procedure ThreadNotify(Reason: TOTANotifyReason);
    procedure EvaluateComplete(const ExprStr, ResultStr: string;
      CanModify: Boolean; ResultAddress, ResultSize: LongWord;
      ReturnCode: Integer); overload;
    procedure ModifyComplete(const ExprStr, ResultStr: string;
      ReturnCode: Integer);
    { IOTAThreadNotifier160 }
    procedure EvaluateComplete(const ExprStr, ResultStr: string;
      CanModify: Boolean; ResultAddress: TOTAAddress; ResultSize: LongWord;
      ReturnCode: Integer); overload;
  public
    property Completed: Boolean read FCompleted;
    property ThreadGone: Boolean read FThreadGone;
    property ReturnCode: Integer read FReturnCode;
    property ResultText: string read FResultText;
  end;

function TDebugEvalNotifier.QueryInterface(const IID: TGUID;
  out Obj): HResult;
begin
  if GetInterface(IID, Obj) then
    Result := S_OK
  else
    Result := E_NOINTERFACE;
end;

function TDebugEvalNotifier._AddRef: Integer;
begin
  Result := -1; // non-refcounted singleton semantics - never auto-freed
end;

function TDebugEvalNotifier._Release: Integer;
begin
  Result := -1; // non-refcounted singleton semantics - never auto-freed
end;

procedure TDebugEvalNotifier.AfterSave;
begin
end;

procedure TDebugEvalNotifier.BeforeSave;
begin
end;

procedure TDebugEvalNotifier.Destroyed;
begin
  // The thread object is going away: complete the pump AND flag the thread
  // dead so the caller skips RemoveNotifier (the notifier list died with it).
  FThreadGone := True;
  FCompleted := True;
end;

procedure TDebugEvalNotifier.Modified;
begin
end;

procedure TDebugEvalNotifier.ThreadNotify(Reason: TOTANotifyReason);
begin
end;

procedure TDebugEvalNotifier.EvaluateComplete(const ExprStr,
  ResultStr: string; CanModify: Boolean; ResultAddress, ResultSize: LongWord;
  ReturnCode: Integer);
begin
  // Legacy 32-bit shape: upcast the address and forward (CnPack idiom).
  EvaluateComplete(ExprStr, ResultStr, CanModify, TOTAAddress(ResultAddress),
    ResultSize, ReturnCode);
end;

procedure TDebugEvalNotifier.ModifyComplete(const ExprStr, ResultStr: string;
  ReturnCode: Integer);
begin
end;

procedure TDebugEvalNotifier.EvaluateComplete(const ExprStr,
  ResultStr: string; CanModify: Boolean; ResultAddress: TOTAAddress;
  ResultSize: LongWord; ReturnCode: Integer);
begin
  FResultText := ResultStr;
  FReturnCode := ReturnCode;
  FCompleted := True;
end;

function _DebuggerServices(out ADS: IOTADebuggerServices): Boolean;
begin
  Result := Assigned(BorlandIDEServices) and
    Supports(BorlandIDEServices, IOTADebuggerServices, ADS);
end;

// Wrap-safe elapsed milliseconds since AStart (GetTickCount arithmetic).
function _TickElapsed(const AStart: Cardinal): Cardinal;
begin
  Result := Cardinal(GetTickCount) - AStart;
end;

// Re-checks the debuggee EVERY pump iteration (never trusts a cached ref):
// the process or its current thread can die while ProcessDebugEvents runs.
function _DebuggeeAlive(const ADS: IOTADebuggerServices): Boolean;
var
  LProc: IOTAProcess;
begin
  Result := False;
  if (ADS = nil) or (ADS.ProcessCount = 0) then
    Exit;
  LProc := ADS.CurrentProcess;
  Result := (LProc <> nil) and (LProc.CurrentThread <> nil);
end;

// Index-sentinel notifier removal (GExperts GX_OtaUtils:5159-5170): copy the
// index, invalidate the caller's variable FIRST, then RemoveNotifier - so no
// re-entry/late path can remove twice. Skips a thread whose Destroyed already
// fired (AThreadGone: its notifier list died with it), and never raises.
procedure _RemoveThreadNotifierSafe(const AThread: IOTAThread;
  var AIndex: Integer; const AThreadGone: Boolean);
var
  LIdx: Integer;
begin
  LIdx := AIndex;
  AIndex := -1;
  if (LIdx < 0) or AThreadGone or (AThread = nil) then
    Exit;
  try
    AThread.RemoveNotifier(LIdx);
  except
    // teardown must never raise
  end;
end;

// Pure-string rendering of the OTA thread state (kept here - DebugPolicy is
// ToolsAPI-free).
function _ThreadStateStr(const AState: TOTAThreadState): string;
begin
  case AState of
    tsStopped:  Result := 'stopped';
    tsRunnable: Result := 'runnable';
    tsBlocked:  Result := 'blocked';
    tsNone:     Result := 'none';
  else
    Result := 'other';
  end;
end;

// Resolve an IDE action by the first matching name (mirrors RunService's
// _TerminalResolveIDEAction) so the step-action fallback reuses the proven path.
function _ResolveIDEAction(const AAlternates: array of string): TBasicAction;
var
  LNTA: INTAServices;
  LList: TCustomActionList;
  LFor, LIdx: Integer;
begin
  Result := nil;
  try
    if not Assigned(BorlandIDEServices) then
      Exit;
    if not Supports(BorlandIDEServices, INTAServices, LNTA) then
      Exit;
    LList := LNTA.ActionList;
    if not Assigned(LList) then
      Exit;
    for LFor := Low(AAlternates) to High(AAlternates) do
      for LIdx := 0 to LList.ActionCount - 1 do
        if SameText(LList.Actions[LIdx].Name, AAlternates[LFor]) then
          Exit(LList.Actions[LIdx]);
  except
    Result := nil;
  end;
end;

function _TopEditActions(out AEA: IOTAEditActions): Boolean;
var
  LES: IOTAEditorServices;
  LView: IOTAEditView;
begin
  Result := False;
  AEA := nil;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LES) then
    Exit;
  LView := LES.TopView;
  if LView = nil then
    Exit;
  Result := Supports(LView, IOTAEditActions, AEA);
end;

function TMCPDebugService.DebugReadState: TDebugState;
var
  LState: TDebugState;
begin
  LState := Default(TDebugState);
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LProc: IOTAProcess;
      LThread: IOTAThread;
    begin
      if not _DebuggerServices(LDS) then
        Exit;
      LState.HasSession := LDS.ProcessCount > 0;
      if not LState.HasSession then
        Exit;
      LProc := LDS.CurrentProcess;
      if LProc = nil then
        Exit;
      // "Stopped" = the user can inspect: a breakpoint stop, a fault, or an
      // exception. psRunning/psStopping mean still executing.
      LState.Stopped := LProc.ProcessState in [psStopped, psFault, psException];
      if not LState.Stopped then
        Exit;
      LThread := LProc.CurrentThread;
      if LThread = nil then
        Exit;
      LState.StopFile := LThread.GetCurrentFile;
      LState.StopLine := LThread.GetCurrentLine;
      LState.ThreadId := LThread.GetOSThreadID;
    end);
  Result := LState;
end;

// Bring APath forward in the Code editor and scroll to ALine, so the breakpoint
// dot appearing/disappearing is VISIBLE - the same "the view matches the action"
// fluidity the design/code tools give (RULE #1). Main-thread only (call inside a
// Synchronize block). Purely visual: any failure is swallowed so it can never
// break the breakpoint operation itself.
procedure _RevealSourceLine(const APath: string; const ALine: Integer);
var
  LMS: IOTAModuleServices;
  LModule: IOTAModule;
  LSource: IOTASourceEditor;
  LFor: Integer;
  LES: IOTAEditorServices;
  LView: IOTAEditView;
  LPos: TOTAEditPos;
begin
  try
    if (APath = '') or (ALine <= 0) or not Assigned(BorlandIDEServices) then
      Exit;
    if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
      Exit;
    LModule := LMS.FindModule(APath);
    if LModule = nil then
      LModule := LMS.OpenModule(APath);
    if LModule = nil then
      Exit;
    // Find the module's SOURCE editor and Show it: this FLIPS from the Form
    // Designer to the Code view (the F12), so the breakpoint dot is actually on
    // screen. OpenFile + set-caret alone leaves the designer in front, so the
    // gutter change stays hidden behind it (the maintainer saw exactly this).
    LSource := nil;
    for LFor := 0 to LModule.GetModuleFileCount - 1 do
      if Supports(LModule.GetModuleFileEditor(LFor), IOTASourceEditor, LSource) then
        Break;
    if LSource = nil then
      Exit;
    LSource.Show;
    if not Supports(BorlandIDEServices, IOTAEditorServices, LES) then
      Exit;
    LView := LES.TopView;
    if not Assigned(LView) then
      Exit;
    LPos.Col := 1;
    LPos.Line := ALine;
    LView.CursorPos := LPos;
    LView.MoveViewToCursor;
    LView.Paint;
  except
    // Visual nicety only - never break the breakpoint operation.
  end;
end;

function TMCPDebugService.DebugSetBreakpoint(const AFileName: string; const ALine: Integer;
  const ACondition: string; const APassCount: Integer;
  out AReason: string): Boolean;
var
  LOk: Boolean;
  LReason: string;
begin
  LOk := False;
  LReason := '';
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LBkpt: IOTABreakpoint;
      LPath: string;
    begin
      if not _DebuggerServices(LDS) then
      begin
        LReason := 'debugger-services-unavailable';
        Exit;
      end;
      // BUG-2 FIX: NewSourceBreakpoint binds against the FULL SOURCE PATH. A
      // bare unit name ("MainForm") registers a breakpoint that NEVER binds at
      // runtime, so the process runs straight past it. Resolve the name to the
      // module's path first (open module, then project scan).
      LPath := TFacadeShared.FindUnitPath(AFileName);
      if LPath = '' then
      begin
        LReason := 'unit-not-found: cannot resolve ' + AFileName +
          ' to a source file in the active project';
        Exit;
      end;
      // nil process = a design-time breakpoint (armed before/independent of a
      // running process), which is exactly what an agent setting BPs wants.
      LBkpt := LDS.NewSourceBreakpoint(LPath, ALine, nil);
      if LBkpt = nil then
      begin
        LReason := 'breakpoint-rejected: the debugger refused a breakpoint at '
          + ExtractFileName(LPath) + ':' + IntToStr(ALine);
        Exit;
      end;
      // Edit-in-place on the returned breakpoint: Expression/PassCount are
      // writable IOTABreakpoint40 (base-vintage) properties, present on every
      // supported ToolsAPI.
      if ACondition <> '' then
        LBkpt.Expression := ACondition;
      if APassCount > 0 then
        LBkpt.PassCount := APassCount;
      LOk := True;
      // Show it: open the unit in Code and scroll to the line so the dot lands
      // on screen (the "view matches the action" fluidity, like RULE #1).
      _RevealSourceLine(LPath, ALine);
    end);
  AReason := LReason;
  Result := LOk;
end;

function TMCPDebugService.DebugSetTracepoint(const AFileName: string; const ALine: Integer;
  const ALogMessage: string; const AEvalExpr: string;
  out AReason: string): Boolean;
var
  LOk: Boolean;
  LReason: string;
begin
  LOk := False;
  LReason := '';
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LBkpt: IOTABreakpoint;
      LPath: string;
    begin
      if not _DebuggerServices(LDS) then
      begin
        LReason := 'debugger-services-unavailable';
        Exit;
      end;
      // BUG-2 FIX (same as SetBreakpoint): bind against the full source path.
      LPath := TFacadeShared.FindUnitPath(AFileName);
      if LPath = '' then
      begin
        LReason := 'unit-not-found: cannot resolve ' + AFileName +
          ' to a source file in the active project';
        Exit;
      end;
      LBkpt := LDS.NewSourceBreakpoint(LPath, ALine, nil);
      if LBkpt = nil then
      begin
        LReason := 'breakpoint-rejected: the debugger refused a breakpoint at '
          + ExtractFileName(LPath) + ':' + IntToStr(ALine);
        Exit;
      end;
      // BUG-1 FIX (proven live on D13): assign the log-and-continue members
      // (DoBreak/LogMessage/EvalExpression/LogResult) DIRECTLY on LBkpt. They
      // are inherited into IOTABreakpoint through the chain (IOTABreakpoint <-
      // IOTABreakpoint120 <- 80 <- 50), so they are ALWAYS present. The old
      // Supports(LBkpt, IOTABreakpoint50) cast FAILED at runtime because the
      // debugger's breakpoint object does not register that intermediate IID -
      // which made SetTracepoint 100% inoperant (always applied:false).
      LBkpt.DoBreak := False;
      LBkpt.LogMessage := ALogMessage;
      if AEvalExpr <> '' then
      begin
        LBkpt.EvalExpression := AEvalExpr;
        LBkpt.LogResult := True;
      end;
      LOk := True;
      _RevealSourceLine(LPath, ALine);
    end);
  AReason := LReason;
  Result := LOk;
end;

function TMCPDebugService.DebugRunToLine(const AFileName: string; const ALine: Integer): Boolean;
var
  LReason: string;
begin
  // Two marshaled steps on purpose (the DebugInspectLocals precedent): plant
  // the breakpoint, then dispatch Continue. No one-shot flag exists in the
  // ToolsAPI, so the breakpoint persists - the tool's description tells the
  // agent to RemoveBreakpoint afterwards when it was temporary.
  Result := DebugSetBreakpoint(AFileName, ALine, '', 0, LReason);
  if Result then
    Result := DebugContinue;
end;

function TMCPDebugService.DebugGetExceptionInfo(out AClass, AMessage, ANote: string): Boolean;
var
  LValue: string;
begin
  Result := False;
  AClass := '';
  AMessage := '';
  ANote := '';
  // ExceptObject evaluates to the live exception instance only while the
  // debuggee is inside exception handling; anywhere else the evaluate errors
  // (or yields nil) - which is exactly the 'not an exception stop' signal.
  if not DebugEvaluate('ExceptObject.ClassName', LValue) then
  begin
    ANote := 'not-an-exception-stop';
    Exit;
  end;
  AClass := TDebugPolicy.UnquoteEvalString(LValue);
  if (AClass = '') or SameText(AClass, 'nil') then
  begin
    AClass := '';
    ANote := 'not-an-exception-stop';
    Exit;
  end;
  Result := True;
  if DebugEvaluate('Exception(ExceptObject).Message', LValue) then
    AMessage := TDebugPolicy.UnquoteEvalString(LValue)
  else
    // A valid exception class whose Message will not read (e.g. a non-
    // Exception object raised): report the class, flag the message.
    ANote := 'message-unavailable';
end;

function TMCPDebugService.DebugRemoveBreakpoint(const AFileName: string;
  const ALine: Integer): Boolean;
var
  LOk: Boolean;
begin
  LOk := False;
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LBkpt: IOTASourceBreakpoint;
      LWanted: TBreakpointFileMatch;
      LPass, I: Integer;
      LTarget, LReveal: string;
    begin
      if not _DebuggerServices(LDS) then
        Exit;
      // Accept a bare unit name ("MainForm") symmetrically with SetBreakpoint:
      // resolve it to the full source path so the FULL-PATH match fires. Without
      // this, RemoveBreakpoint("MainForm",64) never matched a stored
      // "MainForm.pas" breakpoint. Fall back to the raw name (the basename pass
      // still catches an explicit "MainForm.pas").
      LTarget := TFacadeShared.FindUnitPath(AFileName);
      if LTarget = '' then
        LTarget := AFileName;
      // Breakpoint identity (GExperts rule via the pure MatchBreakpointFile):
      // pass 1 removes only a FULL-PATH match (SameFileName); pass 2 falls
      // back to basename+line - never the primary key, it collides across
      // directories (two Unit1.pas in different projects).
      for LPass := 0 to 1 do
      begin
        if LPass = 0 then
          LWanted := bfmFullPath
        else
          LWanted := bfmBaseName;
        for I := 0 to LDS.GetSourceBkptCount - 1 do
        begin
          LBkpt := LDS.GetSourceBkpt(I);
          if (LBkpt <> nil) and (LBkpt.LineNumber = ALine) and
            (TDebugPolicy.MatchBreakpointFile(LBkpt.FileName, LTarget) = LWanted) then
          begin
            LReveal := LBkpt.FileName;
            LDS.RemoveBreakpoint(LBkpt);
            LOk := True;
            // Show it disappear: bring the unit forward at the line.
            _RevealSourceLine(LReveal, ALine);
            Exit;
          end;
        end;
      end;
    end);
  Result := LOk;
end;

function TMCPDebugService.DebugListBreakpoints: TArray<string>;
var
  LList: TArray<string>;
begin
  LList := nil;
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LBkpt: IOTASourceBreakpoint;
      I: Integer;
    begin
      if not _DebuggerServices(LDS) then
        Exit;
      for I := 0 to LDS.GetSourceBkptCount - 1 do
      begin
        LBkpt := LDS.GetSourceBkpt(I);
        if LBkpt = nil then
          Continue;
        // Pure rendering (FormatBreakpointLine): condition, pass count, and
        // the log-message/(tracepoint) markers all show, so an agent can tell
        // its tracepoints from its stops in one listing.
        LList := LList + [TDebugPolicy.FormatBreakpointLine(
          ExtractFileName(LBkpt.FileName), LBkpt.LineNumber, LBkpt.Enabled,
          LBkpt.Expression, LBkpt.PassCount, LBkpt.DoBreak,
          LBkpt.LogMessage)];
      end;
    end);
  Result := LList;
end;

function TMCPDebugService.DebugStep(const AKind: TDebugStepKind): Boolean;
var
  LOk: Boolean;
begin
  LOk := False;
  TThread.Synchronize(nil,
    procedure
    var
      LEA: IOTAEditActions;
      LDS: IOTADebuggerServices;
      LProc: IOTAProcess;
      LAction: TBasicAction;
    begin
      // Path 1 - direct IOTAEditActions (over/into only; access CnPack-proven).
      if (AKind in [dskOver, dskInto]) and _TopEditActions(LEA) then
      begin
        if AKind = dskOver then
          LEA.StepOver
        else
          LEA.TraceInto;
        LOk := True;
        Exit;
      end;
      // Path 2 - IOTAProcess.Run(step mode).
      if _DebuggerServices(LDS) and (LDS.ProcessCount > 0) then
      begin
        LProc := LDS.CurrentProcess;
        if LProc <> nil then
        begin
          case AKind of
            dskOver: LProc.Run(ormStmtStepOver);
            dskInto: LProc.Run(ormStmtStepInto);
            dskOut:  LProc.Run(ormRunUntilReturn);
          end;
          LOk := True;
          Exit;
        end;
      end;
      // Path 3 - fire the IDE's own step action by name (confirmed from CnPack).
      case AKind of
        dskOver: LAction := _ResolveIDEAction(['RunStepOverCommand']);
        dskInto: LAction := _ResolveIDEAction(['RunTraceIntoCommand']);
        dskOut:  LAction := _ResolveIDEAction(['RunUntilReturnCommand',
                   'RunRunUntilReturnCommand']);
      else
        LAction := nil;
      end;
      if Assigned(LAction) then
      begin
        LAction.Execute;
        LOk := True;
      end;
    end);
  Result := LOk;
end;

function TMCPDebugService.DebugContinue: Boolean;
var
  LOk: Boolean;
begin
  LOk := False;
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LProc: IOTAProcess;
      LAction: TBasicAction;
    begin
      if _DebuggerServices(LDS) and (LDS.ProcessCount > 0) then
      begin
        LProc := LDS.CurrentProcess;
        if LProc <> nil then
        begin
          LProc.Run(ormRun);
          LOk := True;
          Exit;
        end;
      end;
      LAction := _ResolveIDEAction(['RunRunCommand', 'DebuggerRunCommand']);
      if Assigned(LAction) then
      begin
        LAction.Execute;
        LOk := True;
      end;
    end);
  Result := LOk;
end;

function TMCPDebugService.DebugPause: Boolean;
var
  LOk: Boolean;
begin
  LOk := False;
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LProc: IOTAProcess;
    begin
      if not _DebuggerServices(LDS) or (LDS.ProcessCount = 0) then
        Exit;
      LProc := LDS.CurrentProcess;
      if LProc = nil then
        Exit;
      LProc.Pause;
      LOk := True;
    end);
  Result := LOk;
end;

function TMCPDebugService.DebugEvaluate(const AExpr: string; out AResult: string): Boolean;
var
  LOk: Boolean;
  LOut: string;
begin
  LOk := False;
  LOut := 'no-thread';
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LProc: IOTAProcess;
      LThread: IOTAThread;
      LBuf: array[0..2047] of Char;
      LCanModify: Boolean;
      LAddr: TOTAAddress;
      LSize, LVal: LongWord;
      LEval: TOTAEvaluateResult;
      LNotifier: TDebugEvalNotifier;
      LIndex, LPumps, LRetry: Integer;
      LStartTick: Cardinal;
    begin
      if not _DebuggerServices(LDS) or (LDS.ProcessCount = 0) then
        Exit;
      LProc := LDS.CurrentProcess;
      if LProc = nil then
        Exit;
      LThread := LProc.CurrentThread;
      if LThread = nil then
        Exit;
      LStartTick := GetTickCount;
      // erBusy = the evaluator is mid-operation: pump one round of debug
      // events and retry the WHOLE Evaluate, a bounded number of times.
      LRetry := 0;
      repeat
        FillChar(LBuf, SizeOf(LBuf), 0);
        LEval := LThread.Evaluate(AExpr, @LBuf[0], Length(LBuf), LCanModify,
          True, nil, LAddr, LSize, LVal);
        if LEval <> erBusy then
          Break;
        LDS.ProcessDebugEvents;
        Inc(LRetry);
      until (LRetry > CDebugEvalBusyRetries) or
        (_TickElapsed(LStartTick) >= CDebugPumpDeadlineMs) or
        (not _DebuggeeAlive(LDS));
      case LEval of
        erOK:
          begin
            LOut := TDebugPolicy.NormalizeEvalResult(string(LBuf));
            LOk := True;
          end;
        erBusy:
          LOut := 'busy';
        erDeferred:
          begin
            // The evaluator called into the debuggee (side effects) and will
            // answer via EvaluateComplete. Register the NON-refcounted
            // notifier and pump - BOUNDED (deadline + cap + alive checks).
            LNotifier := TDebugEvalNotifier.Create;
            try
              LIndex := LThread.AddNotifier(LNotifier);
              try
                LPumps := 0;
                while (LIndex >= 0) and (not LNotifier.Completed) and
                  (LPumps < CDebugPumpMaxIterations) and
                  (_TickElapsed(LStartTick) < CDebugPumpDeadlineMs) and
                  _DebuggeeAlive(LDS) do
                begin
                  LDS.ProcessDebugEvents;
                  Inc(LPumps);
                  if not LNotifier.Completed then
                    Sleep(10);
                end;
              finally
                // Remove on EVERY exit path, index-sentinel style.
                _RemoveThreadNotifierSafe(LThread, LIndex,
                  LNotifier.ThreadGone);
              end;
              if LNotifier.ThreadGone then
                LOut := 'thread-gone'
              else if LNotifier.Completed and (LNotifier.ReturnCode = 0) then
              begin
                // Prefer the notifier's result string; fall back to whatever
                // the evaluator left in the buffer.
                if LNotifier.ResultText <> '' then
                  LOut := TDebugPolicy.NormalizeEvalResult(LNotifier.ResultText)
                else
                  LOut := TDebugPolicy.NormalizeEvalResult(string(LBuf));
                LOk := True;
              end
              else if LNotifier.Completed then
                LOut := 'error: ' + TDebugPolicy.NormalizeEvalResult(LNotifier.ResultText)
              else
                LOut := 'deferred-timeout';
            finally
              // Deterministic free - _Release never frees this object.
              LNotifier.Free;
            end;
          end;
      else
        // erError: the buffer may hold the evaluator's error text.
        LOut := 'error: ' + TDebugPolicy.NormalizeEvalResult(string(LBuf));
      end;
    end);
  AResult := LOut;
  Result := LOk;
end;

function TMCPDebugService.DebugGetCallStack: TArray<string>;
var
  LList: TArray<string>;
begin
  LList := nil;
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LProc: IOTAProcess;
      LThread: IOTAThread;
      LAccess: TOTACallStackState;
      LStartTick: Cardinal;
      LPumps, LCount, LLine, I: Integer;
      LFile: string;
    begin
      if not _DebuggerServices(LDS) or (LDS.ProcessCount = 0) then
        Exit;
      LProc := LDS.CurrentProcess;
      if LProc = nil then
        Exit;
      LThread := LProc.CurrentThread;
      if LThread = nil then
        Exit;
      // csWait = try again after letting the debugger spin: pair EVERY Start
      // with an End, pump, retry - bounded exactly like the deferred eval.
      LStartTick := GetTickCount;
      LPumps := 0;
      repeat
        LAccess := LThread.StartCallStackAccess;
        if LAccess <> csWait then
          Break;
        LThread.EndCallStackAccess;
        LDS.ProcessDebugEvents;
        Sleep(10);
        Inc(LPumps);
      until (LPumps >= CDebugPumpMaxIterations) or
        (_TickElapsed(LStartTick) >= CDebugPumpDeadlineMs) or
        (not _DebuggeeAlive(LDS));
      if LAccess <> csAccessible then
      begin
        // csInaccessible got a Start - close its bracket; a bounded-out
        // csWait already closed it inside the loop.
        if LAccess = csInaccessible then
          LThread.EndCallStackAccess;
        Exit;
      end;
      try
        // GetCallCount MUST precede GetCallHeader/GetCallPos, and the frame
        // indices are ONE-based (ToolsAPI contract).
        LCount := LThread.GetCallCount;
        if LCount > CDebugMaxStackFrames then
          LCount := CDebugMaxStackFrames;
        for I := 1 to LCount do
        begin
          LFile := '';
          LLine := 0;
          LThread.GetCallPos(I, LFile, LLine);
          // Empty FileName = no source for the frame: header only.
          LList := LList + [TDebugPolicy.FormatCallFrame(LThread.GetCallHeader(I),
            LFile, LLine)];
        end;
      finally
        LThread.EndCallStackAccess;
      end;
    end);
  Result := LList;
end;

function TMCPDebugService.DebugListThreads: TArray<string>;
var
  LList: TArray<string>;
begin
  LList := nil;
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LProc: IOTAProcess;
      LThread, LCurrent: IOTAThread;
      LFile, LName: string;
      LLine, I: Integer;
      LIsCurrent: Boolean;
    begin
      if not _DebuggerServices(LDS) or (LDS.ProcessCount = 0) then
        Exit;
      LProc := LDS.CurrentProcess;
      if LProc = nil then
        Exit;
      LCurrent := LProc.CurrentThread;
      for I := 0 to LProc.GetThreadCount - 1 do
      begin
        LThread := LProc.GetThread(I);
        if LThread = nil then
          Continue;
        try
          LFile := LThread.GetCurrentFile;
          if LFile <> '' then
            LLine := Integer(LThread.GetCurrentLine)
          else
            LLine := 0;
          LName := LThread.GetThreadName;
          LIsCurrent := (LCurrent <> nil) and
            (LThread.GetOSThreadID = LCurrent.GetOSThreadID);
          LList := LList + [TDebugPolicy.FormatThreadLine(LThread.GetOSThreadID, LName,
            _ThreadStateStr(LThread.GetState), LFile, LLine, LIsCurrent)];
        except
          // Skip a thread the debugger cannot describe (dying/detached) -
          // an enumeration must never take the whole tool down.
        end;
      end;
    end);
  Result := LList;
end;

function TMCPDebugService.DebugSetCurrentThread(const AOSThreadId: Cardinal): Boolean;
var
  LOk: Boolean;
begin
  LOk := False;
  TThread.Synchronize(nil,
    procedure
    var
      LDS: IOTADebuggerServices;
      LProc: IOTAProcess;
      LThread: IOTAThread;
      I: Integer;
    begin
      if not _DebuggerServices(LDS) or (LDS.ProcessCount = 0) then
        Exit;
      LProc := LDS.CurrentProcess;
      if LProc = nil then
        Exit;
      for I := 0 to LProc.GetThreadCount - 1 do
      begin
        LThread := LProc.GetThread(I);
        if (LThread <> nil) and (LThread.GetOSThreadID = AOSThreadId) then
        begin
          LProc.SetCurrentThread(LThread);
          LOk := True;
          Exit;
        end;
      end;
    end);
  Result := LOk;
end;

function TMCPDebugService.DebugInspectLocals: TArray<string>;
var
  LState: TDebugState;
  LLocals: TArray<TDebugLocal>;
  LOut: TArray<string>;
  LValue: string;
  I: Integer;
begin
  Result := nil;
  // State + source read first (state call marshals internally); the pure
  // extraction needs no IDE at all.
  LState := DebugReadState;
  if (not LState.Stopped) or (LState.StopFile = '') then
    Exit;
  if not TFile.Exists(LState.StopFile) then
    Exit;
  LLocals := ExtractLocalsAtLine(
    TFile.ReadAllText(LState.StopFile), LState.StopLine);
  LOut := nil;
  for I := 0 to High(LLocals) do
  begin
    // Each Evaluate marshals on its own - acceptable at locals scale (tens),
    // and it keeps this function callable from any thread.
    if DebugEvaluate(LLocals[I].Name, LValue) then
      LOut := LOut + [LLocals[I].Name + ' = ' + LValue]
    else
      LOut := LOut + [LLocals[I].Name + ' = <' + LValue + '>'];
  end;
  Result := LOut;
end;

function NewMCPDebugService: IMCPDebugService;
begin
  Result := TMCPDebugService.Create;
end;

end.
