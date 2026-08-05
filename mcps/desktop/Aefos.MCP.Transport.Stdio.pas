unit Aefos.MCP.Transport.Stdio;

{
  Newline-delimited JSON-RPC over stdin/stdout — the transport an MCP client
  (Claude Code, Codex, ...) speaks to a server it spawned as a subprocess.

  The in-IDE Aefos server uses a named pipe because it lives INSIDE the IDE
  process. This server is a separate .exe precisely so a native database driver
  can never take the IDE down with it, and a subprocess is addressed over stdio.
  Same TMCPServer core, same dialect — only the pipe changes.

  ⚠ STDOUT IS THE PROTOCOL. A single stray Writeln corrupts the frame stream and
  the client drops the connection with a parse error that looks like a server
  bug. Diagnostics go to STDERR, never stdout. That is why this unit talks to the
  raw handles instead of Delphi's Output text file: nothing can accidentally
  interleave.

  Framing: one JSON object per line, UTF-8, '\n'-terminated. A blank line is
  ignored rather than dispatched (some clients send keepalive newlines).
}

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Aefos.MCP.Types;

type
  TMCPStdioTransport = class(TInterfacedObject, IMCPTransport)
  private
    FOnFrame: TMCPFrameCallback;
    FActive: Boolean;
    FOutLock: TCriticalSection;
    FStdIn: THandle;
    FStdOut: THandle;
  public
    constructor Create;
    destructor Destroy; override;
    // IMCPTransport. APipeName is meaningless for stdio and is ignored.
    procedure Start(const APipeName: string);
    procedure Stop;
    procedure Send(const AFrame: string);
    procedure SetOnFrame(const ACallback: TMCPFrameCallback);
    // Blocks on the CALLING thread, dispatching frames until stdin reaches EOF
    // (the client closed the pipe = time to exit). The server's Start does not
    // spawn a reader for us — the process's main thread IS the pump.
    procedure Run;
  end;

// Diagnostics that must never touch stdout.
procedure StdioLog(const AMessage: string);

implementation

procedure StdioLog(const AMessage: string);
var
  LBytes: TBytes;
  LWritten: DWORD;
  LHandle: THandle;
begin
  LHandle := GetStdHandle(STD_ERROR_HANDLE);
  if LHandle = INVALID_HANDLE_VALUE then
    Exit;
  LBytes := TEncoding.UTF8.GetBytes(AMessage + sLineBreak);
  if Length(LBytes) > 0 then
    WriteFile(LHandle, LBytes[0], Length(LBytes), LWritten, nil);
end;

{ TMCPStdioTransport }

constructor TMCPStdioTransport.Create;
begin
  inherited Create;
  FOutLock := TCriticalSection.Create;
  FStdIn := GetStdHandle(STD_INPUT_HANDLE);
  FStdOut := GetStdHandle(STD_OUTPUT_HANDLE);
end;

destructor TMCPStdioTransport.Destroy;
begin
  FOutLock.Free;
  inherited;
end;

procedure TMCPStdioTransport.Start(const APipeName: string);
begin
  FActive := True;
end;

procedure TMCPStdioTransport.Stop;
begin
  FActive := False;
end;

procedure TMCPStdioTransport.SetOnFrame(const ACallback: TMCPFrameCallback);
begin
  FOnFrame := ACallback;
end;

procedure TMCPStdioTransport.Send(const AFrame: string);
var
  LBytes: TBytes;
  LWritten: DWORD;
  LTotal: Integer;
begin
  if FStdOut = INVALID_HANDLE_VALUE then
    Exit;
  // Serialised: the server may emit a notification from another thread while a
  // response is being written, and two interleaved half-frames are unparseable.
  FOutLock.Enter;
  try
    LBytes := TEncoding.UTF8.GetBytes(AFrame + #10);
    LTotal := 0;
    while LTotal < Length(LBytes) do
    begin
      if not WriteFile(FStdOut, LBytes[LTotal], Length(LBytes) - LTotal,
        LWritten, nil) then
        Exit;                      // client went away; nothing useful to do
      if LWritten = 0 then
        Exit;
      Inc(LTotal, Integer(LWritten));
    end;
    FlushFileBuffers(FStdOut);
  finally
    FOutLock.Leave;
  end;
end;

procedure TMCPStdioTransport.Run;
var
  LBuffer: TBytes;
  LChunk: array[0..8191] of Byte;
  LRead: DWORD;
  LIndex, LLineEnd: Integer;
  LLine: string;
  LLineBytes: TBytes;
begin
  FActive := True;
  SetLength(LBuffer, 0);
  while FActive do
  begin
    if not ReadFile(FStdIn, LChunk[0], Length(LChunk), LRead, nil) then
      Break;                        // broken pipe
    if LRead = 0 then
      Break;                        // EOF: the client closed stdin
    LIndex := Length(LBuffer);
    SetLength(LBuffer, LIndex + Integer(LRead));
    Move(LChunk[0], LBuffer[LIndex], LRead);

    // Drain every complete line currently in the buffer.
    repeat
      LLineEnd := -1;
      for LIndex := 0 to High(LBuffer) do
        if LBuffer[LIndex] = 10 then
        begin
          LLineEnd := LIndex;
          Break;
        end;
      if LLineEnd < 0 then
        Break;

      LLineBytes := Copy(LBuffer, 0, LLineEnd);
      LBuffer := Copy(LBuffer, LLineEnd + 1, Length(LBuffer) - LLineEnd - 1);
      // Tolerate CRLF from a client that framed with Windows line endings.
      if (Length(LLineBytes) > 0) and
         (LLineBytes[High(LLineBytes)] = 13) then
        SetLength(LLineBytes, Length(LLineBytes) - 1);
      if Length(LLineBytes) = 0 then
        Continue;                   // keepalive newline

      LLine := TEncoding.UTF8.GetString(LLineBytes);
      if (Trim(LLine) <> '') and Assigned(FOnFrame) then
      begin
        // A handler must never kill the pump: the server already converts tool
        // exceptions into error frames, but a defect in that path would
        // otherwise silently end the session.
        try
          FOnFrame(LLine);
        except
          on E: Exception do
            StdioLog('frame dispatch failed: ' + E.ClassName + ': ' + E.Message);
        end;
      end;
    until False;
  end;
end;

end.
