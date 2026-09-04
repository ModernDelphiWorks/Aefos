unit Aefos.MCP.Transport.Http;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  In-process HTTP server-side transport implementing IMCPTransport, so the local
  CLI (Claude Code) connects DIRECTLY via an mcpServers entry "aefos" of
  type "http" and url "http://127.0.0.1:<port>/mcp" — with NO relay executable
  and NO bridge script.

  RTL-ONLY by design (lives in MCP.Core): uses raw Winapi.WinSock2, exactly like
  Aefos.MCP.Transport.NamedPipe uses raw Winapi.Windows. No Indy, no Vcl. —
  preserves the package's "requires rtl only" invariant.

  Protocol — a pragmatic subset of MCP "Streamable HTTP" (2025-06-18):
    - POST <any path>: the body is exactly one JSON-RPC message. OnFrame runs
      SYNCHRONOUSLY on the server thread; the response the server emits via Send
      (same thread, see GResponse) is returned as application/json. A JSON-RPC
      notification (no response emitted) yields 202 Accepted. One request per
      connection (Connection: close).
    - GET / other methods: 405. A server-initiated SSE stream (server->client
      notifications such as re-anchoring) is NOT implemented in this version, so
      those notifications are dropped; request/response tool calls are unaffected.

  Concurrency: ONE server thread accepts and serves a single connection at a time
  (the local CLI issues requests sequentially). Binds 127.0.0.1 only (never
  off-box).

  Transport contract: IMCPTransport.Start(APipeName) carries the decimal TCP PORT
  for this transport (the named-pipe transport uses the same parameter for the
  pipe name). The caller picks a free port and builds the CLI config URL with the
  same port. Raises on an invalid/unbindable port (mirrors CreateNamedPipe
  failing in the pipe transport).
}

interface

uses
  SysUtils,
  // Winapi-scoped units stay dotted on Delphi: not every consumer .dproj config
  // carries the Winapi unit-scope prefix (System.* is safe, Winapi.* is not).
{$IFDEF FPC}
  Windows,
  WinSock2,
{$ELSE}
  Winapi.Windows,   // TRTLCriticalSection / THandle / event + wait APIs
  Winapi.WinSock2,
{$ENDIF}
  Aefos.MCP.Types;

const
  // Concurrent connections served at once. The named-pipe transport next door
  // publishes four instances for the same reason and names the case in its own
  // header: more than one consumer at a time is normal, not exotic. Measured
  // here too -- Copilot opens a second session while the first is still open.
  // Declared here because the connection table is a field of the class below.
  MAX_CONNS = 8;

