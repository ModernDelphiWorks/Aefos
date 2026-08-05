unit Aefos.MCP.OTA.DebugPolicy;

{
  Pure decision seam for the agent debug tools (future plan:
  .local-readonly\ota-agent-debug-plan.md, Phase 1 core).

  Pure RTL - no ToolsAPI, no VCL, no I/O. Carries the OTA-free decisions the
  debug tools must make before the facade drives IOTADebuggerServices /
  IOTAProcess / IOTAThread:

    - DebugGuard        - the RULE #1-spirit precondition guard. Each debug
                          tool declares what the debugger must already be in
                          (nothing / a live session / a STOPPED process) and
                          this returns a machine-actionable kebab reason
                          ('no-debug-session', 'process-running') the agent can
                          self-correct on, mirroring the view guard's
                          'wrong-view-design'/'wrong-view-code'.
    - FormatDebugState  - the one-line state vocabulary the FlowGuide loop
                          chains on ("tool result IS the next prompt"): a stop
                          reads 'stopped-at Unit1.pas:42 (thread 1234)' and
                          directly invites GetCallStack / EvaluateExpression.
    - SnapBreakableLine - snap a requested breakpoint line to the nearest line
                          the compiler will actually break on (the facade
                          supplies the breakable set from
                          IOTAProcess.GetSourceLines), so SetBreakpoint never
                          silently plants a BP on a blank/comment line.

  Mirrors the ESP-091 BuildRunPolicy precedent: a pure, dependency-free seam
  unit-tested headless, with the OTA wiring (IOTADebuggerServices state read,
  NewSourceBreakpoint, Run(RunMode), Evaluate) confined to the facade
  (Aefos.MCP.OTA.DebugService, not written yet) as the only OTA-bound,
  structurally-exempt part - proven live by the Phase 0 spike first.
}

interface

