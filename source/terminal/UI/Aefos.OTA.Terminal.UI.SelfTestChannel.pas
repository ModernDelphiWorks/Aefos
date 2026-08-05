unit Aefos.OTA.Terminal.UI.SelfTestChannel;

/// <summary>
/// L5 in-IDE self-test channel host (ESP-068 / ADR-068-01/02).
///
/// Under AEFOS_OTA_TERMINAL_SELFTEST: opens a loopback named pipe
/// (\\.\pipe\AefosTerminalSelfTest) on a background listener thread,
/// implements ISelfTestExecutor against real OTA/DockForm/TTerminalHost, and
/// writes ide-selftest.json via Core.SelfTest.BuildResponseJson.
///
/// Without the define: the unit exports no types — the class is entirely absent
/// from release/normal builds (BR5). The unit itself remains in the dpk/probe
/// for parity (ADR-068-02 — the define gates the body, not the membership).
/// </summary>

interface

{$I ..\Aefos.OTA.Terminal.inc}

{$IFDEF AEFOS_OTA_TERMINAL_SELFTEST}
type
  /// <summary>
  /// Facade: start/stop the self-test named-pipe listener (BR5 / ADR-068-02).
  /// Whole class compiles only under AEFOS_OTA_TERMINAL_SELFTEST.
  /// Created and torn down by the Wizard under the same define guard.
  /// </summary>
  TIdeSelfTestChannel = class
  private
    FThread: TObject;
    FStopEvent: THandle;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;
{$ENDIF}

implementation

{$IFDEF AEFOS_OTA_TERMINAL_SELFTEST}

uses
  System.Classes,
  System.SysUtils,
  System.StrUtils,
  System.IOUtils,
  Winapi.Windows,
  Vcl.Forms,
  ToolsAPI,
  Aefos.OTA.Terminal.Core.ActionRunner,
  Aefos.OTA.Terminal.Core.SelfTest,
  Aefos.OTA.Terminal.UI.DockForm;

const
  PIPE_NAME     = '\\.\pipe\AefosTerminalSelfTest';
  PIPE_TIMEOUT  = 5000; { ms — connect wait before checking Terminated }
  PIPE_BUF_SIZE = 65536;

{ ---- TIdeSelfTestExecutor ---- }

type
  TIdeSelfTestExecutor = class(TInterfacedObject, ISelfTestExecutor)
  public
    function Execute(const ACmd: TSelfTestCommand; const AArg: string): TSelfTestResult;
  private
    function _ExecutePing: TSelfTestResult;
    function _ExecuteOpenTerminal: TSelfTestResult;
    function _ExecuteRunCommand(const AArg: string): TSelfTestResult;
    function _ExecuteGetState: TSelfTestResult;
    function _ExecuteListTabs: TSelfTestResult;
    function _ExecuteGetWindow: TSelfTestResult;
    function _ExecuteClosePanel: TSelfTestResult;
  end;

function TIdeSelfTestExecutor.Execute(const ACmd: TSelfTestCommand;
  const AArg: string): TSelfTestResult;
begin
  case ACmd of
    TSelfTestCommand.stcPing:         Result := _ExecutePing;
    TSelfTestCommand.stcOpenTerminal: Result := _ExecuteOpenTerminal;
    TSelfTestCommand.stcRunCommand:   Result := _ExecuteRunCommand(AArg);
    TSelfTestCommand.stcGetState:     Result := _ExecuteGetState;
    TSelfTestCommand.stcListTabs:     Result := _ExecuteListTabs;
    TSelfTestCommand.stcGetWindow:    Result := _ExecuteGetWindow;
    TSelfTestCommand.stcClosePanel:   Result := _ExecuteClosePanel;
  else
    Result.Succeeded := False;
    Result.Payload  := '';
    Result.ErrorMsg := 'unhandled command';
  end;
end;

