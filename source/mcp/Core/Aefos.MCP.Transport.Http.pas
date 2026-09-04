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
  // `ioctlsocket` declares `cmd: Longint`, and Winsock's FIONBIO is $8004667E
  // -- one bit past what a signed 32-bit value holds. The packages compile with
  // {$RANGECHECKS ON} (see Aefos.MCP.Core.dpk), so passing the constant did not
  // merely warn at compile time (W1012, which was in every build log and read
  // as noise): it RAISED ERangeError on the accept thread. Every accepted
  // connection died in _Adopt before it was served, the loop went with it, and
  // from the chat the whole thing looked like 'HTTP is slow' -- it was never
  // answering at all. Measured in the field by the trace, then reproduced
  // headless by compiling the probe with -$R+.
  //
  // The same bits written as the signed value they are, so nothing is
  // converted and nothing is checked. Derived from FIONBIO rather than typed
  // out, so it cannot drift from what Winsock declares.
  FIONBIO_CMD = Longint(Int64(FIONBIO) - Int64($100000000));

threadvar
  // Response collector for the server thread. _HandleConn sets it around the
  // synchronous FOnFrame dispatch; Send (called on the SAME thread by the
  // server's _EmitResult/_EmitError) appends the response frame here.
  GResponse: TStringBuilder;
  // Which connection this thread is serving, so every line it writes names the
  // same request. Set by TConnThread.Execute; zero on the accept loop, which
  // serves none.
  GConnId: Integer;

var
  // --- the trace ---------------------------------------------------------
  // A call that is SLOW and a call that is QUEUED look identical from the
  // chat, and this transport has already been declared dead once when it was
  // only late. So it says what it did and when: one line per step, appended to
  // %APPDATA%\Aefos\aefos-http-trace.log, in the shape the teardown and
  // session-save traces next door already use.
  //
  // Times are microseconds from a QueryPerformanceCounter read when the unit
  // loaded -- monotonic, so a clock adjustment can neither invent nor hide a
  // delay, and integer, so a locale that writes decimals with a comma cannot
  // make two logs disagree. The wall-clock stamp is for lining a line up with
  // what the developer saw on screen, not for measuring.
  //
  // Off with AEFOS_HTTP_TRACE=0, on otherwise: one open-append-close per step
  // costs a few hundred microseconds against a first call measured in seconds,
  // and a diagnostic nobody remembered to switch on measures nothing.
  GTraceLock: TRTLCriticalSection;
  GTraceState: Integer;     // -1 not asked yet, 0 off, 1 on
  GTracePath: string;
  GTraceBase: Int64;        // QPC at unit load
  GTraceFreq: Int64;        // 0 when the counter is unavailable
  GConnSeq: Integer;        // hands each accepted connection its number

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
    FId: Integer;           // this connection's number in the trace
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: THttpTransport; ASock: TSocket; AId: Integer);
    // Read by Stop to break a receive that is still waiting on a peer.
    property Sock: TSocket read FSock;
  end;

{ the trace }

// Microseconds since this unit loaded. Zero when the platform has no
// performance counter, which makes every delta zero -- a trace that says
// nothing rather than a trace that says something false.
function _TraceUs: Int64;
var
  LNow: Int64;
begin
  Result := 0;
  if GTraceFreq = 0 then
    Exit;
  if not QueryPerformanceCounter(LNow) then
    Exit;
  Result := ((LNow - GTraceBase) * 1000000) div GTraceFreq;
end;

// Whether to write at all. Asked once and remembered: two threads racing here
// reach the same answer, so the race is not worth a lock.
function _TraceEnabled: Boolean;
var
  LFlag: string;
begin
  if GTraceState < 0 then
  begin
    LFlag := Trim(SysUtils.GetEnvironmentVariable('AEFOS_HTTP_TRACE'));
    if (LFlag = '0') or SameText(LFlag, 'off') then
      GTraceState := 0
    else
      GTraceState := 1;
  end;
  Result := GTraceState = 1;
