unit Aefos.Lazarus.DebugService;

{ Aefos AI - Lazarus edition: MCP debug service backend (debug foundation slice).

  This is the Lazarus twin of the Delphi OTA debug facade
  (source\mcp\OTA\Aefos.MCP.OTA.DebugService.pas). On RAD Studio the debugger is
  driven through IOTADebuggerServices / IOTAProcess / IOTAThread; here it is the
  Lazarus IDE's global DebugBoss (C:\lazarus\ide\packages\idedebugger\
  basedebugmanager.pas:260, a TBaseDebugManager). It is kept in its OWN unit -
  exactly as the Delphi edition keeps IMCPDebugService separate from
  IMCPWorkspaceFacade - so this slice does not touch the heavily-shared
  WorkspaceFacade, and the IdeDebugger package dependency is confined here.

  FIRST SLICE scope (foundation of the debug loop):
    - DebugReadState       -> the live debugger state the agent POLLS after a run
                              / step: has a session? stopped? current file:line +
                              thread. Mirrors DebugService.DebugReadState.
    - DebugSetBreakpoint    -> arm a source breakpoint at file:line (design-time
                              too, before a run). Mirrors DebugSetBreakpoint.
    - DebugRemoveBreakpoint -> remove the breakpoint at file:line. Mirrors
                              DebugRemoveBreakpoint.
    - DebugListBreakpoints  -> render the current breakpoints. Mirrors
                              DebugListBreakpoints.
  Stepping / inspect / evaluate / call-stack are LATER slices - deliberately not
  here.

  TDebugState mirror: the Delphi TDebugState is a pure record that lives in the
  Delphi-only OTA unit Aefos.MCP.OTA.DebugPolicy (source\mcp\OTA), which is not on
  the Lazarus package path and is not FPC-clean as written. Rather than ALTER that
  Delphi GA unit (Delphi must stay intact for this Lazarus-only slice), the record
  is MIRRORED here field-for-field as TAefosLazDebugState and the two pure
  formatters (FormatDebugState / FormatBreakpointLine) are copied VERBATIM from
  Aefos.MCP.OTA.DebugPolicy.pas:180 / :308, so the agent-facing strings are
  byte-identical across editions. (A future refactor could promote the pure record
  + formatters into a shared source\mcp\Core unit for true single-source.)

  DebugBoss mapping (proven against C:\lazarus source):
    - HasSession: LazarusIDE.ToolStatus = itDebugger - the same signal the facade
      RunProject confirms a launch on. It is TRUE from launch until the debuggee
      ends (the Lazarus analogue of Delphi ProcessCount > 0).
    - Stopped: DebugBoss.State in [dsPause, dsInternalPause] (TDBGState,
      lazdebuggerintfbasetypes.pas:56) - the debuggee is paused and inspectable,
      the analogue of Delphi ProcessState in [psStopped, psFault, psException].
    - Current location: the current thread's top frame carries Source + Line
      (dbgintfdebuggerbase.pp: TThreadEntry.TopFrame:1263 -> TCallStackEntry.
      Source:880 / .Line:879). The threads/callstack are populated ASYNC by the
      debugger on pause, so this is BEST-EFFORT: when the frame is not yet loaded
      StopFile stays '' and the state renders 'stopped (no source; thread N)'.
    - Breakpoints: DebugBoss.DoCreateBreakPoint (basedebugmanager.pas:197) /
      DoDeleteBreakPoint (:205) / BreakPoints: TIDEBreakPoints (:235). Each
      TIDEBreakPoint carries Source/Line/Enabled/Expression/BreakHitCount
      (dbgintfdebuggerbase.pp:328-346).

  Threading: every method here touches DebugBoss / the IDE and MUST run on the IDE
  main thread. This unit does NOT marshal - the CALLER (the MCP registrar) marshals
  through the tool context, exactly like the facade members.

  Mode delphiunicode, matching the facade + the MCP core, so `string` = UnicodeString.
  The DebugBoss / IDEIntf boundary is UTF-8 AnsiString, so every path/expression
  crossing in/out is converted explicitly through LazUTF8 (_FromLcl / _ToLcl), the
  same discipline the WorkspaceFacade uses. All literals are ASCII, so no BOM. }

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

interface

