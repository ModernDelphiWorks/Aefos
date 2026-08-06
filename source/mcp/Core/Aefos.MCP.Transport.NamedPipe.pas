unit Aefos.MCP.Transport.NamedPipe;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Windows named-pipe server-side implementation of IMCPTransport
  (ESP-002, Epic 3/5 Demand 1/5; ADR-054; ADR-073).

  Multi-instance design (PIPE_MAX_INSTANCES = 4):
    - Four CreateNamedPipe handles share the same pipe name, allowing up to
      four clients to be connected simultaneously (e.g. this Claude Code
      session + ChatTester subprocess + any other consumer).
    - Each handle runs in its own worker thread (_RunAcceptLoop per instance).
    - Response routing: threadvar GWorkerPipeHandle / GWorkerSendEvent /
      GWorkerSendLockPtr are set before _DispatchFrame so Send, called
      synchronously by the dispatcher on the same worker thread, writes back
      to the correct client handle without a global lock or lookup.
    - Re-anchoring notifications originate on the IDE main thread and must
      reach ALL connected clients; FConnectedClients (protected by
      FConnectedLock) is the broadcast list used in that path.

  Overlapped I/O — unchanged rationale from ADR-073: concurrent Send callers
  (worker response + main-thread notification) would deadlock on a synchronous
  handle because WriteFile and ReadFile share the same serialisation lock.
  Overlapped I/O lets reads and writes proceed independently.

  Stop signals FCancelEvent, cancels all pending IO, closes all handles and
  joins all workers within STOP_TIMEOUT_MS each (BR-7 force-leak on timeout).
}

interface

uses
  // Winapi-scoped units stay dotted on Delphi: not every consumer .dproj config
  // carries the Winapi unit-scope prefix (System.* is safe, Winapi.* is not).
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  Classes,
  SysUtils,
  SyncObjs,
  Generics.Collections,
  Aefos.MCP.Types;

const
  PIPE_MAX_INSTANCES = 4;

type
  TNamedPipeTransport = class(TInterfacedObject, IMCPTransport)
  private
    type
      TPipeInstance = record
        Handle:      THandle;
        WorkerEvent: THandle;
        SendEvent:   THandle;
        SendLock:    TCriticalSection;
      end;

      TConnectedClient = record
        Handle:    THandle;
        SendEvent: THandle;
        SendLock:  TCriticalSection;
      end;

    var
      FInstances:       array[0..PIPE_MAX_INSTANCES - 1] of TPipeInstance;
      FWorkers:         array[0..PIPE_MAX_INSTANCES - 1] of TThread;
      FOnFrame:         TMCPFrameCallback;
      FCancelled:       Boolean;
      FStarted:         Boolean;
      FPipeName:        string;
      FCancelEvent:     THandle;
      FConnectedLock:   TCriticalSection;
      FConnectedClients: TList<TConnectedClient>;

    procedure _InitInstance(const AIdx: Integer);
    procedure _DestroyInstance(const AIdx: Integer);
    procedure _RunAcceptLoop(const AIdx: Integer);
    procedure _DrainPipe(const AHandle, AWorkerEvent: THandle);
    procedure _ProcessAccumulated(var AAccum: TBytes);
    function  _FindLineBreak(const AAccum: TBytes): Integer;
    procedure _DispatchFrame(const AFrame: string);
    function  _ValidatePipeName(const APipeName: string): Boolean;
    procedure _SendToHandle(const AHandle, ASendEvent: THandle;
      const ASendLock: TCriticalSection; const AFrame: string);
    procedure _RegisterClient(const AClient: TConnectedClient);
    procedure _UnregisterClient(const AHandle: THandle);
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Start(const APipeName: string);
    procedure Stop;
    procedure Send(const AFrame: string);
    procedure SetOnFrame(const ACallback: TMCPFrameCallback);
  end;

implementation

{$IF not Declared(GetTickCount64)}
// 10 Seattle's Winapi.Windows does not declare this Vista-era API yet.
// Declared() rather than a CompilerVersion number: it asks the compiler in
// hand whether the symbol exists, instead of encoding a guess about which
// release added it.
function GetTickCount64: UInt64; stdcall; external 'kernel32.dll' name 'GetTickCount64';
{$IFEND}