type
  THttpTransport = class(TInterfacedObject, IMCPTransport)
  private
    FThread: TObject;            // TServerThread; opaque to the interface section
    FListen: TSocket;
    // One slot per connection being served. The accept loop no longer serves a
    // connection itself: a client that opens a socket and holds it idle used to
    // own the whole server until its receive timeout expired, which is what a
    // tool call that 'takes forever' looks like from the chat.
    FConns: array[0..MAX_CONNS - 1] of TObject;   // TConnThread
    FConnLock: TRTLCriticalSection;
    // Manual-reset, signalled by Stop. Every wait in this unit watches it, so
    // shutdown is an event rather than a socket close somebody hopes will make
    // a blocked call return. Same contract the named-pipe transport uses.
    FCancelEvent: THandle;
    FCancelled: Boolean;
    FWsaUp: Boolean;
    FOnFrame: TMCPFrameCallback;
    procedure _Run;
    procedure _Adopt(ASock: TSocket);
    procedure _ReapFinished;
    procedure _CloseLiveConns;
    function _JoinAndFree(AThread: TObject; ADeadline: UInt64): Boolean;
    procedure _HandleConn(ASock: TSocket);
    function _ReadRequest(ASock: TSocket; out AMethod, ABody: string): Boolean;
    procedure _SendAll(ASock: TSocket; const ABytes: TBytes);
    procedure _SendJson(ASock: TSocket; const AStatus, ABody: string);
    procedure _SendStatus(ASock: TSocket; const AStatus: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start(const APipeName: string);
    procedure Stop;
    procedure Send(const AFrame: string);
    procedure SetOnFrame(const ACallback: TMCPFrameCallback);
    // Picks an ephemeral free TCP port on 127.0.0.1 (bind :0 -> read -> close).
    // The caller passes the result to Start and builds the CLI URL with it.
    // Returns 0 on failure.
    class function FindFreePort: Integer;
  end;

implementation

uses
  Classes;   // TThread / CheckSynchronize; the Windows APIs come in with the
             // interface uses, where the class fields already need them.

const
  RECV_TIMEOUT_MS = 15000;       // drop a connection that stalls mid-request
  LOCALHOST_NET   = $0100007F;   // 127.0.0.1 already in network byte order
  // Ceiling on the shutdown join. Past it a worker is left running rather than
  // waited on forever, and the transport is pinned so it cannot be destroyed
  // under that worker (the pipe transport paid for that lesson in the field).
  STOP_TIMEOUT_MS = 5000;

threadvar
  // Response collector for the server thread. _HandleConn sets it around the
  // synchronous FOnFrame dispatch; Send (called on the SAME thread by the
  // server's _EmitResult/_EmitError) appends the response frame here.
  GResponse: TStringBuilder;

type
  TServerThread = class(TThread)
  private
    FOwner: THttpTransport;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: THttpTransport);
  end;

  // One accepted connection, served to completion and then closed. Separate
  // from the accept loop on purpose: serving inline made one idle client able
  // to hold every other request behind it.
  TConnThread = class(TThread)
  private
    FOwner: THttpTransport;
    FSock: TSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: THttpTransport; ASock: TSocket);
    // Read by Stop to break a receive that is still waiting on a peer.
    property Sock: TSocket read FSock;
  end;

constructor TServerThread.Create(AOwner: THttpTransport);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TServerThread.Execute;
begin
  FOwner._Run;
end;

constructor TConnThread.Create(AOwner: THttpTransport; ASock: TSocket);
begin
  FOwner := AOwner;
  FSock := ASock;
  inherited Create(False);
end;

procedure TConnThread.Execute;
begin
  try
    FOwner._HandleConn(FSock);
  except
    // A failed request costs its own connection and nothing else. Letting it
    // out would take the socket down without closing it, which is how the
    // CLOSE_WAIT sockets in the field report were left behind.
  end;
  shutdown(FSock, SD_BOTH);
  closesocket(FSock);
  FSock := INVALID_SOCKET;
end;

{ helpers }

// Index of the start of the CRLFCRLF header terminator, or -1 if not yet present.
function _FindHeaderEnd(const ABuf: TBytes): Integer;
var
  LIdx: Integer;
begin
  Result := -1;
  for LIdx := 0 to Length(ABuf) - 4 do
    if (ABuf[LIdx] = 13) and (ABuf[LIdx + 1] = 10) and
       (ABuf[LIdx + 2] = 13) and (ABuf[LIdx + 3] = 10) then
      Exit(LIdx);
end;

// The text from AStart up to (not including) the next CR/LF.
function _LineValue(const AText: string; AStart: Integer): string;
var
  LEnd: Integer;
