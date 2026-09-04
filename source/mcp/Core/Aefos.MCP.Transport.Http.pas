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
  WinSock2,
{$ELSE}
  Winapi.WinSock2,
{$ENDIF}
  Aefos.MCP.Types;

type
  THttpTransport = class(TInterfacedObject, IMCPTransport)
  private
    FThread: TObject;            // TServerThread; opaque to the interface section
    FListen: TSocket;
    FConn: TSocket;              // current connection (closed by Stop to unblock)
    FCancelled: Boolean;
    FWsaUp: Boolean;
    FOnFrame: TMCPFrameCallback;
    procedure _Run;
    procedure _HandleConn(ASock: TSocket);
    function _ReadRequest(ASock: TSocket; out AMethod, ABody: string): Boolean;
    procedure _SendAll(ASock: TSocket; const ABytes: TBytes);
    procedure _SendJson(ASock: TSocket; const AStatus, ABody: string);
    procedure _SendStatus(ASock: TSocket; const AStatus: string);
  public
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
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,   // WaitForSingleObject: join the server thread WITHOUT
                    // blocking the pump it depends on (see Stop).
{$ENDIF}
  Classes;

const
  RECV_TIMEOUT_MS = 15000;       // drop a connection that stalls mid-request
  LOCALHOST_NET   = $0100007F;   // 127.0.0.1 already in network byte order

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

constructor TServerThread.Create(AOwner: THttpTransport);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TServerThread.Execute;
begin
  FOwner._Run;
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

destructor THttpTransport.Destroy;
begin
  Stop;
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

  FConn := INVALID_SOCKET;
  FCancelled := False;
  FThread := TServerThread.Create(Self);
end;

procedure THttpTransport.Stop;
var
  LThread: TThread;
begin
  FCancelled := True;
  // Unblock accept() and any in-flight recv() by closing the sockets.
  if FListen <> INVALID_SOCKET then
  begin
    closesocket(FListen);
    FListen := INVALID_SOCKET;
  end;
  if FConn <> INVALID_SOCKET then
    closesocket(FConn);

  LThread := TThread(FThread);
  FThread := nil;
  if Assigned(LThread) then
  begin
    // PUMP WHILE JOINING -- a plain WaitFor here hangs the IDE.
    //
    // Every frame this transport serves is marshalled to the main thread with
    // TThread.Synchronize, which only completes when someone calls
    // CheckSynchronize. Stop runs on the main thread, so a bare WaitFor makes
    // the one thread that could release the server thread sit and wait for it:
    // the IDE closes its window and the process never exits. Measured, twice,
    // on Delphi 10 Seattle and again on 12 -- teardown trace stops at
    // 'http: Stop begin' and never reaches 'returned'.
    //
    // Draining before this point does NOT help, and that was the previous
    // attempt: cancellation happens above, so until then the server is still
    // accepting work and simply queues more (92 entries drained, then the same
    // hang). The pump has to run DURING the wait, after cancellation, which is
    // what this loop does.
    if GetCurrentThreadId = MainThreadID then
      while WaitForSingleObject(LThread.Handle, 10) = WAIT_TIMEOUT do
        CheckSynchronize(0)
    else
      // Off the main thread there is nothing to pump and nothing to deadlock
      // against: whoever owns the pump is still running it.
      LThread.WaitFor;
    LThread.Free;
  end;

  if FWsaUp then
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
  LTimeout: Cardinal;
begin
  while not FCancelled do
  begin
    LSock := accept(FListen, nil, nil);
    if FCancelled then
    begin
      if LSock <> INVALID_SOCKET then
        closesocket(LSock);
      Break;
    end;
    if LSock = INVALID_SOCKET then
      Break;   // listen socket closed / error
    LTimeout := RECV_TIMEOUT_MS;
    setsockopt(LSock, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@LTimeout),
      SizeOf(LTimeout));
    FConn := LSock;
    try
      _HandleConn(LSock);
    finally
      FConn := INVALID_SOCKET;
      closesocket(LSock);
    end;
  end;
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