{$IF not Declared(CancelIoEx)}
// Same story as GetTickCount64: a Vista-era API 10 Seattle's Winapi.Windows
// does not declare. This one cannot degrade - it is what unblocks a pending
// overlapped read on a handle from another thread, so the shutdown path needs
// it to exist at all.
function CancelIoEx(hFile: THandle; lpOverlapped: POverlapped): BOOL; stdcall;
  external 'kernel32.dll' name 'CancelIoEx';
{$IFEND}

// Thread-local routing slot — set by _RunAcceptLoop before every _DispatchFrame
// so Send (called synchronously on the same worker thread by the dispatcher)
// knows which client handle and send-synchronisation objects to use.
threadvar
  GWorkerPipeHandle: THandle;
  GWorkerSendEvent:  THandle;
  GWorkerSendLockPtr: Pointer;  // raw ptr; cast to TCriticalSection on use

const
  PIPE_BUFFER_SIZE = MCP_TOOL_RESULT_BUDGET + 1024;
  STOP_TIMEOUT_MS  = 1000;
  // Upper bound on a single overlapped write. A peer that stops reading must not
  // be able to pin a worker thread forever — that pinned worker was force-leaked
  // on Stop (BR-7) and kept the BPL image referenced, which hung finalization /
  // locked the .bpl on IDE unload+rebuild. On expiry the write is cancelled.
  SEND_TIMEOUT_MS  = 1000;
  PIPE_REJECT_REMOTE_CLIENTS = $00000008;

type
  TPipeWorker = class(TThread)
  private
    FOwner: TNamedPipeTransport;
    FIdx:   Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AOwner: TNamedPipeTransport; const AIdx: Integer);
  end;

{ TPipeWorker }

