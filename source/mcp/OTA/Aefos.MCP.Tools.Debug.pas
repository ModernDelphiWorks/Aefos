unit Aefos.MCP.Tools.Debug;

{
  MCP tool registrar for the agent debug family (future plan:
  .local-readonly\ota-agent-debug-plan.md, Phase 1+2).

  Peer of Aefos.MCP.Tools.Build. Each tool is a thin, view-NEUTRAL wrapper: it
  reads the live debugger state (Aefos.MCP.OTA.DebugService, which marshals to
  the IDE main thread), applies the pure precondition guard
  (Aefos.MCP.OTA.DebugPolicy.DebugGuard -> machine-actionable kebab reason the
  agent self-corrects on), then acts. The OTA is confined to DebugService; the
  decisions are the headless-tested DebugPolicy.

  v1 scope: no interactive consent gate yet (mutating debug ops are session-
  scoped, far less destructive than file edits) and no persistent notifier
  (GetDebugState polls) - both are tracked follow-ups. Registered from the chat
  + inspector MCP bootstraps via RegisterDebugTools.
}

interface

uses
  Aefos.MCP.Server;

// Registers the debug tool family on AServer. Call it once per MCP server
// build, alongside RegisterProjectTools / RegisterUnitsTools.
procedure RegisterDebugTools(const AServer: IMCPServer);

implementation

uses
  System.SysUtils,
  System.JSON,
  System.IOUtils,
  Aefos.MCP.Types,
  Aefos.MCP.OTA.DebugPolicy,
  Aefos.MCP.OTA.DebugService;

var
  // The single debug service, resolved once on first use (this unit is its only
  // consumer). An interface ref to a plain TInterfacedObject in the same BPL —
  // the RTL finalizes the global on unload, no IDE ref is ever held.
  GDebugService: IMCPDebugService = nil;

function _Debug: IMCPDebugService;
begin
  if GDebugService = nil then
    GDebugService := NewMCPDebugService;
  Result := GDebugService;
end;

function _Schema(const AJson: string): TJSONObject;
begin
  // The server takes ownership of the returned object after RegisterTool.
  Result := TJSONObject.ParseJSONValue(AJson) as TJSONObject;
  if Result = nil then
    Result := TJSONObject.ParseJSONValue('{"type":"object","properties":{}}')
      as TJSONObject;
end;

function _EmptySchema: TJSONObject;
begin
  Result := _Schema('{"type":"object","properties":{}}');
end;

function _Res(const AContent: string): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  Result.Content := AContent;
end;