type
  { Which step a DebugStep dispatches. Mirror of the Delphi TDebugStepKind
    (Aefos.MCP.OTA.DebugService.pas:35) - same value names so the mapping is
    obvious: dskOver -> DoStepOverProject (F8), dskInto -> DoStepIntoProject (F7),
    dskOut -> DoStepOutProject (Shift+F8). }
  TAefosLazDebugStepKind = (dskOver, dskInto, dskOut);

  { Snapshot of the live debugger, filled on the IDE main thread from DebugBoss.
    Field-for-field mirror of the Delphi TDebugState
    (Aefos.MCP.OTA.DebugPolicy.pas:41) so FormatDebugState renders identically. }
  TAefosLazDebugState = record
    HasSession: Boolean;  // a debug session exists (ToolStatus = itDebugger)
    Stopped: Boolean;     // the debuggee is paused (State in [dsPause, dsInternalPause])
    StopFile: string;     // current thread top-frame source file (when Stopped, best-effort)
    StopLine: Integer;    // current thread top-frame source line (when Stopped, best-effort)
    ThreadId: Cardinal;   // current OS thread id (when Stopped)
  end;

  { The debug service seam. Kept off the frozen IMCPWorkspaceFacade (like the
    Delphi IMCPDebugService); the registrar holds it directly. }
  IAefosLazDebugService = interface
    ['{6F2A9C34-1D7B-4E58-9A03-2C8E5B1F4D96}']
    function DebugReadState: TAefosLazDebugState;
    function DebugSetBreakpoint(const AFileName: string; const ALine: Integer;
      const ACondition: string; const APassCount: Integer;
      out AReason: string): Boolean;
    function DebugRemoveBreakpoint(const AFileName: string;
      const ALine: Integer): Boolean;
    function DebugListBreakpoints: TArray<string>;
    { Dispatch a step (over/into/out) on the PAUSED debuggee. True when a step was
      dispatched; the actual advance is ASYNC, so the caller re-polls DebugReadState
      to see the new location (mirrors the Delphi DebugStep async contract). False
      when there is no paused session (guarded here so a direct call can never
      accidentally START the project - DoStep*Project would launch it from scratch). }
    function DebugStep(const AKind: TAefosLazDebugStepKind): Boolean;
    { Continue a paused debuggee (F9 / DoRunProject resumes it). True on dispatch;
      the run is async, so the caller re-polls DebugReadState. }
    function DebugContinue: Boolean;
    { Pause a running debuggee so it can be inspected (DoPauseProject). True on
      dispatch; the pause lands async. }
    function DebugPause: Boolean;
    { Run to unit:line: plants a plain breakpoint there (DebugSetBreakpoint) and
      dispatches DebugContinue. True when BOTH the breakpoint was created and the
      run was dispatched; the caller polls DebugReadState for the stop. Lazarus has
      no one-shot breakpoint, so the breakpoint PERSISTS - the caller removes it
      with DebugRemoveBreakpoint when it was temporary (mirrors the Delphi
      DebugRunToLine, Aefos.MCP.OTA.DebugService.pas:610). }
    function DebugRunToLine(const AFileName: string; const ALine: Integer): Boolean;
    { Inspect the enclosing routine's parameters + locals at the current stop (the
      IDE Locals window), returning "name = value" lines - byte-for-byte the output
      shape of the Delphi DebugInspectLocals (Aefos.MCP.OTA.DebugService.pas:1105).
      The values come from the NATIVE FpDebug locals supplier (DebugBoss.Locals),
      NOT the Delphi source-parse-then-evaluate path: the OTA has no locals API so
      the RAD edition had to reconstruct the names from source; Lazarus exposes a
      real locals list, so this is the honest upgrade at an identical contract. []
      when not STOPPED. The supplier fills ASYNC, so this triggers the request then
      pumps the IDE main-thread queue (bounded) until the data is valid. }
    function DebugInspectLocals: TArray<string>;
    { Evaluate an arbitrary expression in the current stopped frame's scope (the IDE
      Evaluate/Watch window). True + AResult=value on success; False + AResult=an
      error/reason string otherwise (mirrors the Delphi DebugEvaluate contract,
      Aefos.MCP.OTA.DebugService.pas:850). DebugBoss.Evaluate is async (answers via a
      callback on the IDE main thread), so this dispatches then pumps the main-thread
      queue (bounded deadline + iteration cap) until the callback fires, presenting a
      synchronous result exactly like the RAD erDeferred pump. }
    function DebugEvaluate(const AExpr: string; out AResult: string): Boolean;
    { The current thread's call stack, top frame first, rendered as "header  file:line"
      strings (header only when a frame has no source) - byte-for-byte the output shape
      of the Delphi DebugGetCallStack (Aefos.MCP.OTA.DebugService.pas:958). [] when not
      STOPPED. The stack fills ASYNC (DebugBoss.CallStack), so this triggers the count +
      frame range then pumps the main-thread queue (bounded) until they are valid. }
    function DebugGetCallStack: TArray<string>;
  end;

  { Lazarus IDEIntf/IdeDebugger backend for the MCP debug service. Refcounted
    (TInterfacedObject) so the registrar holds it as an interface. }
  TAefosLazDebugService = class(TInterfacedObject, IAefosLazDebugService)
  private
    { UTF-8 (LCL) <-> UTF-16 (MCP core) boundary conversion, mirroring the
      WorkspaceFacade _FromLcl / _ToLcl. }
    class function _FromLcl(const AValue: AnsiString): UnicodeString; static;
    class function _ToLcl(const AValue: UnicodeString): AnsiString; static;
    { Resolves a unit name / path to the FULL on-disk source path the debug info
      binds against (the same form the gutter click hands DoCreateBreakPoint): an
      open editor by basename first, then the active project's unit list for a
      closed unit. '' when it cannot be resolved (blank input, or a unit that is
      neither open nor part of the project) - the caller then refuses rather than
      arm a bare-name breakpoint the backend can never bind. }
    class function _ResolveSourcePath(const AName: string): string; static;
    { One bounded round of the IDE main-thread pump (ProcessMessages +
      CheckSynchronize + a short yield) used by the async inspection reads. }
    class procedure _PumpMainThread; static;
  public
    function DebugReadState: TAefosLazDebugState;
    function DebugSetBreakpoint(const AFileName: string; const ALine: Integer;
      const ACondition: string; const APassCount: Integer;
      out AReason: string): Boolean;
    function DebugRemoveBreakpoint(const AFileName: string;
      const ALine: Integer): Boolean;
    function DebugListBreakpoints: TArray<string>;
    function DebugStep(const AKind: TAefosLazDebugStepKind): Boolean;
    function DebugContinue: Boolean;
    function DebugPause: Boolean;
    function DebugRunToLine(const AFileName: string; const ALine: Integer): Boolean;
    function DebugInspectLocals: TArray<string>;
    function DebugEvaluate(const AExpr: string; out AResult: string): Boolean;
    function DebugGetCallStack: TArray<string>;
    { Pure renderers, copied VERBATIM from Aefos.MCP.OTA.DebugPolicy so the
      agent-facing strings are byte-identical across editions. }
    class function FormatDebugState(const AState: TAefosLazDebugState): string; static;
    class function FormatBreakpointLine(const AFileName: string; const ALine: Integer;
      const AEnabled: Boolean; const AExpression: string;
      const APassCount: Integer; const ADoBreak: Boolean;
      const ALogMessage: string): string; static;
    { Verbatim twin of TDebugPolicy.FormatCallFrame (Aefos.MCP.OTA.DebugPolicy.pas:276):
      "header  file:line", or the header alone when the frame has no source. }
    class function FormatCallFrame(const AHeader, AFileName: string;
      const ALine: Integer): string; static;
  end;

