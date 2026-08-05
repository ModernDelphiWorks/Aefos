unit Aefos.Compat.Http;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  HTTP compatibility shim (Aefos -> Lazarus port, Milestone 1 / Phase D).

  Single uses-target for the HTTP surface Aefos needs off the IDE: the addon
  manager's plain GET (Milestone 1), plus the Ollama provider + Agent CLI's
  streaming chat POST and blocking /api/show probe POST (Phase D). No auth - the
  addon registry is static files over HTTPS and Ollama is a local endpoint.

  - Delphi (not FPC): delegates to System.Net.HttpClient (THTTPClient), keeping
    the exact semantics of the pre-shim call sites (GET for Addons.Net; the
    streaming sink + blocking Post the Ollama transport / capability probe used).
  - FPC (Windows): implemented over WinINet (wininet.dll, raw imports below).
    Chosen deliberately over fphttpclient+opensslsockets so the FPC exe has ZERO
    extra DLL dependency for HTTPS and the system proxy is respected
    (INTERNET_OPEN_TYPE_PRECONFIG). GET uses InternetOpenUrlW; POST needs the
    request API (InternetConnectW + HttpOpenRequestW + HttpSendRequestW), then the
    same InternetReadFile loop. HTTPS is selected by INTERNET_FLAG_SECURE from the
    URL scheme. Linux later: an fphttpclient+opensslsockets sibling behind an
    IFDEF WINDOWS guard.

  Contract for every Try* function: the RESULT is transport success (a reply was
  received). A non-2xx reply is still a success with AStatusCode carrying the
  code - the caller decides how to treat it (the streaming callers inspect the
  streamed body for the server's own error reason). AError is set (and Result
  False) only on a transport-level failure (DNS, connect, TLS, mid-read reset).

  STREAMING + CANCELLATION: TryPostStream delivers the response body to AOnChunk
  as raw bytes arrive. AOnChunk returns True to keep reading, False to ABORT
  cooperatively - the transfer stops and the handle closes, and that is NOT a
  failure (Result stays True, status/bytes are whatever arrived first). This
  mirrors the abort window the Ollama Delphi sink had (raise-to-unwind), now
  expressed as a return value so the FPC read loop can honour it too.

  API SURFACE COVERED:
    TAefosHttp.TryGetToFile(url, destFile, out status, out err) : Boolean
    TAefosHttp.TryGetText(url, out status, out body, out err)   : Boolean
    TAefosHttp.TryPostStream(url, body, contentType, onChunk,
      connMs, sendMs, recvMs, out status, out statusText, out err) : Boolean
    TAefosHttp.TryPostText(url, body, contentType, timeoutMs,
      out status, out body, out err) : Boolean
}

interface

{$IFNDEF FPC}
uses
  System.SysUtils;
{$ELSE}
uses
  SysUtils;
{$ENDIF}

type
  // Streaming sink for TryPostStream: receives each block of response bytes as
  // it arrives. Return True to keep reading, False to ABORT the transfer
  // (cooperative cancellation - see the unit header). On Delphi a `reference to`
  // (the Ollama transport binds a capturing method); on FPC 3.2.2, which has no
  // anonymous methods, an `of object` method pointer to a per-call carrier.
  {$IFDEF FPC}
  TAefosHttpChunkProc = function(const AChunk: TBytes): Boolean of object;
  {$ELSE}
  TAefosHttpChunkProc = reference to function(const AChunk: TBytes): Boolean;
  {$ENDIF}

  { Static, sealed namespace for the HTTP edge. Never instantiated. }
  TAefosHttp = class sealed
  public
    // GET AUrl, writing the body to ADestFile (overwritten). See the unit
    // header for the Result/AStatusCode/AError contract.
    class function TryGetToFile(const AUrl, ADestFile: string;
      out AStatusCode: Integer; out AError: string): Boolean; static;
    // GET AUrl, returning the body as UTF-8 text in ABody. ATimeoutMs (<=0 =
    // platform default) caps connect + response - the Ollama /api/tags probe
    // uses it so the model dropdown never hangs on a dead endpoint.
    class function TryGetText(const AUrl: string; out AStatusCode: Integer;
      out ABody: string; out AError: string;
      const ATimeoutMs: Integer = 0): Boolean; static;
    // Streaming POST of ARequestBody (AContentType) to AUrl, delivering the
    // response body to AOnChunk as it arrives. Timeouts are milliseconds; <=0
    // leaves the platform default. AStatusText is the reason phrase (fallback
    // error text). See the unit header for the streaming/cancellation contract.
    class function TryPostStream(const AUrl, ARequestBody, AContentType: string;
      const AOnChunk: TAefosHttpChunkProc;
      const AConnectTimeoutMs, ASendTimeoutMs, AResponseTimeoutMs: Integer;
      out AStatusCode: Integer; out AStatusText: string;
      out AError: string): Boolean; static;
    // Blocking POST of ARequestBody (AContentType) to AUrl, returning the whole
    // response body as UTF-8 text (the Ollama /api/show capability probe).
    // ATimeoutMs (<=0 = default) applies to connect and response.
    // AExtraHeaders (optional) is a block of additional request headers as
    // CRLF-separated "Name: Value" lines (e.g. the license Edge Function's
    // 'apikey: ...' header) - each line is applied to the request; empty means
    // none. Added for the cross-compiler license client so the Lazarus edition
    // sends the SAME apikey header the Delphi edition's THTTPClient does.
    class function TryPostText(const AUrl, ARequestBody, AContentType: string;
      const ATimeoutMs: Integer; out AStatusCode: Integer;
      out AResponseBody: string; out AError: string;
      const AExtraHeaders: string = ''): Boolean; static;
  end;

