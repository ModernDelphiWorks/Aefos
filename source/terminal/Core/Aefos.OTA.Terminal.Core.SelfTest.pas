unit Aefos.OTA.Terminal.Core.SelfTest;

/// <summary>
/// L5 self-test protocol: closed command set, request parse, dispatch, response
/// (ESP-068 / ADR-068-01/02/03). RTL + System.JSON only (BR1). Clock-free:
/// run-id is caller-supplied (BR7). No VCL, no ToolsAPI.
/// </summary>

{$SCOPEDENUMS ON}

interface

const
  SELFTEST_LAYER   = 'L5-ide';
  SELFTEST_PACKAGE = 'Aefos.OTA.TerminalSelfTest';

type
  /// <summary>
  /// Closed command set for the L5 self-test channel (ADR-068-01).
  /// Unknown names are rejected by TryParseCommand (BR6).
  /// </summary>
  TSelfTestCommand = (
    stcPing,          { "ping"          — verify the channel is live }
    stcOpenTerminal,  { "open-terminal" — show the terminal dock form }
    stcRunCommand,    { "run-command"   — send text to the focused terminal stdin }
    stcGetState,      { "get-state"     — capture terminal buffer snapshot }
    stcListTabs,      { "list-tabs"     — enumerate open terminal tabs }
    stcGetWindow,     { "get-window"    — return IDE window handle/title/bounds }
    stcClosePanel     { "close-panel"   — hide the terminal dock form }
  );

  /// <summary>Result returned by ISelfTestExecutor.Execute.</summary>
  TSelfTestResult = record
    Succeeded: Boolean;
    Payload: string;
    ErrorMsg: string;
  end;

  /// <summary>
  /// Executor interface: one implementation per runtime context (BR9 / ADR-068-02).
  /// TFakeSelfTestExecutor covers headless tests; TIdeSelfTestExecutor lives in
  /// UI.SelfTestChannel and accesses real OTA/DockForm/TTerminalHost.
  /// </summary>
  ISelfTestExecutor = interface
    ['{A3B5C7D9-E1F2-4A6B-8C0D-2E4F68024680}']
    function Execute(const ACmd: TSelfTestCommand; const AArg: string): TSelfTestResult;
  end;

  /// <summary>Parsed L5 self-test request.</summary>
  TSelfTestRequest = record
    Command: TSelfTestCommand;
    Arg: string;
    RunId: string;
  end;

  /// <summary>
  /// Outcome of a single dispatched command. Consumed by BuildResponseJson to
  /// build the delphi-test/1 envelope.
  /// </summary>
  TSelfTestCommandResult = record
    CommandName: string;
    Succeeded: Boolean;
    Payload: string;
    ErrorMsg: string;
  end;

  /// <summary>
  /// L5 self-test protocol operations: closed-set parse, request parse,
  /// dispatch, and response envelope building. Static-only sealed class.
  /// </summary>
  TSelfTestProtocol = class sealed
  public
    /// <summary>
    /// Map a command-name string to the closed enum.
    /// Returns False for any name outside the seven-item set; never raises (BR6).
    /// </summary>
    class function TryParseCommand(const AName: string;
      out ACmd: TSelfTestCommand): Boolean; static;

    /// <summary>
    /// Parse a JSON request string into ARequest.
    /// Returns False (no exception) on malformed JSON, missing 'command' key, or
    /// unknown command name. Expected shape:
    ///   {"command":"&lt;name&gt;","arg":"&lt;text&gt;","runId":"&lt;id&gt;"}
    /// </summary>
    class function ParseRequest(const AJson: string;
      out ARequest: TSelfTestRequest): Boolean; static;

    /// <summary>
    /// Dispatch ARequest through AExecutor and return a result record.
    /// If AExecutor is nil, returns Ok=False with error "executor not assigned".
    /// </summary>
    class function DispatchRequest(const ARequest: TSelfTestRequest;
      const AExecutor: ISelfTestExecutor): TSelfTestCommandResult; static;

    /// <summary>
    /// Assemble the delphi-test/1 layer:"L5-ide" JSON envelope from a set of
    /// command results. Screenshot artifact path is derived from ARunId (BR7 —
    /// no clock). Uses TestContract.BuildContractJson (BR3 — no second writer).
    /// </summary>
    class function BuildResponseJson(const ARunId: string;
      const AResults: TArray<TSelfTestCommandResult>): string; static;

    /// <summary>
    /// Build a rejection envelope when ParseRequest returns False (malformed
    /// request or unknown command). Produces a single failures[] entry (BR3).
    /// </summary>
    class function BuildRejectionResponseJson(const ARunId, AReason: string): string; static;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  Aefos.OTA.Terminal.Core.TestContract;

function _CommandName(const ACmd: TSelfTestCommand): string;
begin
  case ACmd of
    TSelfTestCommand.stcPing:         Result := 'ping';
    TSelfTestCommand.stcOpenTerminal: Result := 'open-terminal';
    TSelfTestCommand.stcRunCommand:   Result := 'run-command';
    TSelfTestCommand.stcGetState:     Result := 'get-state';
    TSelfTestCommand.stcListTabs:     Result := 'list-tabs';
    TSelfTestCommand.stcGetWindow:    Result := 'get-window';
    TSelfTestCommand.stcClosePanel:   Result := 'close-panel';
  else
    Result := '';
  end;
