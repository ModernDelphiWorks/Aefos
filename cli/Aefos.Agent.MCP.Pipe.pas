unit Aefos.Agent.MCP.Pipe;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Agent CLI - Windows named-pipe implementation of the MCP line
  transport (client side of aefos-mcp-<session>).

  Mirrors what the PowerShell bridge does, minus PowerShell: connect to
  \\.\pipe\<name>, write LF-terminated UTF-8 JSON-RPC frames, read LF-
  terminated responses. Synchronous blocking I/O is exactly right here - the
  client sends one request at a time and the server answers in order on the
  same instance.
*)

interface

uses
  {$IFDEF FPC}
  Windows,
  SysUtils,
  {$ELSE}
  Winapi.Windows,
  System.SysUtils,
  {$ENDIF}
  Aefos.Agent.MCP.Core;

type
  { Static, sealed namespace for the named-pipe MCP transport factory. Never
    instantiated; the class IS the namespace. }
  TAgentMcpPipe = class sealed
  public
    // Connects to \\.\pipe\<APipeName>. False + AError when the pipe is absent
    // (no IDE / no MCP host) or busy beyond ATimeoutMs.
    class function Connect(const APipeName: string; const ATimeoutMs: Cardinal;
      out ATransport: IAgentFrameTransport; out AError: string): Boolean; static;
  end;

implementation

type
  TPipeFrameTransport = class(TInterfacedObject, IAgentFrameTransport)
  private
    FHandle: THandle;
    FTail: TBytes; // bytes after the last LF, carried between reads
  public
    constructor Create(const AHandle: THandle);
    destructor Destroy; override;
    function SendLine(const ALine: string): Boolean;
    function ReadLine(out ALine: string): Boolean;
  end;

constructor TPipeFrameTransport.Create(const AHandle: THandle);
begin
  inherited Create;
  FHandle := AHandle;
end;

destructor TPipeFrameTransport.Destroy;
begin
  if FHandle <> INVALID_HANDLE_VALUE then
    CloseHandle(FHandle);
  inherited;
end;

function TPipeFrameTransport.SendLine(const ALine: string): Boolean;
var
  LBytes: TBytes;
  LWritten: DWORD;
begin
  LBytes := TEncoding.UTF8.GetBytes(ALine + #10);
  Result := WriteFile(FHandle, LBytes[0], Length(LBytes), LWritten, nil) and
    (Integer(LWritten) = Length(LBytes));
end;

function TPipeFrameTransport.ReadLine(out ALine: string): Boolean;
var
  LBuf: array[0..4095] of Byte;
  LRead: DWORD;
  LIndex, LStart, LOld: Integer;
begin
  ALine := '';
  repeat
    // A whole frame may already sit in the tail from the previous read.
    for LIndex := 0 to High(FTail) do
      if FTail[LIndex] = 10 then
      begin
        ALine := TEncoding.UTF8.GetString(FTail, 0, LIndex);
        // Strip a CR left by a cautious writer.
        if (ALine <> '') and (ALine[Length(ALine)] = #13) then
          SetLength(ALine, Length(ALine) - 1);
        LStart := LIndex + 1;
        FTail := Copy(FTail, LStart, Length(FTail) - LStart);
        Exit(True);
      end;
    if not ReadFile(FHandle, LBuf, SizeOf(LBuf), LRead, nil) then
      Exit(False); // closed/broken pipe
    if LRead = 0 then
      Exit(False);
    LOld := Length(FTail);
    SetLength(FTail, LOld + Integer(LRead));
    Move(LBuf[0], FTail[LOld], LRead);
  until False;
end;

class function TAgentMcpPipe.Connect(const APipeName: string;
  const ATimeoutMs: Cardinal;
  out ATransport: IAgentFrameTransport; out AError: string): Boolean;
var
  LFull: string;
  LHandle: THandle;
  LStart: Cardinal;
begin
  Result := False;
  ATransport := nil;
  AError := '';
  LFull := '\\.\pipe\' + APipeName;
  LStart := GetTickCount;
  repeat
    // Explicit -W on FPC (PChar is PWideChar under {$mode delphiunicode}; the
    // unsuffixed CreateFile/WaitNamedPipe there take ANSI PChar).
    {$IFDEF FPC}
    LHandle := CreateFileW(PWideChar(LFull), GENERIC_READ or GENERIC_WRITE,
      0, nil, OPEN_EXISTING, 0, 0);
    {$ELSE}
    LHandle := CreateFile(PChar(LFull), GENERIC_READ or GENERIC_WRITE,
      0, nil, OPEN_EXISTING, 0, 0);
    {$ENDIF}
    if LHandle <> INVALID_HANDLE_VALUE then
      Break;
    if GetLastError <> ERROR_PIPE_BUSY then
    begin
      AError := 'The aefos MCP pipe "' + APipeName + '" is not available ' +
        '(is the IDE running with the MCP host up?).';
      Exit;
    end;
    // All instances busy: wait for one to free up, bounded by the timeout.
    {$IFDEF FPC}
    if not WaitNamedPipeW(PWideChar(LFull), 250) then
      Sleep(50);
    {$ELSE}
    if not WaitNamedPipe(PChar(LFull), 250) then
      Sleep(50);
    {$ENDIF}
  until GetTickCount - LStart >= ATimeoutMs;
  if LHandle = INVALID_HANDLE_VALUE then
  begin
    AError := 'The aefos MCP pipe "' + APipeName + '" stayed busy for ' +
      IntToStr(ATimeoutMs) + ' ms.';
    Exit;
  end;
  ATransport := TPipeFrameTransport.Create(LHandle);
  Result := True;
end;

end.