begin
  LEnd := AStart;
  while (LEnd <= Length(AText)) and (AText[LEnd] <> #13) and (AText[LEnd] <> #10) do
    Inc(LEnd);
  Result := Copy(AText, AStart, LEnd - AStart);
end;

{ THttpTransport }

constructor THttpTransport.Create;
begin
  inherited Create;
  InitializeCriticalSection(FConnLock);
  FListen := INVALID_SOCKET;
end;

destructor THttpTransport.Destroy;
begin
  Stop;
  DeleteCriticalSection(FConnLock);
  inherited;
end;

procedure THttpTransport.SetOnFrame(const ACallback: TMCPFrameCallback);
begin
  FOnFrame := ACallback;
end;

procedure THttpTransport.Start(const APipeName: string);
var
  LWsa: TWSAData;
  LPort: Integer;
  LAddr: TSockAddrIn;
  LOpt: Integer;
begin
  LPort := StrToIntDef(APipeName, 0);
  if (LPort <= 0) or (LPort > 65535) then
    raise Exception.CreateFmt('HTTP transport: invalid port "%s"', [APipeName]);

  if WSAStartup($0202, LWsa) <> 0 then
    raise Exception.Create('HTTP transport: WSAStartup failed');
  FWsaUp := True;

  FListen := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if FListen = INVALID_SOCKET then
    raise Exception.Create('HTTP transport: socket() failed');

  LOpt := 1;
  setsockopt(FListen, SOL_SOCKET, SO_REUSEADDR, PAnsiChar(@LOpt), SizeOf(LOpt));

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port := htons(Word(LPort));
  LAddr.sin_addr.S_addr := LOCALHOST_NET;   // bind 127.0.0.1 only
  if bind(FListen, PSockAddr(@LAddr)^, SizeOf(LAddr)) = SOCKET_ERROR then
  begin
    closesocket(FListen);
    FListen := INVALID_SOCKET;
    raise Exception.CreateFmt(
      'HTTP transport: bind 127.0.0.1:%d failed', [LPort]);
  end;
  if listen(FListen, SOMAXCONN) = SOCKET_ERROR then
  begin
    closesocket(FListen);
    FListen := INVALID_SOCKET;
    raise Exception.Create('HTTP transport: listen() failed');
  end;

  FCancelled := False;
  // Manual-reset: once shutdown is signalled it STAYS signalled, so a wait that
  // starts after the signal returns immediately instead of missing it.
  FCancelEvent := CreateEvent(nil, True, False, nil);
  if FCancelEvent = 0 then
  begin
    closesocket(FListen);
    FListen := INVALID_SOCKET;
    raise Exception.Create('HTTP transport: CreateEvent failed');
  end;
  FThread := TServerThread.Create(Self);
end;

procedure THttpTransport.Stop;
var
  LThread: TObject;
  LDeadline: UInt64;
  LIdx: Integer;
  LLeaked: Boolean;
begin
  if FCancelled and (FThread = nil) then
    Exit;                                  // idempotent: Destroy calls this too
  FCancelled := True;
  if FCancelEvent <> 0 then
    SetEvent(FCancelEvent);
  if FListen <> INVALID_SOCKET then
  begin
    closesocket(FListen);
    FListen := INVALID_SOCKET;
  end;
  // Break the receives before waiting on the threads that are sitting in them.
  _CloseLiveConns;

  LDeadline := GetTickCount64 + STOP_TIMEOUT_MS;
  LLeaked := False;

  LThread := FThread;
  FThread := nil;
  if Assigned(LThread) then
    if not _JoinAndFree(LThread, LDeadline) then
      LLeaked := True;

  EnterCriticalSection(FConnLock);
  try
    for LIdx := 0 to MAX_CONNS - 1 do
      if Assigned(FConns[LIdx]) then
      begin
        if _JoinAndFree(FConns[LIdx], LDeadline) then
          FConns[LIdx] := nil
        else
          LLeaked := True;
      end;
  finally
    LeaveCriticalSection(FConnLock);
  end;

  if LLeaked then
    // A worker outlived the ceiling. It still runs against Self through a plain
    // field, so letting the interface refcount destroy this object now would be
    // a use-after-free -- the named-pipe transport took that crash in the field
    // in 2026-07-08 and pins itself for the same reason. An IDE that closes with
    // a leaked thread beats an IDE that never closes, and beats an AV.
    _AddRef
  else if FCancelEvent <> 0 then
  begin
    CloseHandle(FCancelEvent);
    FCancelEvent := 0;
  end;

  if FWsaUp and (not LLeaked) then
  begin
    WSACleanup;
    FWsaUp := False;
  end;
end;

class function THttpTransport.FindFreePort: Integer;
var
  LWsa: TWSAData;
  LSock: TSocket;
  LAddr: TSockAddrIn;
  LLen: Integer;
begin
  Result := 0;
  if WSAStartup($0202, LWsa) <> 0 then
    Exit;
  try
    LSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if LSock = INVALID_SOCKET then
      Exit;
    try
      FillChar(LAddr, SizeOf(LAddr), 0);
      LAddr.sin_family := AF_INET;
      LAddr.sin_port := 0;                   // OS assigns an ephemeral port
      LAddr.sin_addr.S_addr := LOCALHOST_NET;
      if bind(LSock, PSockAddr(@LAddr)^, SizeOf(LAddr)) = SOCKET_ERROR then
        Exit;
      LLen := SizeOf(LAddr);
      if getsockname(LSock, PSockAddr(@LAddr)^, LLen) = SOCKET_ERROR then
        Exit;
      Result := ntohs(LAddr.sin_port);
    finally
      closesocket(LSock);
    end;
  finally
    WSACleanup;
  end;
end;

procedure THttpTransport._Run;
var
  LSock: TSocket;
  LAcceptEvent: TWSAEvent;
  LEvents: array[0..1] of TWSAEvent;
  LWait: DWORD;
begin
  // Nothing here blocks in a way Stop cannot break. accept() used to block
  // outright, so shutdown had to close the listening socket underneath it and
  // hope the call returned; now the socket reports readiness through an event
  // and the loop waits on that event AND the cancel event together. Signalling
  // cancel is enough to end the loop, immediately and from any state.
  LAcceptEvent := WSACreateEvent;
  if LAcceptEvent = WSA_INVALID_EVENT then
    Exit;
  try
    if WSAEventSelect(FListen, LAcceptEvent, FD_ACCEPT) = SOCKET_ERROR then
      Exit;
    LEvents[0] := LAcceptEvent;
    LEvents[1] := TWSAEvent(FCancelEvent);
    while not FCancelled do
    begin
      // The timeout is a belt for a signal that never arrives, not the
      // mechanism: cancel wakes this the moment it is set.
      LWait := WSAWaitForMultipleEvents(2, @LEvents[0], False, 500, False);
      if FCancelled then
        Break;
      if LWait = WSA_WAIT_EVENT_0 + 1 then
        Break;                       // cancel
      // Reset FIRST, then accept until the queue is empty -- and accept on EVERY
      // wake, including the timeout. FD_ACCEPT is edge-triggered and only fires
      // again for a NEW connection, so resetting after a drain that stopped one
      // accept too early strands that client forever: the event it needed has
      // already been consumed and no other is coming. Trying the accept even on
      // a plain timeout makes that unmissable rather than merely unlikely.
      if LWait = WSA_WAIT_EVENT_0 then
        WSAResetEvent(LAcceptEvent);
      repeat
        LSock := accept(FListen, nil, nil);
        if LSock = INVALID_SOCKET then
          Break;
        if FCancelled then
        begin
          closesocket(LSock);
          Break;
        end;
        _Adopt(LSock);
      until False;
    end;
  finally
    WSACloseEvent(LAcceptEvent);
  end;
end;

// Hands one accepted socket to its own thread. The socket inherits non-blocking
// mode from the event-selected listener, so it is put back to blocking first --
// the request reader is written for blocking reads and a non-blocking recv would
// return WSAEWOULDBLOCK and be read as 'peer closed'.
procedure THttpTransport._Adopt(ASock: TSocket);
var
  LTimeout: Cardinal;
  LMode: Cardinal;
  LIdx: Integer;
  LPlaced: Boolean;
begin
  WSAEventSelect(ASock, 0, 0);
  LMode := 0;
  ioctlsocket(ASock, FIONBIO, LMode);
  LTimeout := RECV_TIMEOUT_MS;
  setsockopt(ASock, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@LTimeout),
    SizeOf(LTimeout));
  LPlaced := False;
  EnterCriticalSection(FConnLock);
  try
    _ReapFinished;
    for LIdx := 0 to MAX_CONNS - 1 do
      if FConns[LIdx] = nil then
      begin
        FConns[LIdx] := TConnThread.Create(Self, ASock);
        LPlaced := True;
        Break;
      end;
  finally
    LeaveCriticalSection(FConnLock);
  end;
  // Every slot busy: refuse THIS connection rather than queue it behind the
  // others. A refused socket is a client that retries; a queued one is the
  // stall this whole change exists to remove.
  if not LPlaced then
  begin
    _SendStatus(ASock, '503 Service Unavailable');
    shutdown(ASock, SD_BOTH);
    closesocket(ASock);
  end;