// Machine-actionable guard failure: the kebab reason IS the payload the agent
// keys off (mirrors the view guard's wrong-view-* contract). Carried in the
// content JSON since TMCPToolResult has no separate error flag.
function _GuardErr(const AReason: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('error', AReason);
    Result := _Res(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function _ParamStr(const AParams: TJSONObject; const AName: string): string;
var
  LVal: TJSONValue;
begin
  Result := '';
  if not Assigned(AParams) then
    Exit;
  LVal := AParams.GetValue(AName);
  if LVal is TJSONString then
    Result := TJSONString(LVal).Value;
end;

function _ParamInt(const AParams: TJSONObject; const AName: string): Integer;
var
  LVal: TJSONValue;
begin
  Result := 0;
  if not Assigned(AParams) then
    Exit;
  LVal := AParams.GetValue(AName);
  if LVal is TJSONNumber then
    Result := TJSONNumber(LVal).AsInt;
end;

function _StateResult(const AExtraKey, AExtraVal: string): TMCPToolResult;
var
  LObj: TJSONObject;
  LState: TDebugState;
  LSrc, LCtx: string;
begin
  LState := _Debug.DebugReadState;
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('state', TDebugPolicy.FormatDebugState(LState));
    LObj.AddPair('hasSession', TJSONBool.Create(LState.HasSession));
    LObj.AddPair('stopped', TJSONBool.Create(LState.Stopped));
    if LState.Stopped then
    begin
      LObj.AddPair('file', LState.StopFile);
      LObj.AddPair('line', TJSONNumber.Create(LState.StopLine));
      LObj.AddPair('thread', TJSONNumber.Create(Int64(LState.ThreadId)));
      // Show the CODE at the stop (current line + a little context), so the
      // agent sees WHAT it is about to run - not just the line number. Reading
      // the saved file is correct: a debugged build matches it on disk.
      LSrc := '';
      if (LState.StopFile <> '') and TFile.Exists(LState.StopFile) then
        try
          LSrc := TFile.ReadAllText(LState.StopFile);
        except
          LSrc := '';
        end;
      if LSrc <> '' then
      begin
        LCtx := TDebugPolicy.FormatSourceContext(LSrc, LState.StopLine, 3);
        if LCtx <> '' then
          LObj.AddPair('source', LCtx);
      end;
    end;
    if AExtraKey <> '' then
      LObj.AddPair(AExtraKey, AExtraVal);
    Result := _Res(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

// Step tools share this shape: guard STOPPED, dispatch, then report the state.
function _StepTool(const AKind: TDebugStepKind): TMCPToolResult;
var
  LReason: string;
begin
  if not TDebugPolicy.DebugGuard(_Debug.DebugReadState, dpStopped, LReason) then
    Exit(_GuardErr(LReason));
  _Debug.DebugStep(AKind);
  Result := _StateResult('dispatched', 'true');
end;

function _Desc(const AName, ATitle, ADescription: string;
  const ASchema: TJSONObject; const AHandler: TMCPToolHandler):
  TMCPToolDescriptor;
begin
  Result := Default(TMCPToolDescriptor);
  Result.Name := AName;
  Result.Title := ATitle;
  Result.Description := ADescription;
  Result.InputSchema := ASchema;
  Result.Handler := AHandler;
end;

procedure RegisterDebugTools(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create('RegisterDebugTools: AServer');

  AServer.RegisterTool(_Desc('GetDebugState', 'Get debug state',
    'Returns the live debugger state: whether a debugged process exists, ' +
    'whether it is STOPPED (at a breakpoint/exception), and the current ' +
    'file:line + thread. Poll this after RunProject / a step / ContinueRun ' +
    'to learn where execution is. Never changes anything.',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _StateResult('', '');
    end));

  AServer.RegisterTool(_Desc('SetBreakpoint', 'Set breakpoint',
    'Creates a source breakpoint at unit:line (works before a run - a ' +
    'design-time breakpoint). Optional: "condition" (a Delphi boolean ' +
    'expression - the breakpoint only stops when it is true) and ' +
    '"passCount" (skip that many passes before stopping). Run the project, ' +
    'then poll GetDebugState to see it stop.',
    _Schema('{"type":"object","properties":{"unit":{"type":"string"},' +
      '"line":{"type":"integer"},"condition":{"type":"string"},' +
      '"passCount":{"type":"integer"}},"required":["unit","line"]}'),
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason: string;
    begin
      if _Debug.DebugSetBreakpoint(_ParamStr(AParams, 'unit'),
        _ParamInt(AParams, 'line'), _ParamStr(AParams, 'condition'),
        _ParamInt(AParams, 'passCount'), LReason) then
        Result := _Res('{"applied":true}')
      else
        Result := _Res('{"applied":false,"reason":' +
          TJSONString.Create(LReason).ToString + '}');
    end));

  AServer.RegisterTool(_Desc('SetTracepoint', 'Set tracepoint',
    'Creates a NON-BREAKING tracepoint at unit:line: each time execution ' +
    'passes it, logMessage is written to the IDE Event Log and the run ' +
    'CONTINUES (log-and-continue - printf debugging without recompiling). ' +
    'Optional "evalExpr" also evaluates an expression on each pass and logs ' +
    'its value. Works before a run, like SetBreakpoint. Remove it with ' +
    'RemoveBreakpoint at the same unit:line.',
    _Schema('{"type":"object","properties":{"unit":{"type":"string"},' +
      '"line":{"type":"integer"},"logMessage":{"type":"string"},' +
      '"evalExpr":{"type":"string"}},' +
      '"required":["unit","line","logMessage"]}'),
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason: string;
    begin
      if _Debug.DebugSetTracepoint(_ParamStr(AParams, 'unit'),
        _ParamInt(AParams, 'line'), _ParamStr(AParams, 'logMessage'),
        _ParamStr(AParams, 'evalExpr'), LReason) then
        Result := _Res('{"applied":true}')
      else
        Result := _Res('{"applied":false,"reason":' +
          TJSONString.Create(LReason).ToString + '}');
    end));

  AServer.RegisterTool(_Desc('RemoveBreakpoint', 'Remove breakpoint',
    'Removes the source breakpoint at unit:line, if one exists.',
    _Schema('{"type":"object","properties":{"unit":{"type":"string"},' +
      '"line":{"type":"integer"}},"required":["unit","line"]}'),
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _Res('{"applied":' +
        LowerCase(BoolToStr(_Debug.DebugRemoveBreakpoint(_ParamStr(AParams, 'unit'),
          _ParamInt(AParams, 'line')), True)) + '}');
    end));

  AServer.RegisterTool(_Desc('ListBreakpoints', 'List breakpoints',
    'Lists the current source breakpoints as "file:line[ disabled][ if expr]".',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LArr: TJSONArray;
      LItem: string;
    begin
      LArr := TJSONArray.Create;
      try
        for LItem in _Debug.DebugListBreakpoints do
          LArr.Add(LItem);
        Result := _Res('{"breakpoints":' + LArr.ToJSON + '}');
      finally
        LArr.Free;
      end;
    end));

  AServer.RegisterTool(_Desc('StepOver', 'Step over',
    'Steps over the current source line (F8). Requires the process STOPPED. ' +
    'Then poll GetDebugState for the new location.',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _StepTool(dskOver);
    end));

  AServer.RegisterTool(_Desc('StepInto', 'Step into',
    'Traces into the call on the current line (F7). Requires STOPPED.',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _StepTool(dskInto);
    end));

  AServer.RegisterTool(_Desc('StepOut', 'Step out',
    'Runs until the current routine returns (Shift+F8). Requires STOPPED.',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _StepTool(dskOut);
    end));

  AServer.RegisterTool(_Desc('ContinueRun', 'Continue',
    'Resumes a stopped process (F9). Falls back to RunProject when no ' +
    'session exists.',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason: string;
    begin
      if not TDebugPolicy.DebugGuard(_Debug.DebugReadState, dpSession, LReason) then
        Exit(_GuardErr(LReason));
      _Debug.DebugContinue;
      Result := _StateResult('dispatched', 'true');
    end));

  AServer.RegisterTool(_Desc('RunToLine', 'Run to line',
    'Sets a breakpoint at unit:line and continues the debugged process, so ' +
    'it runs until that line (or an earlier stop). Requires a debug session. ' +
    'Poll GetDebugState for the stop. NOTE: the breakpoint PERSISTS after ' +
    'the stop (the IDE has no one-shot breakpoints) - call RemoveBreakpoint ' +
    'at the same unit:line if it was temporary.',
    _Schema('{"type":"object","properties":{"unit":{"type":"string"},' +
      '"line":{"type":"integer"}},"required":["unit","line"]}'),
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason: string;
    begin
      if not TDebugPolicy.DebugGuard(_Debug.DebugReadState, dpSession, LReason) then
        Exit(_GuardErr(LReason));
      if not _Debug.DebugRunToLine(_ParamStr(AParams, 'unit'),
        _ParamInt(AParams, 'line')) then
        Exit(_Res('{"applied":false}'));
      Result := _StateResult('dispatched', 'true');
    end));

  AServer.RegisterTool(_Desc('PauseRun', 'Pause',
    'Pauses a running debugged process so it can be inspected.',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason: string;
    begin
      if not TDebugPolicy.DebugGuard(_Debug.DebugReadState, dpSession, LReason) then
        Exit(_GuardErr(LReason));
      _Debug.DebugPause;
      Result := _StateResult('dispatched', 'true');
    end));

  AServer.RegisterTool(_Desc('InspectLocals', 'Inspect locals',
    'Reads the enclosing routine''s parameters and local variables at the ' +
    'current stop (like the IDE Locals window) and returns "name = value" ' +
    'lines. Requires STOPPED. Unevaluable names come back as "name = ' +
    '<reason>" instead of being dropped.',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason, LItem: string;
      LArr: TJSONArray;
    begin
      if not TDebugPolicy.DebugGuard(_Debug.DebugReadState, dpStopped, LReason) then
        Exit(_GuardErr(LReason));
      LArr := TJSONArray.Create;
      try
        for LItem in _Debug.DebugInspectLocals do
          LArr.Add(LItem);
        Result := _Res('{"locals":' + LArr.ToJSON + '}');
      finally
        LArr.Free;
      end;
    end));

  AServer.RegisterTool(_Desc('EvaluateExpression', 'Evaluate',
    'Evaluates an expression in the current stopped thread''s scope (like the ' +
    'IDE Evaluate/Watch window) and returns its value. Requires STOPPED. ' +
    'Use it to read variables, fields, and expressions at a breakpoint.',
    _Schema('{"type":"object","properties":{"expression":{"type":"string"}},' +
      '"required":["expression"]}'),
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason, LValue: string;
      LObj: TJSONObject;
    begin
      if not TDebugPolicy.DebugGuard(_Debug.DebugReadState, dpStopped, LReason) then
        Exit(_GuardErr(LReason));
      LObj := TJSONObject.Create;
      try
        if _Debug.DebugEvaluate(_ParamStr(AParams, 'expression'), LValue) then
          LObj.AddPair('value', LValue)
        else
          LObj.AddPair('error', LValue);
        Result := _Res(LObj.ToJSON);
      finally
        LObj.Free;
      end;
    end));

  AServer.RegisterTool(_Desc('GetExceptionInfo', 'Get exception info',
    'When the process is stopped ON AN EXCEPTION, returns the exception''s ' +
    'class name and message (read from ExceptObject in the stopped thread). ' +
    'Requires STOPPED. At a plain breakpoint stop it returns ' +
    '{"note":"not-an-exception-stop"} instead of erroring.',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason, LClass, LMessage, LNote: string;
      LObj: TJSONObject;
    begin
      if not TDebugPolicy.DebugGuard(_Debug.DebugReadState, dpStopped, LReason) then
        Exit(_GuardErr(LReason));
      LObj := TJSONObject.Create;
      try
        if _Debug.DebugGetExceptionInfo(LClass, LMessage, LNote) then
        begin
          LObj.AddPair('class', LClass);
          LObj.AddPair('message', LMessage);
          if LNote <> '' then
            LObj.AddPair('note', LNote);
        end
        else
          LObj.AddPair('note', LNote);
        Result := _Res(LObj.ToJSON);
      finally
        LObj.Free;
      end;
    end));

  AServer.RegisterTool(_Desc('GetCallStack', 'Get call stack',
    'Returns the current thread''s call stack as "header  file:line" frames, ' +
    'top frame first. A frame without source shows the header only. Requires ' +
    'STOPPED. Call SetCurrentThread first to inspect another thread.',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason, LItem: string;
      LArr: TJSONArray;
    begin
      if not TDebugPolicy.DebugGuard(_Debug.DebugReadState, dpStopped, LReason) then
        Exit(_GuardErr(LReason));
      LArr := TJSONArray.Create;
      try
        for LItem in _Debug.DebugGetCallStack do
          LArr.Add(LItem);
        Result := _Res('{"frames":' + LArr.ToJSON + '}');
      finally
        LArr.Free;
      end;
    end));

  AServer.RegisterTool(_Desc('ListThreads', 'List threads',
    'Lists the debugged process'' threads: OS id, state, optional name, ' +
    'current file:line when known, and which one is current. Requires a ' +
    'debug session. Feed a thread''s OS id to SetCurrentThread to switch.',
    _EmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason, LItem: string;
      LArr: TJSONArray;
    begin
      if not TDebugPolicy.DebugGuard(_Debug.DebugReadState, dpSession, LReason) then
        Exit(_GuardErr(LReason));
      LArr := TJSONArray.Create;
      try
        for LItem in _Debug.DebugListThreads do
          LArr.Add(LItem);
        Result := _Res('{"threads":' + LArr.ToJSON + '}');
      finally
        LArr.Free;
      end;
    end));

  AServer.RegisterTool(_Desc('SetCurrentThread', 'Set current thread',
    'Selects the thread with the given OS thread id (from ListThreads) as ' +
    'current, so EvaluateExpression / GetCallStack / InspectLocals target ' +
    'it. Requires a debug session.',
    _Schema('{"type":"object","properties":{"threadId":{"type":"integer"}},' +
      '"required":["threadId"]}'),
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LReason: string;
    begin
      if not TDebugPolicy.DebugGuard(_Debug.DebugReadState, dpSession, LReason) then
        Exit(_GuardErr(LReason));
      Result := _Res('{"applied":' +
        LowerCase(BoolToStr(_Debug.DebugSetCurrentThread(
          Cardinal(_ParamInt(AParams, 'threadId'))), True)) + '}');
    end));
end;

end.