end;

// One line, appended. Every thread in this unit calls it, so the whole
// open-append-close is inside the lock: sharing the handle instead would
// interleave two half-written lines and the log would have to be believed
// rather than read.
//
// It never raises. A diagnostic that can take the transport down with it is
// worse than no diagnostic -- the same contract SessionSaveTrace states next
// door.
procedure _Trace(const AStep, ADetail: string);
var
  LDir: string;
  LLine: string;
  LBytes: TBytes;
  LMode: Word;
  LStream: TFileStream;
begin
  if not _TraceEnabled then
    Exit;
  EnterCriticalSection(GTraceLock);
  try
    try
      if GTracePath = '' then
      begin
        LDir := SysUtils.GetEnvironmentVariable('APPDATA');
        if LDir = '' then
          Exit;
        LDir := IncludeTrailingPathDelimiter(LDir) + 'Aefos';
        if not DirectoryExists(LDir) then
          ForceDirectories(LDir);
        GTracePath := IncludeTrailingPathDelimiter(LDir) + 'aefos-http-trace.log';
      end;
      LLine := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now) +
        Format(' up=%d t=%d c=%d %s %s',
          [_TraceUs, GetCurrentThreadId, GConnId, AStep, ADetail]) + sLineBreak;
      LBytes := TEncoding.UTF8.GetBytes(LLine);
      if FileExists(GTracePath) then
        LMode := fmOpenWrite or fmShareDenyWrite
      else
        LMode := fmCreate or fmShareDenyWrite;
      LStream := TFileStream.Create(GTracePath, LMode);
      try
        LStream.Seek(0, soEnd);
        LStream.WriteBuffer(LBytes[0], Length(LBytes));
      finally
        LStream.Free;
      end;
    except
      // Swallowed on purpose -- see above.
    end;
  finally
    LeaveCriticalSection(GTraceLock);
  end;
end;

// The value of one string field of a JSON object, read by hand.
//
// Not a parser: the trace needs to NAME the call that was slow, and pulling
// two fields out of a frame the server is about to parse properly costs less
// than carrying a JSON dependency into a transport that is RTL-only by design.
// A field it cannot find is an empty string, never a guess.
function _JsonField(const ABody, AName: string): string;
var
  LAt, LStart, LEnd: Integer;
begin
  Result := '';
  LAt := Pos('"' + AName + '"', ABody);
  if LAt = 0 then
    Exit;
  LStart := LAt + Length(AName) + 2;
  while (LStart <= Length(ABody)) and (ABody[LStart] <> '"') and
        (ABody[LStart] <> ',') and (ABody[LStart] <> '}') do
    Inc(LStart);
  if (LStart > Length(ABody)) or (ABody[LStart] <> '"') then
    Exit;
  Inc(LStart);
  LEnd := LStart;
  while (LEnd <= Length(ABody)) and (ABody[LEnd] <> '"') do
    Inc(LEnd);
  Result := Copy(ABody, LStart, LEnd - LStart);
end;

// What a trace line should call this request: the JSON-RPC method, and for a
// tools/call the tool's own name, which is the part a reader is looking for.
function _FramePeek(const ABody: string): string;
var
  LMethod, LName: string;
begin
  LMethod := _JsonField(ABody, 'method');
  LName := _JsonField(ABody, 'name');
  if LMethod = '' then
    LMethod := '?';
  Result := 'rpc=' + LMethod;
  if LName <> '' then
    Result := Result + ' tool=' + LName;
end;

constructor TServerThread.Create(AOwner: THttpTransport);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TServerThread.Execute;
begin
  // The accept loop is the transport. If it leaves, every later request is
  // silence -- the client connects, nothing answers, and the chat shows a call
  // that never comes back. It left once in the field and said nothing: one
  // accept in the log and no line after it, for the rest of the IDE session.
  // TThread swallows an exception into FatalException, so an unnamed death is
  // exactly what that looks like. Not any more.
  try
    FOwner._Run;
    _Trace('run.exit', 'accept loop returned');
  except
    on E: Exception do
      _Trace('run.error', Format('%s: %s', [E.ClassName, E.Message]));
  end;