end;

// Frees the threads that already finished. Caller holds FConnLock.
procedure THttpTransport._ReapFinished;
var
  LIdx: Integer;
begin
  for LIdx := 0 to MAX_CONNS - 1 do
    if Assigned(FConns[LIdx]) and TThread(FConns[LIdx]).Finished then
    begin
      TThread(FConns[LIdx]).Free;
      FConns[LIdx] := nil;
    end;
end;

// Breaks any receive still waiting on a peer, so its thread can finish.
procedure THttpTransport._CloseLiveConns;
var
  LIdx: Integer;
  LSock: TSocket;
begin
  EnterCriticalSection(FConnLock);
  try
    for LIdx := 0 to MAX_CONNS - 1 do
      if Assigned(FConns[LIdx]) then
      begin
        LSock := TConnThread(FConns[LIdx]).Sock;
        if LSock <> INVALID_SOCKET then
        begin
          // shutdown() first: closesocket alone does not reliably wake a recv
          // that is already parked, and waiting out RECV_TIMEOUT_MS instead is
          // fifteen seconds of an IDE that will not close.
          shutdown(LSock, SD_BOTH);
          closesocket(LSock);
        end;
      end;
  finally
    LeaveCriticalSection(FConnLock);
  end;
end;

// Joins one thread, pumping Synchronize while it waits, and frees it. False
// when the deadline passed with the thread still running -- see Stop for what
// that costs and why it is still better than waiting forever.
function THttpTransport._JoinAndFree(AThread: TObject; ADeadline: UInt64): Boolean;
var
  LThread: TThread;