implementation

uses
  {$IFNDEF FPC}
  System.Classes,
  System.NetConsts,   // lets THTTPClient's ContentType/AcceptCharSet inline
  System.Net.HttpClient,
  System.Net.URLClient;
  {$ELSE}
  Classes;
  {$ENDIF}

{$IFNDEF FPC}

class function TAefosHttp.TryGetToFile(const AUrl, ADestFile: string;
  out AStatusCode: Integer; out AError: string): Boolean;
var
  LClient: THTTPClient;
  LStream: TFileStream;
  LResp: IHTTPResponse;
begin
  Result := False;
  AStatusCode := 0;
  AError := '';
  LClient := THTTPClient.Create;
  try
    LStream := TFileStream.Create(ADestFile, fmCreate);
    try
      try
        LResp := LClient.Get(AUrl, LStream);
        AStatusCode := LResp.StatusCode;
        Result := True;
      except
        on E: Exception do
          AError := E.Message;
      end;
    finally
      LStream.Free;
    end;
  finally
    LClient.Free;
  end;
end;

class function TAefosHttp.TryGetText(const AUrl: string; out AStatusCode: Integer;
  out ABody: string; out AError: string; const ATimeoutMs: Integer): Boolean;
var
  LClient: THTTPClient;
  LResp: IHTTPResponse;
begin
  Result := False;
  AStatusCode := 0;
  ABody := '';
  AError := '';
  LClient := THTTPClient.Create;
  try
    if ATimeoutMs > 0 then
    begin
      LClient.ConnectionTimeout := ATimeoutMs;
      LClient.ResponseTimeout := ATimeoutMs;
    end;
    try
      LResp := LClient.Get(AUrl);
      AStatusCode := LResp.StatusCode;
      ABody := LResp.ContentAsString(TEncoding.UTF8);
      Result := True;
    except
      on E: Exception do
        AError := E.Message;
    end;
  finally
    LClient.Free;
  end;
end;

type
  // Raised by the sink Write when AOnChunk asks to abort - unwinds the Post fast,
  // caught in TryPostStream and reported as a normal (non-failure) stop.
  EAefosHttpAbort = class(Exception);

  // Response sink handed to THTTPClient.Post: forwards each arriving block to the
  // caller's AOnChunk and raises EAefosHttpAbort when it returns False. This is
  // the exact shape the Ollama transport's TOllamaSinkStream had, lifted into the
  // shim so both compilers share one streaming contract.
  TAefosPostSink = class(TStream)
  private
    FOnChunk: TAefosHttpChunkProc;
  public
    constructor Create(const AOnChunk: TAefosHttpChunkProc);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TAefosPostSink.Create(const AOnChunk: TAefosHttpChunkProc);
begin
  inherited Create;
  FOnChunk := AOnChunk;
end;

function TAefosPostSink.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TAefosPostSink.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0;
end;

function TAefosPostSink.Write(const Buffer; Count: Longint): Longint;
var
  LBytes: TBytes;