type
  // Snapshot of the live debugger, filled by the OTA facade from
  // IOTADebuggerServices/CurrentProcess/CurrentThread and passed here so all
  // the decision logic stays headless-testable.
  TDebugState = record
    HasSession: Boolean;  // a debugged process exists (ProcessCount > 0)
    Stopped: Boolean;     // the current process is at a stop (state <> running)
    StopFile: string;     // current thread source file (when Stopped)
    StopLine: Integer;    // current thread source line (when Stopped)
    ThreadId: Cardinal;   // current OS thread id (when Stopped)
  end;

  // What a debug tool requires of the debugger before the facade acts.
  //   dpNone    - no requirement (SetBreakpoint works design-time, nil process)
  //   dpSession - needs a debugged process (PauseRun, ListThreads, GetDebugState
  //               is dpNone since it always answers)
  //   dpStopped - needs the process STOPPED (StepOver, EvaluateExpression,
  //               GetCallStack, InspectLocals)
  TDebugPrecondition = (dpNone, dpSession, dpStopped);

  // How a live breakpoint's file relates to a requested file (see
  // MatchBreakpointFile). Full-path identity outranks a basename-only match.
  TBreakpointFileMatch = (bfmNone, bfmFullPath, bfmBaseName);

  // Pure decision seam for the agent debug tools as a sealed static namespace
  // (see the unit header for the Phase 1 core contract). Never instantiated.
  TDebugPolicy = class sealed
  public
    // Validates a tool's precondition against the live state. Returns True when the
    // tool may proceed; otherwise False with AReason set to a kebab code the agent
    // acts on:
    //   'no-debug-session' - needs a running debuggee -> call RunProject and resend
    //   'process-running'  - needs the process stopped -> PauseRun / wait for a BP
    class function DebugGuard(const AState: TDebugState;
      const ANeed: TDebugPrecondition; out AReason: string): Boolean; static;

    // One-line, agent-chainable rendering of the debugger state:
    //   no session          -> 'no-debug-session'
    //   session, running    -> 'running'
    //   stopped with source -> 'stopped-at <file>:<line> (thread <id>)'
    //   stopped, no source  -> 'stopped (no source; thread <id>)'
    class function FormatDebugState(const AState: TDebugState): string; static;

    // Renders a small source snippet around the stop line so the agent SEES the code
    // it is on, not just the number: lines [ACurrentLine-ARadius .. +ARadius] (clamped
    // to the file), each as '  <n>: <text>', with the current line marked '> <n>: ...'.
    // Pure (splits ASource itself). Returns '' when ASource is empty or ACurrentLine
    // falls outside it.
    class function FormatSourceContext(const ASource: string; const ACurrentLine,
      ARadius: Integer): string; static;

    // Snaps ARequested to the nearest breakable line in ABreakable (the sorted or
    // unsorted set of lines the compiler emits code for). Rules:
    //   - empty set (design-time / unknown)      -> ARequested unchanged
    //   - ARequested already breakable           -> ARequested
    //   - otherwise the nearest line; on a tie   -> the LOWER line (break earlier)
    class function SnapBreakableLine(const ARequested: Integer;
      const ABreakable: TArray<Integer>): Integer; static;

    // Defensive cleanup of an evaluator result string (the CnPack
    // CropDebugQuotaStr caveat): the debugger crops long values at its quota,
    // which can leave an UNBALANCED trailing quote. Trims trailing NULs/blanks
    // (the facade copies out of a fixed PChar buffer); then, when the value holds
    // an ODD number of single quotes AND ends with one, that trailing quote is
    // dropped. Balanced values pass through untouched.
    class function NormalizeEvalResult(const AValue: string): string; static;

    // One call-stack frame line the agent chains on: 'header  file:line' when the
    // frame has source; the bare header when FileName is empty (the ToolsAPI
    // contract for a frame with no debug info: FileName = '', Line = 0).
    class function FormatCallFrame(const AHeader, AFileName: string;
      const ALine: Integer): string; static;

    // One thread line for ListThreads:
    //   'thread <osid> <state>[ name="<name>"][ at <file>:<line>][ (current)]'
    // AStateStr is the facade's rendering of TOTAThreadState (kept a plain string
    // so this unit stays ToolsAPI-free).
    class function FormatThreadLine(const AOSThreadId: Cardinal; const AName, AStateStr,
      AFileName: string; const ALine: Integer;
      const AIsCurrent: Boolean): string; static;

    // Breakpoint identity (the GExperts rule): a full-path match (SameFileName -
    // case/separator-insensitive) is the primary key; basename equality is the
    // FALLBACK only (bare unit names / relocated files). Matching basenames first
    // collides across directories - two Unit1.pas in different projects.
    class function MatchBreakpointFile(const ABkptFile,
      ARequestFile: string): TBreakpointFileMatch; static;

    // One breakpoint line for ListBreakpoints (the facade feeds the live
    // IOTASourceBreakpoint fields; the rendering stays pure):
    //   '<file>:<line>[ disabled][ if <expr>][ pass <n>][ log "<msg>"][ (tracepoint)]'
    // APassCount <= 0 and empty strings render nothing; ADoBreak = False marks a
    // tracepoint (log-and-continue) so the agent can tell it from a real stop.
    class function FormatBreakpointLine(const AFileName: string; const ALine: Integer;
      const AEnabled: Boolean; const AExpression: string;
      const APassCount: Integer; const ADoBreak: Boolean;
      const ALogMessage: string): string; static;

    // Strips ONE balanced pair of surrounding single quotes from a debugger string
    // value ('EAbort' -> EAbort) and un-doubles the '' escapes the evaluator emits
    // inside ('it''s' -> it's). Unquoted / unbalanced values pass through
    // untouched - GetExceptionInfo uses this so 'class'/'message' come back as
    // plain text, not evaluator-quoted literals.
    class function UnquoteEvalString(const AValue: string): string; static;
  end;

implementation

uses
  System.SysUtils;

class function TDebugPolicy.DebugGuard(const AState: TDebugState;
  const ANeed: TDebugPrecondition; out AReason: string): Boolean;
begin
  AReason := '';
  case ANeed of
    dpNone:
      Result := True;
    dpSession:
      begin
        Result := AState.HasSession;
        if not Result then
          AReason := 'no-debug-session';
      end;
    dpStopped:
      begin
        if not AState.HasSession then
        begin
          AReason := 'no-debug-session';
          Exit(False);
        end;
        Result := AState.Stopped;
        if not Result then
          AReason := 'process-running';
      end;
  else
    // Unreachable for the closed enum, but keep the guard fail-closed rather
    // than fall through to an uninitialised Result.
    Result := False;
    AReason := 'unknown-precondition';
  end;
end;

class function TDebugPolicy.FormatDebugState(const AState: TDebugState): string;
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

class function TDebugPolicy.FormatSourceContext(const ASource: string; const ACurrentLine,
  ARadius: Integer): string;
var
  LLines: TArray<string>;
  LFrom, LTo, LFor: Integer;
  LMark: string;
  LSb: TStringBuilder;