implementation

uses
  SysUtils,
  Classes,                      // CheckSynchronize (flush queued cross-thread results while pumping)
  Forms,                        // Application.ProcessMessages (bounded async pump for inspect/eval/stack)
  Controls,                     // TModalResult / mrOk (DoCreateBreakPoint result)
  LazUTF8,                      // UTF8ToUTF16 / UTF16ToUTF8 (the LCL boundary)
  LazFileUtils,                 // FilenameIsAbsolute / FileExistsUTF8 (full-path resolution)
  LazIDEIntf,                   // LazarusIDE / ToolStatus / itDebugger / ActiveProject
  ProjectIntf,                  // TLazProject / TLazProjectFile (resolve a closed project unit)
  SrcEditorIntf,                // SourceEditorManagerIntf / SourceEditors (source-path resolution)
  BaseDebugManager,             // DebugBoss: TBaseDebugManager (State/BreakPoints/Threads/Locals/CallStack/Evaluate)
  Debugger,                     // TIDEBreakPoints / TIdeThreadsMonitor / TCurrentLocals / TIdeCallStack(Entry)
  IdeDebuggerBase,              // TLocalsValue (Name/Value on a native locals entry)
  LazDebuggerIntfBaseTypes,     // TDBGState (dsPause / dsInternalPause)
  LazDebuggerIntf,              // TDebuggerDataState (ddsUnknown/ddsRequested/ddsEvaluating/ddsValid)
  DbgIntfDebuggerBase,          // TThreads / TThreadEntry / TCallStackEntry / TDBGType / TDBGEvaluateResultCallback
  Aefos.Lazarus.IdeSilence;     // TAefosIdeSilence (one-shot debugger stop-dialog silence)

const
  // Bounded async pump budget for the inspection reads (locals / evaluate / call
  // stack). The FpDebug backend answers Evaluate and fills the Locals + CallStack
  // monitors ASYNC on the IDE main thread, so each read triggers the request then
  // pumps the main-thread message queue until the data is valid or the budget runs
  // out - the Lazarus twin of the Delphi CDebugPumpDeadlineMs / CDebugPumpMaxIterations
  // / CDebugMaxStackFrames (Aefos.MCP.OTA.DebugService.pas:187).
  CLazDebugPumpDeadlineMs = 3000;
  CLazDebugPumpMaxIterations = 300;
  CLazDebugMaxStackFrames = 200;