end;

constructor TConnThread.Create(AOwner: THttpTransport; ASock: TSocket;
  AId: Integer);
begin
  FOwner := AOwner;
  FSock := ASock;
  FId := AId;
  inherited Create(False);
end;

procedure TConnThread.Execute;
var
  LStarted: Int64;
begin
  GConnId := FId;
  LStarted := _TraceUs;
  _Trace('conn.begin', Format('sock=%d', [FSock]));
  try
    FOwner._HandleConn(FSock);
  except
    on E: Exception do
      // A failed request costs its own connection and nothing else. Letting it
      // out would take the socket down without closing it, which is how the
      // CLOSE_WAIT sockets in the field report were left behind. It is traced,
      // though: a connection that ends without a response is exactly what the
      // caller sees as a call that never came back.
      _Trace('conn.error', Format('%s: %s', [E.ClassName, E.Message]));
  end;
  shutdown(FSock, SD_BOTH);
  closesocket(FSock);
  _Trace('conn.end', Format('us=%d', [_TraceUs - LStarted]));
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
  _Trace('listen', Format('port=%d', [LPort]));
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
  _Trace('stop', 'cancel signalled');
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
        // Before the slot, not after: the gap between this line and the
        // conn.begin that follows it is the transport's own handover, and it
        // is the first thing a reader has to be able to rule out.
        _Trace('accept', Format('sock=%d wake=%d', [LSock, LWait]));
        // A connection that cannot be adopted costs ITSELF, never the loop.
        // Letting it out of here ended the accept loop, and an accept loop
        // that ended made every later request in that IDE session hang with
        // nothing in any log -- the exact failure this trace was built to see.
        try
          _Adopt(LSock);
        except
          on E: Exception do
          begin
            _Trace('adopt.error', Format('%s: %s', [E.ClassName, E.Message]));
            shutdown(LSock, SD_BOTH);
            closesocket(LSock);
          end;
        end;
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
  LSlot: Integer;
  LPlaced: Boolean;
begin
  WSAEventSelect(ASock, 0, 0);
  LMode := 0;
  ioctlsocket(ASock, FIONBIO_CMD, LMode);
  LTimeout := RECV_TIMEOUT_MS;
  setsockopt(ASock, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@LTimeout),
    SizeOf(LTimeout));
  // Step by step, because the field says the loop dies HERE and a single line
  // saying 'adopt' cannot say which of these four things it died in. Each one
  // is a different bug: the socket options, the lock, reaping a finished
  // worker, or starting a new one.
  _Trace('adopt.opts', Format('sock=%d', [ASock]));
  LPlaced := False;
  LSlot := -1;
  EnterCriticalSection(FConnLock);
  try
    _Trace('adopt.lock', 'held');
    _ReapFinished;
    _Trace('adopt.reap', 'done');
    for LIdx := 0 to MAX_CONNS - 1 do
      if FConns[LIdx] = nil then
      begin
        FConns[LIdx] := TConnThread.Create(Self, ASock,
          InterlockedIncrement(GConnSeq));
        LPlaced := True;
        LSlot := LIdx;
        Break;
      end;
    _Trace('adopt.spawn', Format('placed=%d slot=%d', [Ord(LPlaced), LSlot]));
  finally
    LeaveCriticalSection(FConnLock);
  end;
  if LPlaced then
    _Trace('adopt', Format('sock=%d slot=%d', [ASock, LSlot]));
  // Every slot busy: refuse THIS connection rather than queue it behind the
  // others. A refused socket is a client that retries; a queued one is the
  // stall this whole change exists to remove.
  if not LPlaced then
  begin
    // The one refusal that must never be silent: to the caller a 503 and a
    // stall are the same wait, and this is the line that tells them apart.
    _Trace('refused', Format('sock=%d reason=all-%d-slots-busy',
      [ASock, MAX_CONNS]));
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
  LAt: Int64;