begin
  Result := '';
  if (ASource = '') or (ACurrentLine <= 0) then
    Exit;
  LLines := ASource.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  if (Length(LLines) = 0) or (ACurrentLine > Length(LLines)) then
    Exit;
  LFrom := ACurrentLine - ARadius;
  if LFrom < 1 then
    LFrom := 1;
  LTo := ACurrentLine + ARadius;
  if LTo > Length(LLines) then
    LTo := Length(LLines);
  LSb := TStringBuilder.Create;
  try
    for LFor := LFrom to LTo do
    begin
      if LFor > LFrom then
        LSb.Append(#10);
      if LFor = ACurrentLine then
        LMark := '> '
      else
        LMark := '  ';
      // LLines is 0-based; source lines are 1-based.
      LSb.Append(Format('%s%d: %s', [LMark, LFor, LLines[LFor - 1]]));
    end;
    Result := LSb.ToString;
  finally
    LSb.Free;
  end;
end;

class function TDebugPolicy.SnapBreakableLine(const ARequested: Integer;
  const ABreakable: TArray<Integer>): Integer;
var
  LLine, LBestDelta, LDelta: Integer;
begin
  if Length(ABreakable) = 0 then
    Exit(ARequested);
  Result := ABreakable[0];
  LBestDelta := Abs(ABreakable[0] - ARequested);
  for LLine in ABreakable do
  begin
    if LLine = ARequested then
      Exit(ARequested);
    LDelta := Abs(LLine - ARequested);
    // Strictly-less keeps the FIRST-seen on a tie; to make ties deterministic
    // as "the lower line" regardless of input order, also take a same-delta
    // candidate when it is lower than the current pick.
    if (LDelta < LBestDelta) or ((LDelta = LBestDelta) and (LLine < Result)) then
    begin
      LBestDelta := LDelta;
      Result := LLine;
    end;
  end;
end;

class function TDebugPolicy.NormalizeEvalResult(const AValue: string): string;
var
  LLen, LQuotes, LIndex: Integer;
begin
  Result := AValue;
  // Trim trailing NULs and blanks the fixed evaluate buffer can carry.
  LLen := Length(Result);
  while (LLen > 0) and (Result[LLen] <= ' ') do
    Dec(LLen);
  SetLength(Result, LLen);
  // Odd quote count + trailing quote = the quota crop artifact; drop it.
  LQuotes := 0;
  for LIndex := 1 to LLen do
    if Result[LIndex] = '''' then
      Inc(LQuotes);
  if (LLen > 0) and (LQuotes mod 2 = 1) and (Result[LLen] = '''') then
    SetLength(Result, LLen - 1);
end;

class function TDebugPolicy.FormatCallFrame(const AHeader, AFileName: string;
  const ALine: Integer): string;
begin
  if AFileName <> '' then
    Result := Format('%s  %s:%d', [AHeader, AFileName, ALine])
  else
    Result := AHeader;
end;

class function TDebugPolicy.FormatThreadLine(const AOSThreadId: Cardinal; const AName, AStateStr,
  AFileName: string; const ALine: Integer;
  const AIsCurrent: Boolean): string;
begin
  Result := Format('thread %u %s', [AOSThreadId, AStateStr]);
  if AName <> '' then
    Result := Result + Format(' name="%s"', [AName]);
  if AFileName <> '' then
    Result := Result + Format(' at %s:%d', [AFileName, ALine]);
  if AIsCurrent then
    Result := Result + ' (current)';
end;

class function TDebugPolicy.MatchBreakpointFile(const ABkptFile,
  ARequestFile: string): TBreakpointFileMatch;
begin
  if SameFileName(ABkptFile, ARequestFile) then
    Exit(bfmFullPath);
  if SameText(ExtractFileName(ABkptFile), ExtractFileName(ARequestFile)) then
    Exit(bfmBaseName);
  Result := bfmNone;
end;

class function TDebugPolicy.FormatBreakpointLine(const AFileName: string; const ALine: Integer;
  const AEnabled: Boolean; const AExpression: string;
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

class function TDebugPolicy.UnquoteEvalString(const AValue: string): string;
var
  LLen: Integer;
begin
  Result := AValue;
  LLen := Length(Result);
  if (LLen >= 2) and (Result[1] = '''') and (Result[LLen] = '''') then
  begin
    Result := Copy(Result, 2, LLen - 2);
    Result := StringReplace(Result, '''''', '''', [rfReplaceAll]);
  end;
end;

end.