begin
  LThread := TThread(AThread);
  Result := False;
  repeat
    Result := WaitForSingleObject(LThread.Handle, 25) = WAIT_OBJECT_0;
    // Every frame is marshalled to the main thread with TThread.Synchronize, so
    // a thread mid-dispatch is parked waiting for exactly the thread that
    // usually calls Stop. Waiting without pumping is a guaranteed deadlock.
    if (not Result) and (TThread.CurrentThread.ThreadID = MainThreadID) then
      CheckSynchronize;
  until Result or (GetTickCount64 > ADeadline);
  if Result then
    LThread.Free;
end;

procedure THttpTransport._HandleConn(ASock: TSocket);
var
  LMethod, LBody, LResp: string;
  LSb: TStringBuilder;
begin
  if not _ReadRequest(ASock, LMethod, LBody) then
    Exit;
  if not SameText(LMethod, 'POST') then
  begin
    _SendStatus(ASock, '405 Method Not Allowed');
    Exit;
  end;
  if Trim(LBody) = '' then
  begin
    _SendStatus(ASock, '400 Bad Request');
    Exit;
  end;

  // Dispatch synchronously and capture whatever the server emits via Send.
  // The server marshals OTA work to the IDE main thread internally, so Send is
  // still invoked on THIS thread.
  LSb := TStringBuilder.Create;
  try
    GResponse := LSb;
    try
      if Assigned(FOnFrame) then
        FOnFrame(LBody);
    finally
      GResponse := nil;
    end;
    LResp := LSb.ToString;
  finally
    LSb.Free;
  end;

  if LResp <> '' then
    _SendJson(ASock, '200 OK', LResp)
  else
    _SendStatus(ASock, '202 Accepted');   // JSON-RPC notification, no response
end;

function THttpTransport._ReadRequest(ASock: TSocket;
  out AMethod, ABody: string): Boolean;
var
  LBuf: TBytes;
  LChunk: array[0..4095] of Byte;
  LRecv, LLen, LHdrEnd, LContentLen, LBodyHave, LSpace, LIdx: Integer;
  LHeaders, LLower: string;