end;

class function TSelfTestProtocol.TryParseCommand(const AName: string;
  out ACmd: TSelfTestCommand): Boolean;
begin
  Result := True;
  if      AName = 'ping'          then ACmd := TSelfTestCommand.stcPing
  else if AName = 'open-terminal' then ACmd := TSelfTestCommand.stcOpenTerminal
  else if AName = 'run-command'   then ACmd := TSelfTestCommand.stcRunCommand
  else if AName = 'get-state'     then ACmd := TSelfTestCommand.stcGetState
  else if AName = 'list-tabs'     then ACmd := TSelfTestCommand.stcListTabs
  else if AName = 'get-window'    then ACmd := TSelfTestCommand.stcGetWindow
  else if AName = 'close-panel'   then ACmd := TSelfTestCommand.stcClosePanel
  else
  begin
    ACmd   := TSelfTestCommand.stcPing;
    Result := False;
  end;
end;

class function TSelfTestProtocol.ParseRequest(const AJson: string;
  out ARequest: TSelfTestRequest): Boolean;
var
  LRoot: TJSONObject;
  LCmdName: string;
begin
  ARequest := Default(TSelfTestRequest);
  Result := False;
  if AJson.Trim = '' then
    Exit;
  try
    LRoot := TJSONObject.ParseJSONValue(AJson) as TJSONObject;
    if not Assigned(LRoot) then
      Exit;
    try
      if not LRoot.TryGetValue<string>('command', LCmdName) then
        Exit;
      if not TSelfTestProtocol.TryParseCommand(LCmdName, ARequest.Command) then
        Exit;
      LRoot.TryGetValue<string>('arg', ARequest.Arg);
      LRoot.TryGetValue<string>('runId', ARequest.RunId);
      if ARequest.RunId = '' then
        ARequest.RunId := 'default';
      Result := True;
    finally
      LRoot.Free;
    end;
  except
    Result := False;
  end;
end;

class function TSelfTestProtocol.DispatchRequest(const ARequest: TSelfTestRequest;
  const AExecutor: ISelfTestExecutor): TSelfTestCommandResult;
var
  LResult: TSelfTestResult;
begin
  Result.CommandName := _CommandName(ARequest.Command);
  if not Assigned(AExecutor) then
  begin
    Result.Succeeded := False;
    Result.Payload   := '';
    Result.ErrorMsg  := 'executor not assigned';
    Exit;
  end;
  LResult            := AExecutor.Execute(ARequest.Command, ARequest.Arg);
  Result.Succeeded   := LResult.Succeeded;
  Result.Payload     := LResult.Payload;
  Result.ErrorMsg    := LResult.ErrorMsg;
end;

class function TSelfTestProtocol.BuildResponseJson(const ARunId: string;
  const AResults: TArray<TSelfTestCommandResult>): string;
var
  LDoc: TTestContractDoc;
  LItem: TSelfTestCommandResult;
  LFailures: TArray<TTestFailureEntry>;
  LEntry: TTestFailureEntry;
  LFailed, LPassed: Integer;
  LRunId: string;
begin
  LRunId := ARunId;
  if LRunId = '' then
    LRunId := 'default';

  LFailed := 0;
  LPassed := 0;
  SetLength(LFailures, 0);
  for LItem in AResults do
  begin
    if LItem.Succeeded then
      Inc(LPassed)
    else
    begin
      Inc(LFailed);
      LEntry          := Default(TTestFailureEntry);
      LEntry.Id       := LItem.CommandName;
      LEntry.Expected := 'ok';
      LEntry.Actual   := LItem.ErrorMsg;
      LEntry.Evidence := '';
      LFailures       := LFailures + [LEntry];
    end;
  end;

  LDoc.Schema    := DELPHI_TEST_SCHEMA;
  LDoc.Layer     := SELFTEST_LAYER;
  LDoc.Package   := SELFTEST_PACKAGE;
  LDoc.AllPassed := (LFailed = 0);
  // Behavior-fix (deliberate, surgical): Total now derives from ALL parts via
  // TTestSummary.Create (Passed+Failed+Skipped). The old hand-set
  // "Total := LPassed + LFailed" silently dropped Skipped; here Skipped is 0,
  // so the emitted count is unchanged — the fix removes the latent drift.
  LDoc.Summary   := TTestSummary.Create(LPassed, LFailed, 0);
  LDoc.Failures  := LFailures;
  LDoc.Artifacts := ['.test-out/' + LRunId + '/ide-selftest-screenshot.png'];
  LDoc.Mode      := '';
  Result := LDoc.ToJson;
end;

class function TSelfTestProtocol.BuildRejectionResponseJson(const ARunId, AReason: string): string;
var
  LResult: TSelfTestCommandResult;
begin
  LResult.CommandName := 'unknown';
  LResult.Succeeded   := False;
  LResult.Payload     := '';
  LResult.ErrorMsg    := AReason;
  Result := TSelfTestProtocol.BuildResponseJson(ARunId, [LResult]);
end;

end.