begin
  LAt := _TraceUs;
  if not _ReadRequest(ASock, LMethod, LBody) then
  begin
    // No request came out of the socket at all: the peer closed, or the
    // fifteen-second receive timeout expired. Both are silence to the caller,
    // and only this line says which one happened.
    _Trace('read.none', Format('us=%d', [_TraceUs - LAt]));
    Exit;
  end;
  _Trace('read.done', Format('us=%d http=%s bytes=%d %s',
    [_TraceUs - LAt, LMethod, Length(LBody), _FramePeek(LBody)]));
  if not SameText(LMethod, 'POST') then
  begin
    _Trace('reply', 'status=405');
    _SendStatus(ASock, '405 Method Not Allowed');
    Exit;
  end;
  if Trim(LBody) = '' then
  begin
    _Trace('reply', 'status=400');
    _SendStatus(ASock, '400 Bad Request');
    Exit;
  end;

  // Dispatch synchronously and capture whatever the server emits via Send.
  // The server marshals OTA work to the IDE main thread internally, so Send is
  // still invoked on THIS thread.
  //
  // **This pair of lines is what the trace exists for.** The main thread the
  // dispatch marshals to is the one running the IDE, and a turn of the agent
  // owns it: if the first call is slow because it is queued behind the IDE
  // rather than because anything here is stuck, the whole delay lands between
  // dispatch.begin and dispatch.end, with read and send measured in
  // microseconds on either side. If it does not, the delay is ours and the
  // surrounding lines say which step owns it.
  LAt := _TraceUs;
  _Trace('dispatch.begin', _FramePeek(LBody));
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
  _Trace('dispatch.end', Format('us=%d bytes=%d',
    [_TraceUs - LAt, Length(LResp)]));

  LAt := _TraceUs;
  if LResp <> '' then
  begin
    _SendJson(ASock, '200 OK', LResp);
    _Trace('reply', Format('status=200 us=%d bytes=%d',
      [_TraceUs - LAt, Length(LResp)]));
  end
  else
  begin
    _SendStatus(ASock, '202 Accepted');   // JSON-RPC notification, no response
    _Trace('reply', Format('status=202 us=%d', [_TraceUs - LAt]));
  end;
end;

function THttpTransport._ReadRequest(ASock: TSocket;
  out AMethod, ABody: string): Boolean;
var
  LBuf: TBytes;
  LChunk: array[0..4095] of Byte;
  LRecv, LLen, LHdrEnd, LContentLen, LBodyHave, LSpace, LIdx: Integer;
  LHeaders, LLower: string;
  LAt: Int64;
  LFirst: Boolean;
begin
  Result := False;
  AMethod := '';
  ABody := '';
  SetLength(LBuf, 0);

  // 1) accumulate until the header terminator (CRLFCRLF) is present.
  LAt := _TraceUs;
  LFirst := True;
  repeat
    LRecv := recv(ASock, LChunk[0], SizeOf(LChunk), 0);
    if LRecv <= 0 then
      Exit;   // peer closed, timeout, or error
    if LFirst then
    begin
      // Time to the FIRST byte, separately from the rest. A client that opens
      // the socket and sends late is not a server that reads slowly, and
      // without this line the two are one number.
      _Trace('read.first', Format('us=%d bytes=%d', [_TraceUs - LAt, LRecv]));
      LFirst := False;
    end;
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

initialization
  InitializeCriticalSection(GTraceLock);
  GTraceState := -1;
  // Read once, here, so every delta in the log is measured from the same
  // origin no matter which thread writes it.
  if not QueryPerformanceFrequency(GTraceFreq) then
    GTraceFreq := 0;
  if (GTraceFreq = 0) or (not QueryPerformanceCounter(GTraceBase)) then
  begin
    GTraceFreq := 0;
    GTraceBase := 0;
  end;

finalization
  DeleteCriticalSection(GTraceLock);

end.