begin
  Result := False;
  AMethod := '';
  ABody := '';
  SetLength(LBuf, 0);

  // 1) accumulate until the header terminator (CRLFCRLF) is present.
  repeat
    LRecv := recv(ASock, LChunk[0], SizeOf(LChunk), 0);
    if LRecv <= 0 then
      Exit;   // peer closed, timeout, or error
    LLen := Length(LBuf);
    SetLength(LBuf, LLen + LRecv);
    Move(LChunk[0], LBuf[LLen], LRecv);
    LHdrEnd := _FindHeaderEnd(LBuf);
  until LHdrEnd >= 0;

  LHeaders := TEncoding.ASCII.GetString(LBuf, 0, LHdrEnd);

  // method = first token of the request line
  LSpace := Pos(' ', LHeaders);
  if LSpace > 0 then
    AMethod := Copy(LHeaders, 1, LSpace - 1);

  // Content-Length (case-insensitive); positions match since lowering ASCII
  // keeps lengths identical.
  LContentLen := 0;
  LLower := LowerCase(LHeaders);
  LIdx := Pos('content-length:', LLower);
  if LIdx > 0 then
    LContentLen := StrToIntDef(
      Trim(_LineValue(LHeaders, LIdx + Length('content-length:'))), 0);

  // 2) read the remaining body bytes (body starts 4 bytes past LHdrEnd).
  LBodyHave := Length(LBuf) - (LHdrEnd + 4);
  while LBodyHave < LContentLen do
  begin
    LRecv := recv(ASock, LChunk[0], SizeOf(LChunk), 0);
    if LRecv <= 0 then
      Exit;
    LLen := Length(LBuf);
    SetLength(LBuf, LLen + LRecv);
    Move(LChunk[0], LBuf[LLen], LRecv);
    LBodyHave := Length(LBuf) - (LHdrEnd + 4);
  end;

  if LContentLen > 0 then
    ABody := TEncoding.UTF8.GetString(LBuf, LHdrEnd + 4, LContentLen);
  Result := True;
end;

procedure THttpTransport._SendAll(ASock: TSocket; const ABytes: TBytes);
var
  LOff, LSent: Integer;
begin
  LOff := 0;
  while LOff < Length(ABytes) do
  begin
    // Must be unit-qualified to beat the class's own Send method; the unit name
    // differs by compiler (Winapi.WinSock2 on Delphi vs WinSock2 on FPC).
{$IFDEF FPC}
    LSent := WinSock2.send(ASock, ABytes[LOff], Length(ABytes) - LOff, 0);
{$ELSE}
    LSent := Winapi.WinSock2.send(ASock, ABytes[LOff], Length(ABytes) - LOff, 0);
{$ENDIF}
    if LSent <= 0 then
      Exit;   // peer closed or error
    Inc(LOff, LSent);
  end;
end;

procedure THttpTransport._SendJson(ASock: TSocket; const AStatus, ABody: string);
var
  LBodyBytes: TBytes;
  LHeader: string;
begin
  LBodyBytes := TEncoding.UTF8.GetBytes(ABody);
  LHeader :=
    'HTTP/1.1 ' + AStatus + #13#10 +
    'Content-Type: application/json; charset=utf-8'#13#10 +
    'Content-Length: ' + IntToStr(Length(LBodyBytes)) + #13#10 +
    'Connection: close'#13#10#13#10;
  _SendAll(ASock, TEncoding.ASCII.GetBytes(LHeader));
  _SendAll(ASock, LBodyBytes);
end;

procedure THttpTransport._SendStatus(ASock: TSocket; const AStatus: string);
var
  LHeader: string;
begin
  LHeader :=
    'HTTP/1.1 ' + AStatus + #13#10 +
    'Content-Length: 0'#13#10 +
    'Connection: close'#13#10#13#10;
  _SendAll(ASock, TEncoding.ASCII.GetBytes(LHeader));
end;

procedure THttpTransport.Send(const AFrame: string);
begin
  // Synchronous response path: append to the collector for the server thread
  // currently inside FOnFrame. A nil collector means a server-initiated
  // notification with no HTTP request to answer — dropped (no SSE in this
  // version).
  if Assigned(GResponse) then
    GResponse.Append(AFrame);
end;

end.