begin
  Result := Count;
  if Count <= 0 then
    Exit;
  SetLength(LBytes, Count);
  Move(Buffer, LBytes[0], Count);
  if Assigned(FOnChunk) and (not FOnChunk(LBytes)) then
    raise EAefosHttpAbort.Create('aborted');
end;

class function TAefosHttp.TryPostStream(const AUrl, ARequestBody,
  AContentType: string; const AOnChunk: TAefosHttpChunkProc;
  const AConnectTimeoutMs, ASendTimeoutMs, AResponseTimeoutMs: Integer;
  out AStatusCode: Integer; out AStatusText: string; out AError: string): Boolean;
var
  LClient: THTTPClient;
  LSource: TStringStream;
  LSink: TAefosPostSink;
  LResp: IHTTPResponse;
begin
  Result := False;
  AStatusCode := 0;
  AStatusText := '';
  AError := '';
  LClient := THTTPClient.Create;
  try
    if AConnectTimeoutMs > 0 then
      LClient.ConnectionTimeout := AConnectTimeoutMs;
    if ASendTimeoutMs > 0 then
      LClient.SendTimeout := ASendTimeoutMs;
    if AResponseTimeoutMs > 0 then
      LClient.ResponseTimeout := AResponseTimeoutMs;
    LClient.ContentType := AContentType;
    LClient.AcceptCharSet := 'utf-8';
    LSource := TStringStream.Create(ARequestBody, TEncoding.UTF8);
    try
      LSink := TAefosPostSink.Create(AOnChunk);
      try
        try
          LResp := LClient.Post(AUrl, LSource, LSink);
          AStatusCode := LResp.StatusCode;
          AStatusText := LResp.StatusText;
          Result := True;
        except
          on EAefosHttpAbort do
            // Cooperative cancel: the caller told us to stop. Not a failure -
            // the caller ends the stream on its own terms (Ollama emits Done).
            Result := True;
          on E: Exception do
            AError := E.Message;
        end;
      finally
        LSink.Free;
      end;
    finally
      LSource.Free;
    end;
  finally
    LClient.Free;
  end;
end;

// Applies a CRLF-separated "Name: Value" header block to a THTTPClient's
// CustomHeaders (each non-empty line is one header). Blank lines are skipped; a
// line without a colon is ignored.
procedure _ApplyHeaders(const AClient: THTTPClient; const AHeaders: string);
var
  LLines: TArray<string>;
  LLine, LName, LValue: string;
  LColon: Integer;