function TIdeSelfTestExecutor._ExecutePing: TSelfTestResult;
begin
  Result.Succeeded := True;
  Result.Payload := '{"alive":true,"selftest":true,"package":"Aefos.OTA.Terminal"}';
  Result.ErrorMsg := '';
end;

function TIdeSelfTestExecutor._ExecuteOpenTerminal: TSelfTestResult;
begin
  try
    TThread.Synchronize(nil, procedure
    begin
      ShowAefosTerminalDockForm;
    end);
    Result.Succeeded := True;
    Result.Payload  := '{"action":"opened"}';
    Result.ErrorMsg := '';
  except
    on E: Exception do
    begin
      Result.Succeeded := False;
      Result.Payload  := '';
      Result.ErrorMsg := E.Message;
    end;
  end;
end;

function TIdeSelfTestExecutor._ExecuteRunCommand(const AArg: string): TSelfTestResult;
var
  LInput: ITerminalInput;
  LOk: Boolean;
  LError: string;
begin
  LOk    := False;
  LError := 'no active terminal';
  LInput := nil;

  TThread.Synchronize(nil, procedure
  begin
    if Assigned(AefosTerminalDockForm) then
      LInput := AefosTerminalDockForm.ActiveTerminalInput;
  end);

  if Assigned(LInput) and LInput.IsActive then
  begin
    try
      LInput.SendInput(AArg + #13);
      LOk    := True;
      LError := '';
    except
      on E: Exception do
        LError := E.Message;
    end;
  end;

  Result.Succeeded := LOk;
  Result.Payload  := IfThen(LOk, '{"command":"' + AArg + '"}', '');
  Result.ErrorMsg := LError;
end;

function TIdeSelfTestExecutor._ExecuteGetState: TSelfTestResult;
var
  LState: string;
  LOk: Boolean;
  LError: string;
begin
  LOk    := False;
  LError := 'no terminal active';
  LState := '';

  TThread.Synchronize(nil, procedure
  begin
    if Assigned(AefosTerminalDockForm) and
       Assigned(AefosTerminalDockForm.FocusedView) and
       Assigned(AefosTerminalDockForm.FocusedView.Buffer) then
    begin
      LState := AefosTerminalDockForm.FocusedView.Buffer.SaveStateJSON;
      LOk    := True;
      LError := '';
    end;
  end);

  Result.Succeeded := LOk;
  Result.Payload  := LState;
  Result.ErrorMsg := LError;
end;

function TIdeSelfTestExecutor._ExecuteListTabs: TSelfTestResult;
var
  LJson: string;
  LOk: Boolean;
  LError: string;
begin
  LOk    := False;
  LError := 'dock form not available';
  LJson  := '';

  TThread.Synchronize(nil, procedure
  var
    LI: Integer;
    LNames: TArray<string>;
  begin
    if Assigned(AefosTerminalDockForm) then
    begin
      SetLength(LNames, AefosTerminalDockForm.pgcTerminals.PageCount);
      for LI := 0 to AefosTerminalDockForm.pgcTerminals.PageCount - 1 do
        LNames[LI] := AefosTerminalDockForm.pgcTerminals.Pages[LI].Caption;
      LJson := '{"count":' + IntToStr(Length(LNames)) + ',"tabs":[';
      for LI := 0 to High(LNames) do
      begin
        if LI > 0 then LJson := LJson + ',';
        LJson := LJson + '"' + LNames[LI] + '"';
      end;
      LJson  := LJson + ']}';
      LOk    := True;
      LError := '';
    end;
  end);

  Result.Succeeded := LOk;
  Result.Payload  := LJson;
  Result.ErrorMsg := LError;
end;

function TIdeSelfTestExecutor._ExecuteGetWindow: TSelfTestResult;
var
  LJson: string;
  LOk: Boolean;
  LError: string;
begin
  LOk    := False;
  LError := 'cannot read window info';
  LJson  := '';

  TThread.Synchronize(nil, procedure
  var
    LHandle: HWND;
    LTitle: string;
    LRect: TRect;
  begin
    try
      LHandle := Application.MainForm.Handle;
      LTitle  := Application.MainForm.Caption;
      LRect   := Application.MainForm.BoundsRect;
      LJson := Format('{"handle":%d,"title":"%s","left":%d,"top":%d,"right":%d,"bottom":%d}',
        [LHandle, LTitle, LRect.Left, LRect.Top, LRect.Right, LRect.Bottom]);
      LOk    := True;
      LError := '';
    except
      on E: Exception do
        LError := E.Message;
    end;
  end);

  Result.Succeeded := LOk;
  Result.Payload  := LJson;
  Result.ErrorMsg := LError;
end;

function TIdeSelfTestExecutor._ExecuteClosePanel: TSelfTestResult;
begin
  try
    TThread.Synchronize(nil, procedure
    begin
      if Assigned(AefosTerminalDockForm) then
        AefosTerminalDockForm.Hide;
    end);
    Result.Succeeded := True;
    Result.Payload  := '{"action":"closed"}';
    Result.ErrorMsg := '';
  except
    on E: Exception do
    begin
      Result.Succeeded := False;
      Result.Payload  := '';
      Result.ErrorMsg := E.Message;
    end;
  end;
end;

{ ---- TIdeSelfTestListenerThread ---- }

type
  TIdeSelfTestListenerThread = class(TThread)
  private
    FExecutor: ISelfTestExecutor;
    FStopEvent: THandle;
    procedure _HandleConnection(const APipe: THandle);
    function _ReadLine(const APipe: THandle; out ALine: string): Boolean;
    procedure _WriteLine(const APipe: THandle; const ALine: string);
    procedure _WriteResultFile(const ARunId, AJson: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const AExecutor: ISelfTestExecutor; const AStopEvent: THandle);
  end;

constructor TIdeSelfTestListenerThread.Create(const AExecutor: ISelfTestExecutor;
  const AStopEvent: THandle);
begin
  inherited Create(True);
  FExecutor   := AExecutor;
  FStopEvent  := AStopEvent;
  FreeOnTerminate := False;
end;

procedure TIdeSelfTestListenerThread.Execute;
var
  LPipe: THandle;
  LOvlp: TOverlapped;
  LHandles: array[0..1] of THandle;
  LWait: DWORD;
  LConnected: Boolean;
  LError: DWORD;
begin
  while not Terminated do
  begin
    LPipe := CreateNamedPipe(
      PIPE_NAME,
      PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
      1,            { max instances }
      PIPE_BUF_SIZE,
      PIPE_BUF_SIZE,
      PIPE_TIMEOUT,
      nil);

    if LPipe = INVALID_HANDLE_VALUE then
    begin
      Sleep(500);
      Continue;
    end;

    try
      ZeroMemory(@LOvlp, SizeOf(LOvlp));
      LOvlp.hEvent := CreateEvent(nil, True, False, nil);
      try
        LConnected := ConnectNamedPipe(LPipe, @LOvlp);
        if not LConnected then
        begin
          LError := GetLastError;
          if LError = ERROR_IO_PENDING then
          begin
            LHandles[0] := LOvlp.hEvent;
            LHandles[1] := FStopEvent;
            LWait := WaitForMultipleObjects(2, @LHandles[0], False, INFINITE);
            LConnected := (LWait = WAIT_OBJECT_0);
          end
          else if LError = ERROR_PIPE_CONNECTED then
            LConnected := True;
        end;

        if LConnected and not Terminated then
          _HandleConnection(LPipe);
      finally
        CloseHandle(LOvlp.hEvent);
      end;
    finally
      DisconnectNamedPipe(LPipe);
      CloseHandle(LPipe);
    end;
  end;
end;

function TIdeSelfTestListenerThread._ReadLine(const APipe: THandle;
  out ALine: string): Boolean;
var
  LByte: Byte;
  LBytes: TBytes;
  LRead: DWORD;
  LAccum: RawByteString;
begin
  ALine  := '';
  LAccum := '';
  Result := False;
  SetLength(LBytes, 1);
  repeat
    if not ReadFile(APipe, LBytes[0], 1, LRead, nil) then
      Exit;
    if LRead = 0 then
      Exit;
    LByte := LBytes[0];
    if LByte = 10 then { LF }
    begin
      Result := True;
      Break;
    end;
    if LByte <> 13 then { strip CR }
      LAccum := LAccum + AnsiChar(LByte);
  until False;
  ALine := UTF8ToString(RawByteString(LAccum));
end;

procedure TIdeSelfTestListenerThread._WriteLine(const APipe: THandle;
  const ALine: string);
var
  LBuf: RawByteString;
  LWritten: DWORD;
begin
  LBuf := UTF8Encode(ALine) + #10;
  WriteFile(APipe, LBuf[1], Length(LBuf), LWritten, nil);
end;

procedure TIdeSelfTestListenerThread._WriteResultFile(const ARunId, AJson: string);
var
  LDir, LPath: string;
begin
  LDir  := TPath.Combine('.test-out', ARunId);
  TDirectory.CreateDirectory(LDir);
  LPath := TPath.Combine(LDir, 'ide-selftest.json');
  TFile.WriteAllText(LPath, AJson, TEncoding.UTF8);
end;

procedure TIdeSelfTestListenerThread._HandleConnection(const APipe: THandle);
var
  LLine: string;
  LReq: TSelfTestRequest;
  LCmdResult: TSelfTestCommandResult;
  LJson: string;
  LRunId: string;
begin
  if not _ReadLine(APipe, LLine) then
    Exit;

  if TSelfTestProtocol.ParseRequest(LLine, LReq) then
  begin
    LRunId    := LReq.RunId;
    LCmdResult := TSelfTestProtocol.DispatchRequest(LReq, FExecutor);
    LJson     := TSelfTestProtocol.BuildResponseJson(LRunId, [LCmdResult]);
  end
  else
  begin
    LRunId := 'default';
    LJson  := TSelfTestProtocol.BuildRejectionResponseJson(LRunId, 'malformed or unknown request');
  end;

  _WriteLine(APipe, LJson);
  _WriteResultFile(LRunId, LJson);
end;

{ ---- TIdeSelfTestChannel (full body) ---- }

constructor TIdeSelfTestChannel.Create;
begin
  inherited;
  FThread    := nil;
  FStopEvent := CreateEvent(nil, True, False, nil);
end;

destructor TIdeSelfTestChannel.Destroy;
begin
  Stop;
  if FStopEvent <> 0 then
    CloseHandle(FStopEvent);
  inherited;
end;

procedure TIdeSelfTestChannel.Start;
var
  LExecutor: ISelfTestExecutor;
  LThread: TIdeSelfTestListenerThread;
begin
  if Assigned(FThread) then
    Exit;
  LExecutor := TIdeSelfTestExecutor.Create;
  LThread   := TIdeSelfTestListenerThread.Create(LExecutor, FStopEvent);
  FThread   := LThread;
  LThread.Start;
end;

procedure TIdeSelfTestChannel.Stop;
var
  LThread: TIdeSelfTestListenerThread;
begin
  if not Assigned(FThread) then
    Exit;
  LThread := TIdeSelfTestListenerThread(FThread);
  LThread.Terminate;
  SetEvent(FStopEvent);
  { Cancel any blocking pipe operation so the thread wakes up. }
  CancelSynchronousIo(LThread.Handle);
  LThread.WaitFor;
  FreeAndNil(FThread);
  ResetEvent(FStopEvent);
end;

{$ENDIF AEFOS_OTA_TERMINAL_SELFTEST}

end.