type
  { Non-refcounted carrier for the async DebugBoss.Evaluate callback (the Lazarus
    twin of the Delphi TDebugEvalNotifier, DebugService.pas:200). FPC has no
    closures, so an of-object Callback method + a Done flag let DebugEvaluate pump
    the main-thread message queue until the backend answers. Created and freed by
    DebugEvaluate on the IDE main thread; never held past that call. }
  TAefosLazEvalCatcher = class
  public
    Done: Boolean;
    Success: Boolean;
    ResultText: AnsiString;   // UTF-8 (LCL) domain; the caller decodes via _FromLcl
    // Matches TDBGEvaluateResultCallback (dbgintfdebuggerbase.pp:1539). The
    // ResultText param is AnsiString (UTF-8, the LCL domain) EXPLICITLY - under
    // $mode delphiunicode a bare `String` is UnicodeString and would not match the
    // debugger's of-object procedure type.
    procedure Callback(Sender: TObject; ASuccess: Boolean; AResultText: AnsiString;
      AResultType: TDBGType);
  end;

procedure TAefosLazEvalCatcher.Callback(Sender: TObject; ASuccess: Boolean;
  AResultText: AnsiString; AResultType: TDBGType);
begin
  Success := ASuccess;
  ResultText := AResultText;
  Done := True;
end;

{ ---- boundary conversion -------------------------------------------------- }

class function TAefosLazDebugService._FromLcl(const AValue: AnsiString): UnicodeString;
begin
  // The IDE/DebugBoss string domain is UTF-8 AnsiString; decode to UTF-16.
  Result := UTF8ToUTF16(AValue);
end;

class function TAefosLazDebugService._ToLcl(const AValue: UnicodeString): AnsiString;
begin
  // UTF16ToUTF8 returns a CP_ACP AnsiString holding UTF-8 bytes (LazUTF8), the
  // form DebugBoss / the editor manager expect.
  Result := UTF16ToUTF8(AValue);
end;

{ ---- source-path resolution ----------------------------------------------- }

class function TAefosLazDebugService._ResolveSourcePath(const AName: string): string;
var
  LEditor: TSourceEditorInterface;
  LProject: TLazProject;
  LProjFile: TLazProjectFile;
  LLcl, LWantedName: AnsiString;   // UTF-8 (LCL) domain throughout
  LIdx: Integer;
begin
  // The debug info (DWARF) binds a breakpoint against the FULL on-disk path the
  // compiler recorded - the exact form the gutter click uses (it always hands
  // DoCreateBreakPoint the editor's own TSourceEditor.Filename, sourceeditor.pp
  // :5956). SourceEditorIntfWithFilename compares the WHOLE path string
  // (CompareFilenameWithSrcEditIntf -> CompareFilenames, sourceeditor.pp:1951),
  // so a bare unit name ('Unit1') NEVER matches an open editor and the old code
  // fell through to the raw name - a breakpoint the backend can never bind (it
  // silently never halts). So resolve the name to a real full path: an open
  // editor by name first (the gutter's form), then the active project's unit list
  // for a closed unit. '' when unresolvable, so the caller refuses rather than arm
  // an unbindable breakpoint. All matching stays in the UTF-8 (LCL) domain via
  // CompareFilenames - OS-case-correct and the exact semantics the IDE uses.
  Result := '';
  if Trim(AName) = '' then
    Exit('');
  LLcl := _ToLcl(AName);
  // 0) Already an absolute path to an existing file: honour it verbatim.
  if FilenameIsAbsolute(LLcl) and FileExistsUTF8(LLcl) then
    Exit(_FromLcl(LLcl));
  // Ext-stripped name key, so 'Unit1', 'unit1.pas' and a full path all reduce to
  // the same comparison ('Unit1').
  LWantedName := ExtractFileNameOnly(LLcl);
  // 1) An open source editor whose name matches -> its full on-disk FileName.
  //    Byte-for-byte the gutter-click path, so the breakpoint binds.
  if SourceEditorManagerIntf <> nil then
  begin
    LEditor := SourceEditorManagerIntf.SourceEditorIntfWithFilename(LLcl);
    if LEditor <> nil then
      Exit(_FromLcl(LEditor.FileName));
    for LIdx := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
    begin
      LEditor := SourceEditorManagerIntf.SourceEditors[LIdx];
      if (LEditor <> nil)
        and (CompareFilenames(ExtractFileNameOnly(LEditor.FileName), LWantedName) = 0) then
        Exit(_FromLcl(LEditor.FileName));
    end;
  end;
  // 2) A unit that belongs to the active project but is NOT open in an editor.
  //    The project knows its absolute path (GetFullFilename), so a design-time
  //    breakpoint on a closed unit still binds against the debug info.
  if LazarusIDE <> nil then
  begin
    LProject := LazarusIDE.ActiveProject;
    if LProject <> nil then
      for LIdx := 0 to LProject.FileCount - 1 do
      begin
        LProjFile := LProject.Files[LIdx];
        if (LProjFile <> nil)
          and (CompareFilenames(ExtractFileNameOnly(LProjFile.GetFullFilename),
            LWantedName) = 0) then
          Exit(_FromLcl(LProjFile.GetFullFilename));
      end;
  end;
  // Unresolvable -> '' : the caller refuses with unit-not-found. A bare unit name
  // would create a breakpoint the debug info can never bind - it would never halt
  // AND leaves an unbindable slave in the debugger backend on the next run.
  Result := '';