constructor TPipeWorker.Create(const AOwner: TNamedPipeTransport;
  const AIdx: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  FIdx   := AIdx;
end;

procedure TPipeWorker.Execute;
begin
  try
    FOwner._RunAcceptLoop(FIdx);
  except
  end;
end;

{ TNamedPipeTransport }

constructor TNamedPipeTransport.Create;
var
  LIdx: Integer;
begin
  inherited Create;
  for LIdx := 0 to PIPE_MAX_INSTANCES - 1 do
  begin
    FInstances[LIdx].Handle      := INVALID_HANDLE_VALUE;
    FInstances[LIdx].WorkerEvent := 0;
    FInstances[LIdx].SendEvent   := 0;
    FInstances[LIdx].SendLock    := nil;
    FWorkers[LIdx]               := nil;
  end;
  FCancelEvent     := CreateEvent(nil, True, False, nil);
  FConnectedLock   := TCriticalSection.Create;
  FConnectedClients := TList<TConnectedClient>.Create;
end;

destructor TNamedPipeTransport.Destroy;
begin
  Stop;
  if FCancelEvent <> 0 then
    CloseHandle(FCancelEvent);
  FConnectedClients.Free;
  FConnectedLock.Free;
  inherited;
end;

function TNamedPipeTransport._ValidatePipeName(const APipeName: string): Boolean;
begin
  Result := (APipeName <> '') and
    (Pos(MCP_PIPE_PREFIX, APipeName) = 1);
end;

procedure TNamedPipeTransport.SetOnFrame(const ACallback: TMCPFrameCallback);
begin
  FOnFrame := ACallback;
end;

procedure TNamedPipeTransport._InitInstance(const AIdx: Integer);
begin
  FInstances[AIdx].Handle :=
    // FPC's unqualified CreateNamedPipe is the ANSI overload (PAnsiChar); the
    // wide overload matches this unit's Unicode pipe name (Delphi PChar=PWideChar).
{$IFDEF FPC}
    CreateNamedPipeW(PWideChar(FPipeName),
{$ELSE}
    CreateNamedPipe(PChar(FPipeName),
{$ENDIF}
    PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
    PIPE_TYPE_MESSAGE or PIPE_READMODE_BYTE or PIPE_WAIT or PIPE_REJECT_REMOTE_CLIENTS,
    PIPE_MAX_INSTANCES,
    PIPE_BUFFER_SIZE,
    PIPE_BUFFER_SIZE,
    0,
    nil);
  if FInstances[AIdx].Handle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  FInstances[AIdx].WorkerEvent := CreateEvent(nil, True, False, nil);
  FInstances[AIdx].SendEvent   := CreateEvent(nil, True, False, nil);
  FInstances[AIdx].SendLock    := TCriticalSection.Create;
end;

procedure TNamedPipeTransport._DestroyInstance(const AIdx: Integer);
begin
  if FInstances[AIdx].Handle <> INVALID_HANDLE_VALUE then
  begin
    CancelIoEx(FInstances[AIdx].Handle, nil);
    DisconnectNamedPipe(FInstances[AIdx].Handle);
    CloseHandle(FInstances[AIdx].Handle);
    FInstances[AIdx].Handle := INVALID_HANDLE_VALUE;
  end;
  if FInstances[AIdx].WorkerEvent <> 0 then
  begin
    CloseHandle(FInstances[AIdx].WorkerEvent);
    FInstances[AIdx].WorkerEvent := 0;
  end;
  if FInstances[AIdx].SendEvent <> 0 then
  begin
    CloseHandle(FInstances[AIdx].SendEvent);
    FInstances[AIdx].SendEvent := 0;
  end;
  FreeAndNil(FInstances[AIdx].SendLock);
end;

procedure TNamedPipeTransport.Start(const APipeName: string);
var
  LIdx: Integer;
  LInitialised: Integer;
begin
  if FStarted then
    raise EMCPInternalError.Create('TNamedPipeTransport.Start: already started');
  if not _ValidatePipeName(APipeName) then
    raise EMCPInvalidRequest.Create(
      'TNamedPipeTransport.Start: pipe name must start with ' + MCP_PIPE_PREFIX);
  FPipeName  := APipeName;
  FCancelled := False;
  ResetEvent(FCancelEvent);
  // Make Start atomic: if any _InitInstance fails (e.g. CreateNamedPipe ->
  // ERROR_PIPE_BUSY when the name already has PIPE_MAX_INSTANCES handles), unwind
  // the handles/threads already created so a failed Start leaks nothing and
  // leaves the transport restartable (FStarted stays False). Without this, a
  // partial set leaked pipe instances that themselves kept the name busy, making
  // every subsequent retry fail too.
  LInitialised := 0;
  try
    for LIdx := 0 to PIPE_MAX_INSTANCES - 1 do
    begin
      _InitInstance(LIdx);
      FWorkers[LIdx] := TPipeWorker.Create(Self, LIdx);
      Inc(LInitialised);
    end;
  except
    for LIdx := 0 to LInitialised - 1 do
    begin
      // Workers are created suspended and not yet Started, so Free is safe here.
      FreeAndNil(FWorkers[LIdx]);
      _DestroyInstance(LIdx);
    end;
    raise;
  end;
  FStarted := True;
  for LIdx := 0 to PIPE_MAX_INSTANCES - 1 do
    TPipeWorker(FWorkers[LIdx]).Start;
end;

procedure TNamedPipeTransport.Stop;
var
  LIdx:      Integer;
  LWorker:   TThread;
  LDeadline: UInt64;
  LJoined:   Boolean;
begin
  if not FStarted then
    Exit;
  FCancelled := True;
  SetEvent(FCancelEvent);
  for LIdx := 0 to PIPE_MAX_INSTANCES - 1 do
    _DestroyInstance(LIdx);
  for LIdx := 0 to PIPE_MAX_INSTANCES - 1 do
  begin
    LWorker := FWorkers[LIdx];
    FWorkers[LIdx] := nil;
    if Assigned(LWorker) then
    begin
      // Join with a synchronize pump: the server marshals EVERY frame to the
      // main thread (TThread.Synchronize in the host's marshaller), so a worker
      // mid-dispatch is parked waiting for the main thread — and Stop usually
      // RUNS on the main thread (Options apply / teardown). A blind wait here
      // was a guaranteed deadlock that always expired the timeout and force-
      // leaked a still-running worker.
      LDeadline := GetTickCount64 + STOP_TIMEOUT_MS;
      repeat
        LJoined := WaitForSingleObject(LWorker.Handle, 25) = WAIT_OBJECT_0;
        if (not LJoined) and (TThread.CurrentThread.ThreadID = MainThreadID) then
          CheckSynchronize;
      until LJoined or (GetTickCount64 > LDeadline);
      if LJoined then
        LWorker.Free
      else
        // Force-leak on timeout (BR-7) — and PIN the transport with it: the
        // leaked worker keeps executing against Self through a plain (non-
        // refcounted) FOwner reference, so letting the interface refcount
        // destroy Self here is a use-after-free. Field crash 2026-07-08:
        // EExternalException C0150014 (ntdll) right after the Terminal
        // Options 'Test MCP' restarted the host. Leaking both is the lesser
        // evil and mirrors the BR-7 philosophy (leak > corrupt).
        _AddRef;
    end;
  end;
  FConnectedLock.Enter;
  try
    FConnectedClients.Clear;
  finally
    FConnectedLock.Leave;
  end;
  FStarted := False;
end;

procedure TNamedPipeTransport._RegisterClient(const AClient: TConnectedClient);
begin
  FConnectedLock.Enter;
  try
    FConnectedClients.Add(AClient);
  finally
    FConnectedLock.Leave;
  end;
end;

procedure TNamedPipeTransport._UnregisterClient(const AHandle: THandle);
var
  LIdx: Integer;
begin
  FConnectedLock.Enter;
  try
    for LIdx := FConnectedClients.Count - 1 downto 0 do
      if FConnectedClients[LIdx].Handle = AHandle then
      begin
        FConnectedClients.Delete(LIdx);
        Break;
      end;
  finally
    FConnectedLock.Leave;
  end;
end;

procedure TNamedPipeTransport._SendToHandle(const AHandle, ASendEvent: THandle;
  const ASendLock: TCriticalSection; const AFrame: string);
var
  LBytes:       TBytes;
  LWritten:     DWORD;
  LOverlapped:  TOverlapped;
  LError:       DWORD;
  LWaitHandles: array[0..1] of THandle;
  LTimeout:     DWORD;
begin
  if AHandle = INVALID_HANDLE_VALUE then
    Exit;
  LBytes := TEncoding.UTF8.GetBytes(AFrame + #10);
  // R10: a frame far bigger than the pipe buffer (e.g. a CaptureForm PNG appended as base64,
  // which _ApplyBudget does NOT cap) can take longer than the flat 1s to drain even on a healthy
  // client. Timing out then CancelIoEx-ing mid-write leaves a PARTIAL frame on the wire and
  // desyncs the NDJSON stream (the peer can't reframe). Scale the drain allowance to the frame
  // size (~+4ms/KB), capped so the send lock can never stall too long; teardown is unaffected
  // because FCancelEvent still breaks the wait immediately regardless of LTimeout.
  LTimeout := SEND_TIMEOUT_MS;
  if Length(LBytes) > PIPE_BUFFER_SIZE then
  begin
    Inc(LTimeout, (Length(LBytes) div 1024) * 4);
    if LTimeout > 10000 then
      LTimeout := 10000;
  end;
  ASendLock.Enter;
  try
    if AHandle = INVALID_HANDLE_VALUE then
      Exit;
    FillChar(LOverlapped, SizeOf(LOverlapped), 0);
    LOverlapped.hEvent := ASendEvent;
    ResetEvent(ASendEvent);
    LWritten := 0;
    if WriteFile(AHandle, LBytes[0], Length(LBytes), LWritten, @LOverlapped) then
      Exit;
    LError := GetLastError;
    if LError <> ERROR_IO_PENDING then
      Exit;
    // Wait on the write OR the transport cancel signal, bounded by SEND_TIMEOUT_MS
    // (never an unbounded GetOverlappedResult(..., True)). FCancelEvent is set by
    // Stop, so a teardown can never be blocked here by a non-reading peer. On
    // cancel/timeout, abort the write; then reap the now-settled overlapped op.
    LWaitHandles[0] := ASendEvent;
    LWaitHandles[1] := FCancelEvent;
    if WaitForMultipleObjects(2, @LWaitHandles, False, LTimeout) <> WAIT_OBJECT_0 then
      CancelIoEx(AHandle, @LOverlapped);
    GetOverlappedResult(AHandle, LOverlapped, LWritten, True);
  finally
    ASendLock.Leave;
  end;
end;

procedure TNamedPipeTransport.Send(const AFrame: string);
var
  LHandle:    THandle;
  LEvent:     THandle;
  LLockPtr:   Pointer;
  LClients:   TArray<TConnectedClient>;
  LIdx:       Integer;
begin
  if not FStarted then
    Exit;
  LHandle  := GWorkerPipeHandle;
  LEvent   := GWorkerSendEvent;
  LLockPtr := GWorkerSendLockPtr;
  if (LHandle <> INVALID_HANDLE_VALUE) and (LHandle <> 0) and Assigned(LLockPtr) then
  begin
    // Called from a worker thread (response) — send to that client only.
    _SendToHandle(LHandle, LEvent, TCriticalSection(LLockPtr), AFrame);
  end
  else
  begin
    // Called from the IDE main thread (re-anchoring notifications) — broadcast
    // to every currently connected client.
    FConnectedLock.Enter;
    try
      LClients := FConnectedClients.ToArray;
    finally
      FConnectedLock.Leave;
    end;
    for LIdx := 0 to High(LClients) do
      _SendToHandle(LClients[LIdx].Handle,
        LClients[LIdx].SendEvent,
        LClients[LIdx].SendLock,
        AFrame);
  end;
end;

procedure TNamedPipeTransport._DispatchFrame(const AFrame: string);
var
  LCallback: TMCPFrameCallback;
begin
  LCallback := FOnFrame;
  if Assigned(LCallback) then
  begin
    try
      LCallback(AFrame);
    except
    end;
  end;
end;

function TNamedPipeTransport._FindLineBreak(const AAccum: TBytes): Integer;
var
  LIndex: Integer;
begin
  for LIndex := 0 to Length(AAccum) - 1 do
    if AAccum[LIndex] = 10 then
      Exit(LIndex);
  Result := -1;
end;

procedure TNamedPipeTransport._ProcessAccumulated(var AAccum: TBytes);
var
  LBreakPos:  Integer;
  LLineBytes: TBytes;
begin
  LBreakPos := _FindLineBreak(AAccum);
  while LBreakPos >= 0 do
  begin
    LLineBytes := Copy(AAccum, 0, LBreakPos);
    if (Length(LLineBytes) > 0) and
       (LLineBytes[Length(LLineBytes) - 1] = 13) then
      SetLength(LLineBytes, Length(LLineBytes) - 1);
    AAccum := Copy(AAccum, LBreakPos + 1, Length(AAccum) - LBreakPos - 1);
    if Length(LLineBytes) > 0 then
      _DispatchFrame(TEncoding.UTF8.GetString(LLineBytes));
    LBreakPos := _FindLineBreak(AAccum);
  end;
end;

procedure TNamedPipeTransport._DrainPipe(const AHandle, AWorkerEvent: THandle);
var
  LBuffer:      array[0..PIPE_BUFFER_SIZE - 1] of Byte;
  LBytesRead:   DWORD;
  LAccum:       TBytes;
  LStart:       Integer;
  LOverlapped:  TOverlapped;
  LWaitHandles: array[0..1] of THandle;
  LError:       DWORD;
begin
  SetLength(LAccum, 0);
  while not FCancelled do
  begin
    FillChar(LOverlapped, SizeOf(LOverlapped), 0);
    LOverlapped.hEvent := AWorkerEvent;
    ResetEvent(AWorkerEvent);
    LBytesRead := 0;
    if not ReadFile(AHandle, LBuffer, Length(LBuffer), LBytesRead, @LOverlapped) then
    begin
      LError := GetLastError;
      if LError <> ERROR_IO_PENDING then
        Exit;
      LWaitHandles[0] := AWorkerEvent;
      LWaitHandles[1] := FCancelEvent;
      if WaitForMultipleObjects(2, @LWaitHandles, False, INFINITE) <> WAIT_OBJECT_0 then
      begin
        CancelIoEx(AHandle, @LOverlapped);
        Exit;
      end;
      if not GetOverlappedResult(AHandle, LOverlapped, LBytesRead, False) then
        Exit;
    end;
    if FCancelled then
      Exit;
    if LBytesRead = 0 then
      Continue;
    LStart := Length(LAccum);
    SetLength(LAccum, LStart + Integer(LBytesRead));
    Move(LBuffer[0], LAccum[LStart], LBytesRead);
    _ProcessAccumulated(LAccum);
  end;
end;

procedure TNamedPipeTransport._RunAcceptLoop(const AIdx: Integer);
var
  LHandle:      THandle;
  LOverlapped:  TOverlapped;
  LWaitHandles: array[0..1] of THandle;
  LError, LDummy: DWORD;
  LConnected:   Boolean;
  LClient:      TConnectedClient;
begin
  LHandle := FInstances[AIdx].Handle;
  if LHandle = INVALID_HANDLE_VALUE then
    Exit;

  while not FCancelled do
  begin
    FillChar(LOverlapped, SizeOf(LOverlapped), 0);
    LOverlapped.hEvent := FInstances[AIdx].WorkerEvent;
    ResetEvent(FInstances[AIdx].WorkerEvent);

    LConnected := ConnectNamedPipe(LHandle, @LOverlapped);
    if not LConnected then
    begin
      LError := GetLastError;
      if LError = ERROR_PIPE_CONNECTED then
        LConnected := True
      else if LError = ERROR_IO_PENDING then
      begin
        LWaitHandles[0] := FInstances[AIdx].WorkerEvent;
        LWaitHandles[1] := FCancelEvent;
        if WaitForMultipleObjects(2, @LWaitHandles, False, INFINITE) <> WAIT_OBJECT_0 then
          Exit;
        LDummy := 0;
        LConnected := GetOverlappedResult(LHandle, LOverlapped, LDummy, False);
      end;
    end;

    if FCancelled then
      Exit;

    if not LConnected then
    begin
      // Unrecoverable error on this instance — recreate the handle so the
      // slot keeps listening rather than going silent (fixes the original
      // _RunAcceptLoop Break that left the pipe listed but not accepting).
      CloseHandle(LHandle);
      LHandle :=
{$IFDEF FPC}
        CreateNamedPipeW(PWideChar(FPipeName),
{$ELSE}
        CreateNamedPipe(PChar(FPipeName),
{$ENDIF}
        PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_MESSAGE or PIPE_READMODE_BYTE or PIPE_WAIT or PIPE_REJECT_REMOTE_CLIENTS,
        PIPE_MAX_INSTANCES,
        PIPE_BUFFER_SIZE,
        PIPE_BUFFER_SIZE,
        0,
        nil);
      if LHandle = INVALID_HANDLE_VALUE then
        Exit;
      FInstances[AIdx].Handle := LHandle;
      Continue;
    end;

    // Arm thread-local routing so Send writes to THIS client.
    GWorkerPipeHandle  := LHandle;
    GWorkerSendEvent   := FInstances[AIdx].SendEvent;
    GWorkerSendLockPtr := FInstances[AIdx].SendLock;

    LClient.Handle    := LHandle;
    LClient.SendEvent := FInstances[AIdx].SendEvent;
    LClient.SendLock  := FInstances[AIdx].SendLock;
    _RegisterClient(LClient);

    _DrainPipe(LHandle, FInstances[AIdx].WorkerEvent);

    _UnregisterClient(LHandle);
    GWorkerPipeHandle  := INVALID_HANDLE_VALUE;
    GWorkerSendEvent   := 0;
    GWorkerSendLockPtr := nil;

    DisconnectNamedPipe(LHandle);
  end;
end;

end.