begin
  LLines := AHeaders.Replace(#13#10, #10, [rfReplaceAll]).Split([#10]);
  for LLine in LLines do
  begin
    if Trim(LLine) = '' then
      Continue;
    LColon := Pos(':', LLine);
    if LColon <= 0 then
      Continue;
    LName := Trim(Copy(LLine, 1, LColon - 1));
    LValue := Trim(Copy(LLine, LColon + 1, MaxInt));
    if LName <> '' then
      AClient.CustomHeaders[LName] := LValue;
  end;
end;

class function TAefosHttp.TryPostText(const AUrl, ARequestBody,
  AContentType: string; const ATimeoutMs: Integer; out AStatusCode: Integer;
  out AResponseBody: string; out AError: string;
  const AExtraHeaders: string): Boolean;
var
  LClient: THTTPClient;
  LSource: TStringStream;
  LResp: IHTTPResponse;
begin
  Result := False;
  AStatusCode := 0;
  AResponseBody := '';
  AError := '';
  LClient := THTTPClient.Create;
  try
    if ATimeoutMs > 0 then
    begin
      LClient.ConnectionTimeout := ATimeoutMs;
      LClient.ResponseTimeout := ATimeoutMs;
    end;
    LClient.ContentType := AContentType;
    if AExtraHeaders <> '' then
      _ApplyHeaders(LClient, AExtraHeaders);
    LSource := TStringStream.Create(ARequestBody, TEncoding.UTF8);
    try
      try
        LResp := LClient.Post(AUrl, LSource);
        AStatusCode := LResp.StatusCode;
        AResponseBody := LResp.ContentAsString(TEncoding.UTF8);
        Result := True;
      except
        on E: Exception do
          AError := E.Message;
      end;
    finally
      LSource.Free;
    end;
  finally
    LClient.Free;
  end;
end;

{$ELSE}

const
  INTERNET_OPEN_TYPE_PRECONFIG = 0;      // honour the system proxy config
  INTERNET_FLAG_RELOAD         = $80000000;
  INTERNET_FLAG_NO_UI          = $00000200;
  INTERNET_FLAG_SECURE         = $00800000; // HTTPS (TLS) for the request
  INTERNET_FLAG_KEEP_CONNECTION = $00400000;
  INTERNET_SERVICE_HTTP        = 3;
  INTERNET_DEFAULT_HTTP_PORT   = 80;
  INTERNET_DEFAULT_HTTPS_PORT  = 443;
  INTERNET_OPTION_CONNECT_TIMEOUT = 2;
  INTERNET_OPTION_SEND_TIMEOUT    = 5;
  INTERNET_OPTION_RECEIVE_TIMEOUT = 6;
  HTTP_QUERY_STATUS_CODE       = 19;
  HTTP_QUERY_STATUS_TEXT       = 20;
  HTTP_QUERY_FLAG_NUMBER       = $20000000;

// Raw WinINet imports (wininet.dll) - no `Windows`/`wininet` unit dependency, so
// only DWORD-as-Cardinal and LongBool cross the boundary.
function InternetOpenW(lpszAgent: PWideChar; dwAccessType: Cardinal;
  lpszProxy, lpszProxyBypass: PWideChar; dwFlags: Cardinal): Pointer; stdcall;
  external 'wininet.dll' name 'InternetOpenW';
function InternetOpenUrlW(hInternet: Pointer; lpszUrl, lpszHeaders: PWideChar;
  dwHeadersLength, dwFlags: Cardinal; dwContext: NativeUInt): Pointer; stdcall;
  external 'wininet.dll' name 'InternetOpenUrlW';
function InternetReadFile(hFile: Pointer; lpBuffer: Pointer;
  dwNumberOfBytesToRead: Cardinal;
  out lpdwNumberOfBytesRead: Cardinal): LongBool; stdcall;
  external 'wininet.dll' name 'InternetReadFile';
function HttpQueryInfoW(hRequest: Pointer; dwInfoLevel: Cardinal;
  lpBuffer: Pointer; var lpdwBufferLength: Cardinal;
  var lpdwIndex: Cardinal): LongBool; stdcall;
  external 'wininet.dll' name 'HttpQueryInfoW';
function InternetCloseHandle(hInternet: Pointer): LongBool; stdcall;
  external 'wininet.dll' name 'InternetCloseHandle';
function InternetConnectW(hInternet: Pointer; lpszServerName: PWideChar;
  nServerPort: Word; lpszUserName, lpszPassword: PWideChar; dwService: Cardinal;
  dwFlags: Cardinal; dwContext: NativeUInt): Pointer; stdcall;
  external 'wininet.dll' name 'InternetConnectW';
function HttpOpenRequestW(hConnect: Pointer; lpszVerb, lpszObjectName,
  lpszVersion, lpszReferrer: PWideChar; lplpszAcceptTypes: Pointer;
  dwFlags: Cardinal; dwContext: NativeUInt): Pointer; stdcall;
  external 'wininet.dll' name 'HttpOpenRequestW';
function HttpSendRequestW(hRequest: Pointer; lpszHeaders: PWideChar;
  dwHeadersLength: Cardinal; lpOptional: Pointer;
  dwOptionalLength: Cardinal): LongBool; stdcall;
  external 'wininet.dll' name 'HttpSendRequestW';
function InternetSetOptionW(hInternet: Pointer; dwOption: Cardinal;
  lpBuffer: Pointer; dwBufferLength: Cardinal): LongBool; stdcall;
  external 'wininet.dll' name 'InternetSetOptionW';

// Sets a WinINet timeout option (milliseconds) on a handle; no-op when AMs<=0.
procedure _SetTimeout(const AHandle: Pointer; const AOption: Cardinal;
  const AMs: Integer);
var
  LValue: Cardinal;
begin
  if AMs <= 0 then
    Exit;
  LValue := Cardinal(AMs);
  InternetSetOptionW(AHandle, AOption, @LValue, SizeOf(LValue));
end;

// Core GET: opens AUrl (HTTPS handled by the scheme), reads the status code and
// the whole body into ABytes. Result is transport success (see unit header).
// ATimeoutMs (<=0 = default) caps connect + receive.
function _WinInetGet(const AUrl: string; out AStatus: Integer;
  out ABytes: TBytes; out AError: string; const ATimeoutMs: Integer): Boolean;
var
  LSession, LHandle: Pointer;
  LBuf: array[0..8191] of Byte;
  LRead, LLen, LIdx, LStatusDw: Cardinal;
  LTotal: Integer;
begin
  Result := False;
  AStatus := 0;
  SetLength(ABytes, 0);
  AError := '';
  LSession := InternetOpenW('Aefos', INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
  if LSession = nil then
  begin
    AError := SysErrorMessage(GetLastOSError);
    Exit;
  end;
  try
    _SetTimeout(LSession, INTERNET_OPTION_CONNECT_TIMEOUT, ATimeoutMs);
    _SetTimeout(LSession, INTERNET_OPTION_RECEIVE_TIMEOUT, ATimeoutMs);
    LHandle := InternetOpenUrlW(LSession, PWideChar(AUrl), nil, 0,
      INTERNET_FLAG_RELOAD or INTERNET_FLAG_NO_UI, 0);
    if LHandle = nil then
    begin
      AError := SysErrorMessage(GetLastOSError);
      Exit;
    end;
    try
      LStatusDw := 0;
      LLen := SizeOf(LStatusDw);
      LIdx := 0;
      if HttpQueryInfoW(LHandle,
        HTTP_QUERY_STATUS_CODE or HTTP_QUERY_FLAG_NUMBER,
        @LStatusDw, LLen, LIdx) then
        AStatus := Integer(LStatusDw);
      LTotal := 0;
      repeat
        LRead := 0;
        if not InternetReadFile(LHandle, @LBuf[0], Length(LBuf), LRead) then
        begin
          AError := SysErrorMessage(GetLastOSError);
          Exit; // transport failure mid-read
        end;
        if LRead > 0 then
        begin
          SetLength(ABytes, LTotal + Integer(LRead));
          Move(LBuf[0], ABytes[LTotal], LRead);
          Inc(LTotal, Integer(LRead));
        end;
      until LRead = 0;
      Result := True;
    finally
      InternetCloseHandle(LHandle);
    end;
  finally
    InternetCloseHandle(LSession);
  end;
end;

class function TAefosHttp.TryGetToFile(const AUrl, ADestFile: string;
  out AStatusCode: Integer; out AError: string): Boolean;
var
  LBytes: TBytes;
  LStream: TFileStream;
begin
  Result := _WinInetGet(AUrl, AStatusCode, LBytes, AError, 0);
  if not Result then
    Exit;
  LStream := TFileStream.Create(ADestFile, fmCreate or fmShareDenyWrite);
  try
    if Length(LBytes) > 0 then
      LStream.WriteBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
end;

class function TAefosHttp.TryGetText(const AUrl: string; out AStatusCode: Integer;
  out ABody: string; out AError: string; const ATimeoutMs: Integer): Boolean;
var
  LBytes: TBytes;
  LStart: Integer;
begin
  ABody := '';
  Result := _WinInetGet(AUrl, AStatusCode, LBytes, AError, ATimeoutMs);
  if not Result then
    Exit;
  // Strip a leading UTF-8 BOM if the server sent one, then decode.
  LStart := 0;
  if (Length(LBytes) >= 3) and (LBytes[0] = $EF) and (LBytes[1] = $BB) and
    (LBytes[2] = $BF) then
    LStart := 3;
  ABody := TEncoding.UTF8.GetString(LBytes, LStart, Length(LBytes) - LStart);
end;

// Splits AUrl into scheme (secure?), host, port and object path (path+query).
// A scheme-less or slash-less URL still resolves (host = the whole authority,
// path = '/'); only the http/https schemes are recognised.
procedure _CrackUrl(const AUrl: string; out ASecure: Boolean;
  out AHost, APath: string; out APort: Word);
var
  LRest, LAuthority: string;
  LSlash, LColon: Integer;
begin
  LRest := AUrl;
  ASecure := False;
  APort := INTERNET_DEFAULT_HTTP_PORT;
  if LowerCase(Copy(LRest, 1, 8)) = 'https://' then
  begin
    ASecure := True;
    APort := INTERNET_DEFAULT_HTTPS_PORT;
    LRest := Copy(LRest, 9, MaxInt);
  end
  else if LowerCase(Copy(LRest, 1, 7)) = 'http://' then
    LRest := Copy(LRest, 8, MaxInt);
  LSlash := Pos('/', LRest);
  if LSlash = 0 then
  begin
    LAuthority := LRest;
    APath := '/';
  end
  else
  begin
    LAuthority := Copy(LRest, 1, LSlash - 1);
    APath := Copy(LRest, LSlash, MaxInt);
  end;
  // Bracketed IPv6 literal ([::1] or [::1]:11434): the host is the bracketed
  // run verbatim; only a colon AFTER the closing bracket separates the port.
  // A naive Pos(':') would split inside the brackets (review finding).
  if (LAuthority <> '') and (LAuthority[1] = '[') then
  begin
    LColon := Pos(']', LAuthority);
    if LColon = 0 then
    begin
      AHost := LAuthority;   // malformed; let WinINet report it
      Exit;
    end;
    AHost := Copy(LAuthority, 1, LColon);
    if (Length(LAuthority) > LColon) and (LAuthority[LColon + 1] = ':') then
      APort := Word(StrToIntDef(Copy(LAuthority, LColon + 2, MaxInt), APort));
    Exit;
  end;
  LColon := Pos(':', LAuthority);
  if LColon = 0 then
    AHost := LAuthority
  else
  begin
    AHost := Copy(LAuthority, 1, LColon - 1);
    APort := Word(StrToIntDef(Copy(LAuthority, LColon + 1, MaxInt), APort));
  end;
end;

// Core POST over WinINet: connect, open a POST request, send ABody, read the
// response body in a loop and hand each block to AOnChunk. AOnChunk returning
// False stops the read (cooperative abort - Result stays True). AStatus /
// AStatusText carry the reply status; a non-2xx is still transport success. See
// the unit header for the full contract.
function _WinInetPost(const AUrl, ABody, AContentType: string;
  const AOnChunk: TAefosHttpChunkProc;
  const AConnMs, ASendMs, ARecvMs: Integer;
  out AStatus: Integer; out AStatusText: string; out AError: string;
  const AExtraHeaders: string = ''): Boolean;
var
  LSession, LConn, LReq: Pointer;
  LSecure: Boolean;
  LHost, LPath: string;
  LPort: Word;
  LFlags: Cardinal;
  LHeaders: string;
  LBodyBytes: TBytes;
  LStatusDw, LLen, LIdx: Cardinal;
  LTextBuf: array[0..511] of WideChar;
  LBuf: array[0..8191] of Byte;
  LRead: Cardinal;
  LChunk: TBytes;
begin
  Result := False;
  AStatus := 0;
  AStatusText := '';
  AError := '';
  _CrackUrl(AUrl, LSecure, LHost, LPath, LPort);
  LSession := InternetOpenW('Aefos', INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
  if LSession = nil then
  begin
    AError := SysErrorMessage(GetLastOSError);
    Exit;
  end;
  try
    _SetTimeout(LSession, INTERNET_OPTION_CONNECT_TIMEOUT, AConnMs);
    _SetTimeout(LSession, INTERNET_OPTION_SEND_TIMEOUT, ASendMs);
    _SetTimeout(LSession, INTERNET_OPTION_RECEIVE_TIMEOUT, ARecvMs);
    LConn := InternetConnectW(LSession, PWideChar(LHost), LPort, nil, nil,
      INTERNET_SERVICE_HTTP, 0, 0);
    if LConn = nil then
    begin
      AError := SysErrorMessage(GetLastOSError);
      Exit;
    end;
    try
      LFlags := INTERNET_FLAG_RELOAD or INTERNET_FLAG_NO_UI or
        INTERNET_FLAG_KEEP_CONNECTION;
      if LSecure then
        LFlags := LFlags or INTERNET_FLAG_SECURE;
      LReq := HttpOpenRequestW(LConn, 'POST', PWideChar(LPath), nil, nil, nil,
        LFlags, 0);
      if LReq = nil then
      begin
        AError := SysErrorMessage(GetLastOSError);
        Exit;
      end;
      try
        LHeaders := 'Content-Type: ' + AContentType + #13#10;
        // Append any caller-supplied header lines (already "Name: Value"+CRLF).
        if AExtraHeaders <> '' then
          LHeaders := LHeaders + AExtraHeaders;
        LBodyBytes := TEncoding.UTF8.GetBytes(ABody);
        if not HttpSendRequestW(LReq, PWideChar(LHeaders), Length(LHeaders),
          Pointer(LBodyBytes), Length(LBodyBytes)) then
        begin
          AError := SysErrorMessage(GetLastOSError);
          Exit;
        end;
        LStatusDw := 0;
        LLen := SizeOf(LStatusDw);
        LIdx := 0;
        if HttpQueryInfoW(LReq, HTTP_QUERY_STATUS_CODE or HTTP_QUERY_FLAG_NUMBER,
          @LStatusDw, LLen, LIdx) then
          AStatus := Integer(LStatusDw);
        LLen := SizeOf(LTextBuf) - SizeOf(WideChar);
        LIdx := 0;
        FillChar(LTextBuf, SizeOf(LTextBuf), 0);
        if HttpQueryInfoW(LReq, HTTP_QUERY_STATUS_TEXT, @LTextBuf[0], LLen, LIdx) then
          AStatusText := PWideChar(@LTextBuf[0]);
        repeat
          LRead := 0;
          if not InternetReadFile(LReq, @LBuf[0], Length(LBuf), LRead) then
          begin
            AError := SysErrorMessage(GetLastOSError);
            Exit; // transport failure mid-read
          end;
          if LRead > 0 then
          begin
            SetLength(LChunk, LRead);
            Move(LBuf[0], LChunk[0], LRead);
            if Assigned(AOnChunk) and (not AOnChunk(LChunk)) then
            begin
              // Cooperative abort: stop reading, close the handle, report ok.
              Result := True;
              Exit;
            end;
          end;
        until LRead = 0;
        Result := True;
      finally
        InternetCloseHandle(LReq);
      end;
    finally
      InternetCloseHandle(LConn);
    end;
  finally
    InternetCloseHandle(LSession);
  end;
end;

type
  // Accumulating sink for TryPostText: collects every block, never aborts. A
  // carrier object (not a closure) because the FPC callback is `of object`.
  TAefosByteSink = class
  private
    FBytes: TBytes;
    FTotal: Integer;
  public
    function Take(const AChunk: TBytes): Boolean;
    property Bytes: TBytes read FBytes;
    property Total: Integer read FTotal;
  end;

function TAefosByteSink.Take(const AChunk: TBytes): Boolean;
begin
  if Length(AChunk) > 0 then
  begin
    SetLength(FBytes, FTotal + Length(AChunk));
    Move(AChunk[0], FBytes[FTotal], Length(AChunk));
    Inc(FTotal, Length(AChunk));
  end;
  Result := True; // never abort a blocking collect
end;

class function TAefosHttp.TryPostStream(const AUrl, ARequestBody,
  AContentType: string; const AOnChunk: TAefosHttpChunkProc;
  const AConnectTimeoutMs, ASendTimeoutMs, AResponseTimeoutMs: Integer;
  out AStatusCode: Integer; out AStatusText: string; out AError: string): Boolean;
begin
  Result := _WinInetPost(AUrl, ARequestBody, AContentType, AOnChunk,
    AConnectTimeoutMs, ASendTimeoutMs, AResponseTimeoutMs,
    AStatusCode, AStatusText, AError);
end;

class function TAefosHttp.TryPostText(const AUrl, ARequestBody,
  AContentType: string; const ATimeoutMs: Integer; out AStatusCode: Integer;
  out AResponseBody: string; out AError: string;
  const AExtraHeaders: string): Boolean;
var
  LSink: TAefosByteSink;
  LProc: TAefosHttpChunkProc;
  LStatusText: string;
  LStart: Integer;
begin
  AResponseBody := '';
  LSink := TAefosByteSink.Create;
  try
    LProc := LSink.Take;   // of-object method pointer (no @ in delphi mode)
    Result := _WinInetPost(AUrl, ARequestBody, AContentType, LProc,
      ATimeoutMs, ATimeoutMs, ATimeoutMs, AStatusCode, LStatusText, AError,
      AExtraHeaders);
    if not Result then
      Exit;
    // Strip a leading UTF-8 BOM if present, then decode (matches TryGetText).
    LStart := 0;
    if (LSink.Total >= 3) and (LSink.Bytes[0] = $EF) and (LSink.Bytes[1] = $BB)
      and (LSink.Bytes[2] = $BF) then
      LStart := 3;
    AResponseBody := TEncoding.UTF8.GetString(LSink.Bytes, LStart,
      LSink.Total - LStart);
  finally
    LSink.Free;
  end;
end;

{$ENDIF}

end.