end;

{ ---- state ---------------------------------------------------------------- }

function TAefosLazDebugService.DebugReadState: TAefosLazDebugState;
var
  LState: TAefosLazDebugState;
  LThreads: TThreads;
  LEntry: TThreadEntry;
  LFrame: TCallStackEntry;
  LCurId: Integer;
begin
  LState := Default(TAefosLazDebugState);
  // HasSession: a live debug session (mirrors Delphi ProcessCount > 0). The IDE
  // reports itDebugger from launch until the debuggee ends.
  LState.HasSession := (LazarusIDE <> nil) and (LazarusIDE.ToolStatus = itDebugger);
  if (not LState.HasSession) or (DebugBoss = nil) then
  begin
    Result := LState;
    Exit;
  end;
  // Stopped: the debuggee is paused and inspectable (dsPause / internal pause),
  // the Lazarus equivalent of Delphi psStopped/psFault/psException.
  LState.Stopped := DebugBoss.State in [dsPause, dsInternalPause];
  if not LState.Stopped then
  begin
    Result := LState;
    Exit;
  end;
  // Current location - BEST EFFORT. The threads/callstack are populated async by
  // the debugger on pause; when the current thread's top frame is available it
  // carries the source file + line. If not yet loaded, StopFile stays '' and the
  // state renders 'stopped (no source; thread N)'. Never fail the read on it.
  try
    LThreads := DebugBoss.Threads.CurrentThreads;
    if (LThreads <> nil) and (LThreads.Count > 0) then
    begin
      LCurId := LThreads.CurrentThreadId;
      LState.ThreadId := Cardinal(LCurId);
      LEntry := LThreads.EntryById[LCurId];
      if LEntry <> nil then
      begin
        if LEntry.ThreadTargetId <> 0 then
          LState.ThreadId := Cardinal(LEntry.ThreadTargetId);
        LFrame := LEntry.TopFrame;
        if LFrame <> nil then
        begin
          LState.StopFile := _FromLcl(LFrame.Source);
          LState.StopLine := LFrame.Line;
        end;
      end;
    end;
  except
    // The location is a nicety; a failure here must not break the state read.
  end;
  Result := LState;
end;

{ ---- breakpoints ---------------------------------------------------------- }

function TAefosLazDebugService.DebugSetBreakpoint(const AFileName: string;
  const ALine: Integer; const ACondition: string; const APassCount: Integer;
  out AReason: string): Boolean;
var
  LPath: string;
  LBkpt: TIDEBreakPoint;
begin
  Result := False;
  AReason := '';
  if DebugBoss = nil then
  begin
    AReason := 'debugger-services-unavailable';
    Exit;
  end;
  LPath := _ResolveSourcePath(AFileName);
  if LPath = '' then
  begin
    // Refuse rather than arm a bare-name breakpoint the debug info can never bind
    // (it would never halt). The unit must be open in an editor or part of the
    // active project so the full on-disk path - the form DWARF records - resolves.
    AReason := 'unit-not-found: cannot resolve ' + AFileName +
      ' to a source file (open it in the editor or add it to the active project)';
    Exit;
  end;
  LBkpt := nil;
  // WarnIfNoDebugger=False: a design-time breakpoint (armed before / independent
  // of a running debuggee - what an agent setting BPs wants) AND no warning modal
  // (a modal would block the MCP pipe). AnUpdating=False.
  if (DebugBoss.DoCreateBreakPoint(_ToLcl(LPath), ALine, False, LBkpt, False) <> mrOk)
    or (LBkpt = nil) then
  begin
    AReason := 'breakpoint-rejected: the debugger refused a breakpoint at '
      + ExtractFileName(LPath) + ':' + IntToStr(ALine);
    Exit;
  end;
  // Edit-in-place on the returned breakpoint (Expression = condition, BreakHitCount
  // = pass count), the Lazarus twins of the OTA IOTABreakpoint Expression/PassCount.
  if ACondition <> '' then
    LBkpt.Expression := _ToLcl(ACondition);
  if APassCount > 0 then
    LBkpt.BreakHitCount := APassCount;
  Result := True;
end;

function TAefosLazDebugService.DebugRemoveBreakpoint(const AFileName: string;
  const ALine: Integer): Boolean;
var
  LTarget, LTargetBase: string;
  LBkpt: TIDEBreakPoint;
  LIdx: Integer;
begin
  Result := False;
  if DebugBoss = nil then
    Exit;
  // Resolve for a full-path match; fall back to the raw name. Then match by
  // basename + line (mirrors the Delphi basename fallback) so a bare unit name
  // ('MainForm') removes a breakpoint stored under its full path.
  LTarget := _ResolveSourcePath(AFileName);
  if LTarget = '' then
    LTarget := AFileName;
  LTargetBase := ExtractFileName(LTarget);
  for LIdx := DebugBoss.BreakPoints.Count - 1 downto 0 do
  begin
    LBkpt := DebugBoss.BreakPoints.Items[LIdx];
    if (LBkpt <> nil) and (LBkpt.Line = ALine)
      and SameText(_FromLcl(ExtractFileName(LBkpt.Source)), LTargetBase) then
    begin
      DebugBoss.DoDeleteBreakPoint(LBkpt.Source, LBkpt.Line);
      Result := True;
      Exit;
    end;
  end;
end;

function TAefosLazDebugService.DebugListBreakpoints: TArray<string>;
var
  LList: TArray<string>;
  LBkpt: TIDEBreakPoint;
  LIdx: Integer;
begin
  LList := nil;
  if DebugBoss <> nil then
    for LIdx := 0 to DebugBoss.BreakPoints.Count - 1 do
    begin
      LBkpt := DebugBoss.BreakPoints.Items[LIdx];
      if LBkpt = nil then
        Continue;
      // Lazarus has no tracepoint marker on the base breakpoint the way the OTA
      // does, so this slice always renders a real breakpoint (ADoBreak=True,
      // ALogMessage=''); tracepoints are a later slice.
      LList := LList + [FormatBreakpointLine(
        _FromLcl(ExtractFileName(LBkpt.Source)), LBkpt.Line, LBkpt.Enabled,
        _FromLcl(LBkpt.Expression), LBkpt.BreakHitCount, True, '')];
    end;
  Result := LList;
end;

{ ---- stepping / run control ----------------------------------------------- }

function TAefosLazDebugService.DebugStep(const AKind: TAefosLazDebugStepKind): Boolean;
begin
  // Dispatch a step through DebugBoss - the SAME programmatic entry the RunMenu
  // 'Step over'/'Step into'/'Step out' items fire (DoStepOverProject /
  // DoStepIntoProject / DoStepOutProject, basedebugmanager.pas:156-158). These
  // ALSO start the project from scratch when nothing is running, so require the
  // debuggee already PAUSED (State in [dsPause, dsInternalPause]) - the same
  // precondition the tool guard checks - and refuse otherwise, so a direct call
  // can never silently launch. The advance is async; the caller re-polls
  // DebugReadState (parity with the Delphi DebugStep, DebugService.pas:740).
  Result := False;
  if DebugBoss = nil then
    Exit;
  if not (DebugBoss.State in [dsPause, dsInternalPause]) then
    Exit;
  case AKind of
    dskOver: DebugBoss.DoStepOverProject;
    dskInto: DebugBoss.DoStepIntoProject;
    dskOut:  DebugBoss.DoStepOutProject;
  end;
  Result := True;
end;

function TAefosLazDebugService.DebugContinue: Boolean;
begin
  // Resume a paused debuggee (F9). LazarusIDE.DoRunProject (lazideintf.pas:383)
  // routes to CONTINUE when a session is live and paused, and is NON-BLOCKING
  // (unlike DebugBoss.RunDebugger, which waits until the program ends). The run is
  // async, so the caller re-polls DebugReadState (parity with the Delphi
  // DebugContinue = IOTAProcess.Run(ormRun), DebugService.pas:796).
  Result := False;
  if LazarusIDE = nil then
    Exit;
  // The resumed program may simply RUN TO THE END, and the debugger's stop /
  // exit-code box is pumped by this very thread - the one the MCP pipe answers
  // on. Arm the IDE's own one-shot SkipStopMessage for that stop (see
  // Aefos.Lazarus.IdeSilence); no user preference is read or written.
  TAefosIdeSilence.ArmDebuggerStopSilence;
  LazarusIDE.DoRunProject;
  Result := True;
end;

function TAefosLazDebugService.DebugPause: Boolean;
begin
  // Pause a running debuggee so it can be inspected (DoPauseProject,
  // basedebugmanager.pas:154 - the RunMenu 'Pause' item). The pause lands async;
  // the caller re-polls DebugReadState (parity with the Delphi DebugPause =
  // IOTAProcess.Pause, DebugService.pas:828).
  Result := False;
  if DebugBoss = nil then
    Exit;
  DebugBoss.DoPauseProject;
  Result := True;
end;

function TAefosLazDebugService.DebugRunToLine(const AFileName: string;
  const ALine: Integer): Boolean;
var
  LReason: string;
begin
  // Two steps, byte-for-byte the Delphi DebugRunToLine (DebugService.pas:610):
  // plant a plain breakpoint at unit:line, then dispatch Continue. Lazarus (like
  // the ToolsAPI) has no one-shot breakpoint, so it PERSISTS after the stop - the
  // tool description tells the agent to RemoveBreakpoint afterwards when it was
  // temporary. The caller polls DebugReadState for the stop.
  Result := DebugSetBreakpoint(AFileName, ALine, '', 0, LReason);
  if Result then
    Result := DebugContinue;
end;

{ ---- pure renderers (verbatim from Aefos.MCP.OTA.DebugPolicy) -------------- }

class function TAefosLazDebugService.FormatDebugState(
  const AState: TAefosLazDebugState): string;
begin
  if not AState.HasSession then
    Exit('no-debug-session');
  if not AState.Stopped then
    Exit('running');
  if AState.StopFile <> '' then
    Result := Format('stopped-at %s:%d (thread %u)',
      [AState.StopFile, AState.StopLine, AState.ThreadId])
  else
    Result := Format('stopped (no source; thread %u)', [AState.ThreadId]);
end;

class function TAefosLazDebugService.FormatBreakpointLine(const AFileName: string;
  const ALine: Integer; const AEnabled: Boolean; const AExpression: string;
  const APassCount: Integer; const ADoBreak: Boolean;
  const ALogMessage: string): string;
begin
  Result := Format('%s:%d', [AFileName, ALine]);
  if not AEnabled then
    Result := Result + ' disabled';
  if AExpression <> '' then
    Result := Result + ' if ' + AExpression;
  if APassCount > 0 then
    Result := Result + ' pass ' + IntToStr(APassCount);
  if ALogMessage <> '' then
    Result := Result + ' log "' + ALogMessage + '"';
  if not ADoBreak then
    Result := Result + ' (tracepoint)';
end;

class function TAefosLazDebugService.FormatCallFrame(const AHeader, AFileName: string;
  const ALine: Integer): string;
begin
  if AFileName <> '' then
    Result := Format('%s  %s:%d', [AHeader, AFileName, ALine])
  else
    Result := AHeader;
end;

{ ---- inspection (locals / evaluate / call stack) -------------------------- }

// Pump the IDE main-thread message queue ONE bounded round (process messages +
// flush queued cross-thread results), then a short yield. Runs on the IDE main
// thread (the registrar marshalled the caller here) - the Lazarus analogue of the
// Delphi LDS.ProcessDebugEvents pump. Guarded so a pump fault never takes the tool
// down. Kept a class method (house rule: no loose global routines).
class procedure TAefosLazDebugService._PumpMainThread; static;
begin
  try
    Application.ProcessMessages;
    CheckSynchronize(1);
  except
    // A reentrant pump fault is not the tool's concern; the deadline still bounds us.
  end;
  Sleep(5);
end;

function TAefosLazDebugService.DebugInspectLocals: TArray<string>;
var
  LList: TArray<string>;
  LThreads: TThreads;
  LStack: TIdeCallStack;
  LLocals: TIDELocals;
  LVal: TLocalsValue;
  LThreadId, LFrame, LIdx: Integer;
  LStartTick: QWord;
  LPumps: Integer;
begin
  LList := nil;
  if (DebugBoss = nil) or (LazarusIDE = nil)
    or (LazarusIDE.ToolStatus <> itDebugger)
    or (not (DebugBoss.State in [dsPause, dsInternalPause])) then
    Exit(nil);
  try
    // Current thread + the IDE-selected stack frame: the native Locals supplier is
    // keyed on exactly this (thread, frame) pair (localsdlg.pp GetThreadId /
    // GetStackframe). Default to thread 1 / frame 0 when the monitors are empty.
    LThreadId := 1;
    LThreads := DebugBoss.Threads.CurrentThreads;
    if LThreads <> nil then
      LThreadId := LThreads.CurrentThreadId;
    LFrame := 0;
    LStack := DebugBoss.CallStack.CurrentCallStackList.EntriesForThreads[LThreadId];
    if LStack <> nil then
      LFrame := LStack.CurrentIndex;
    LLocals := DebugBoss.Locals.CurrentLocalsList[LThreadId, LFrame];
    if LLocals = nil then
      Exit(nil);
    // Accessing Count while the data is not yet loaded TRIGGERS the async request
    // (localsdlg.pp:658). Pump the main-thread queue until the list is valid or the
    // budget runs out; re-poke Count each round to keep the request alive.
    if LLocals is TCurrentLocals then
    begin
      LStartTick := GetTickCount64;
      LPumps := 0;
      LLocals.Count; // trigger
      while (TCurrentLocals(LLocals).Validity in [ddsUnknown, ddsRequested, ddsEvaluating])
        and (LPumps < CLazDebugPumpMaxIterations)
        and (GetTickCount64 - LStartTick < CLazDebugPumpDeadlineMs)
        and (LazarusIDE.ToolStatus = itDebugger) do
      begin
        _PumpMainThread;
        Inc(LPumps);
        LLocals.Count;
      end;
    end;
    for LIdx := 0 to LLocals.Count - 1 do
    begin
      LVal := LLocals.Entries[LIdx];
      if LVal <> nil then
        LList := LList + [_FromLcl(LVal.Name) + ' = ' + _FromLcl(LVal.Value)];
    end;
  except
    // Best-effort: a supplier fault must not crash the transport (parity with the
    // Delphi read's try/except).
  end;
  Result := LList;
end;

function TAefosLazDebugService.DebugEvaluate(const AExpr: string;
  out AResult: string): Boolean;
var
  LCatcher: TAefosLazEvalCatcher;
  LStartTick: QWord;
  LPumps: Integer;
begin
  Result := False;
  AResult := 'no-debug-session';
  if (DebugBoss = nil) or (LazarusIDE = nil)
    or (LazarusIDE.ToolStatus <> itDebugger) then
    Exit;
  if not (DebugBoss.State in [dsPause, dsInternalPause]) then
  begin
    AResult := 'process-running';
    Exit;
  end;
  LCatcher := TAefosLazEvalCatcher.Create;
  try
    // DebugBoss.Evaluate is ASYNC: it returns whether the evaluate could be STARTED,
    // and the backend answers later through the callback on the IDE main thread. We
    // are already on the main thread (the registrar marshalled us here), so pump the
    // message queue - bounded by a deadline + iteration cap - until the callback
    // fires, exactly like the Delphi erDeferred pump (DebugService.pas:903). No @ on
    // the method pointer: this unit is $mode delphiunicode.
    if not DebugBoss.Evaluate(_ToLcl(AExpr), LCatcher.Callback, []) then
    begin
      AResult := 'evaluate-unavailable';
      Exit;
    end;
    LStartTick := GetTickCount64;
    LPumps := 0;
    while (not LCatcher.Done) and (LPumps < CLazDebugPumpMaxIterations)
      and (GetTickCount64 - LStartTick < CLazDebugPumpDeadlineMs)
      and (LazarusIDE.ToolStatus = itDebugger) do
    begin
      _PumpMainThread;
      Inc(LPumps);
    end;
    if not LCatcher.Done then
    begin
      AResult := 'evaluate-timeout';
      Exit;
    end;
    AResult := Trim(_FromLcl(LCatcher.ResultText));
    Result := LCatcher.Success;
    if (not Result) and (AResult = '') then
      AResult := 'evaluate-failed';
  finally
    LCatcher.Free;
  end;
end;

function TAefosLazDebugService.DebugGetCallStack: TArray<string>;
var
  LList: TArray<string>;
  LThreads: TThreads;
  LStack: TIdeCallStack;
  LEntry: TIdeCallStackEntry;
  LThreadId, LCount, LIdx: Integer;
  LStartTick: QWord;
  LPumps: Integer;
begin
  LList := nil;
  if (DebugBoss = nil) or (LazarusIDE = nil)
    or (LazarusIDE.ToolStatus <> itDebugger)
    or (not (DebugBoss.State in [dsPause, dsInternalPause])) then
    Exit(nil);
  try
    LThreadId := 1;
    LThreads := DebugBoss.Threads.CurrentThreads;
    if LThreads <> nil then
      LThreadId := LThreads.CurrentThreadId;
    LStack := DebugBoss.CallStack.CurrentCallStackList.EntriesForThreads[LThreadId];
    if LStack = nil then
      Exit(nil);
    // CountLimited(N) triggers the async count request AND caps the work
    // (callstackdlg.pp:353/587). Pump until the count is valid or the budget ends.
    LStartTick := GetTickCount64;
    LPumps := 0;
    LCount := LStack.CountLimited(CLazDebugMaxStackFrames);
    while (LStack.CountValidity in [ddsUnknown, ddsRequested, ddsEvaluating])
      and (LPumps < CLazDebugPumpMaxIterations)
      and (GetTickCount64 - LStartTick < CLazDebugPumpDeadlineMs)
      and (LazarusIDE.ToolStatus = itDebugger) do
    begin
      _PumpMainThread;
      Inc(LPumps);
      LCount := LStack.CountLimited(CLazDebugMaxStackFrames);
    end;
    if LCount > CLazDebugMaxStackFrames then
      LCount := CLazDebugMaxStackFrames;
    if LCount <= 0 then
      Exit(nil);
    // Load the frame range so Entries are populated (callstackdlg.pp:414), then pump
    // for its own async fill until the last requested frame exists or the budget ends.
    LStack.PrepareRange(0, LCount);
    LStartTick := GetTickCount64;
    LPumps := 0;
    while (LPumps < CLazDebugPumpMaxIterations)
      and (GetTickCount64 - LStartTick < CLazDebugPumpDeadlineMs)
      and (LazarusIDE.ToolStatus = itDebugger)
      and (not LStack.HasEntry(LCount - 1)) do
    begin
      _PumpMainThread;
      Inc(LPumps);
    end;
    for LIdx := 0 to LCount - 1 do
    begin
      LEntry := LStack.Entries[LIdx];
      if LEntry <> nil then
        LList := LList + [FormatCallFrame(_FromLcl(LEntry.GetFunctionWithArg),
          _FromLcl(LEntry.Source), LEntry.Line)];
    end;
  except
    // Best-effort: a supplier fault must not crash the transport.
  end;
  Result := LList;
end;

end.
