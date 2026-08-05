unit Aefos.Lazarus.TerminalController;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  Headless terminal controller for the Lazarus port (Aefos -> Lazarus, terminal
  slice). This is the terminal twin of the chat controller: it ties together the
  three pieces the earlier slices delivered -

    * Aefos.OTA.Terminal.Core.ConPTY      (#258) - the Windows pseudo-console
    * a reader thread                     (this unit) - drains the PTY output pipe
    * Aefos.OTA.Terminal.Core.VTermBuffer (#259) - the libvterm screen model

  and exposes the live TTerminalCell grid (through the buffer) plus write-input
  (keystrokes -> PTY). It owns NO window and NO UI: the window + the HTML render
  protocol + input wiring are the next slice. It mirrors the structure and
  lifetime of the Delphi TTerminalHost (source\terminal\Core\
  Aefos.OTA.Terminal.Core.TerminalHost.pas) but is trimmed to the ConPTY spawn +
  reader + buffer-feed + write + resize core; session persistence, command
  history and the action runner are separate concerns not pulled in here.

  LIFETIME (the #245/#246 discipline, applied to the terminal):
    * The reader thread marshals every chunk onto the main thread with
      Synchronize (NOT TThread.Queue - FPC purges queued calls from a
      FreeOnTerminate thread; and Synchronize blocks the reader so the carrier
      bytes stay valid for the call).
    * A liveness token (a Boolean the controller owns, passed by pointer) guards
      the synchronized feed: once Stop begins teardown it is cleared, so a
      late-serviced Synchronize no-ops instead of feeding a buffer that is about
      to go away.
    * Stop terminates the child (TerminateProcess - no orphan), breaks the output
      pipe to unblock the reader's ReadFile, then Terminate+WaitFor's the thread
      before releasing anything the thread could still touch.

  The controller does NOT own the buffer - the caller supplies and frees it, so
  the same live grid can be shared with a canvas/renderer in the next slice
  (exactly as TTerminalHost takes its TVTermBuffer).
*)

interface

uses
  {$IFDEF FPC}Windows, SysUtils, Classes,{$ELSE}Winapi.Windows, System.SysUtils, System.Classes,{$ENDIF}
  Aefos.OTA.Terminal.Core.ConPTY,
  Aefos.OTA.Terminal.Core.VTermBuffer;

type
  /// <summary>
  /// Background thread that reads raw bytes from the pseudo-console output pipe
  /// and feeds them into the libvterm-backed screen model on the MAIN thread via
  /// Synchronize. A liveness token (owned by the controller) makes a
  /// late-serviced feed a no-op once teardown has begun.
  /// </summary>
  TAefosTerminalReaderThread = class(TThread)
  private
    FReadPipe: THandle;
    FBuffer: TVTermBuffer;
    FLivePtr: PBoolean;
    FReadBuf: array[0..8191] of Byte;
    FBytesRead: Cardinal;
    FPending: TBytes;
    procedure _FeedPending;
  protected
    procedure Execute; override;
  public
    constructor Create(AReadPipe: THandle; ABuffer: TVTermBuffer;
      ALivePtr: PBoolean);
  end;

  /// <summary>
  /// Owns the lifecycle of a terminal child process (e.g. cmd.exe) behind a
  /// Windows pseudo-console, feeding its output into a caller-supplied
  /// TVTermBuffer and accepting keystroke/byte input. Headless - no UI.
  /// </summary>
  TAefosTerminalController = class
  private
    FBuffer: TVTermBuffer;
    FConPTY: TConPTY;
    FHPCON: HPCON;
    FReadPipe: THandle;
    FWritePipe: THandle;
    FProcInfo: TProcessInformation;
    FReader: TAefosTerminalReaderThread;
    FRunning: Boolean;
    FAlive: Boolean;
    procedure _Cleanup;
  public
    /// <summary>Binds the controller to a caller-owned screen model. The buffer
    /// is NOT freed by the controller.</summary>
    constructor Create(ABuffer: TVTermBuffer);
    destructor Destroy; override;

    /// <summary>Spawns the shell through ConPTY and starts the reader thread.
    /// ACommand is a full command line (executable + arguments).</summary>
    procedure Start(const ACommand: string; const AStartDir: string = '');
    /// <summary>Terminates the child, unblocks and joins the reader thread, and
    /// releases all OS handles. Idempotent.</summary>
    procedure Stop;

    /// <summary>Sends text (keystrokes / VT input) to the child as UTF-8.</summary>
    procedure WriteInput(const AText: string);
    /// <summary>Sends raw bytes to the child input pipe unchanged.</summary>
    procedure WriteBytes(const AData: TBytes);
    /// <summary>Resizes the screen model and the pseudo-console together.</summary>
    procedure Resize(const ACols, ARows: Integer);

    /// <summary>True between a successful Start and Stop.</summary>
    function IsRunning: Boolean;
    /// <summary>True while the child process handle still signals running.</summary>
    function IsProcessAlive: Boolean;

    /// <summary>The live screen model (caller-owned).</summary>
    property Buffer: TVTermBuffer read FBuffer;
  end;

implementation

{ FPC's friendly CreateProcessW binds lpStartupInfo as `const TStartupInfo`, which
  a const record may pass BY VALUE - copying only the base STARTUPINFO and dropping
  the STARTUPINFOEX trailing lpAttributeList, so the PSEUDOCONSOLE attribute never
  reaches the kernel and the child spawns its own console instead of attaching to
  ours. Declaring the raw API with a Pointer lpStartupInfo lets us pass @LStartup
  so the contiguous EX struct arrives intact. (Same fix as conptyprobe.lpr / the
  documented C-import exception to the no-loose-functions rule.) }
function CreateProcessEx(lpApplicationName: Pointer; lpCommandLine: Pointer;
  lpProcessAttributes, lpThreadAttributes: Pointer; bInheritHandles: BOOL;
  dwCreationFlags: DWORD; lpEnvironment, lpCurrentDirectory: Pointer;
  lpStartupInfo: Pointer; lpProcessInformation: Pointer): BOOL; stdcall;
  external 'kernel32' name 'CreateProcessW';

{ TAefosTerminalReaderThread }

constructor TAefosTerminalReaderThread.Create(AReadPipe: THandle;
  ABuffer: TVTermBuffer; ALivePtr: PBoolean);
begin
  inherited Create(False);
  FReadPipe := AReadPipe;
  FBuffer := ABuffer;
  FLivePtr := ALivePtr;
  FreeOnTerminate := False;
end;

procedure TAefosTerminalReaderThread._FeedPending;
begin
  // Liveness token: if the controller has begun teardown the buffer may be about
  // to be released, so drop the trailing chunk rather than feed a dying buffer.
  // In the normal path Synchronize blocks this thread and Stop's WaitFor drains
  // the call while the buffer is still alive; the token only guards teardown.
  if (FLivePtr <> nil) and FLivePtr^ and Assigned(FBuffer) then
    FBuffer.FeedBytes(FPending);
end;

procedure TAefosTerminalReaderThread.Execute;
var
  LOk: Boolean;
begin
  while not Terminated do
  begin
    LOk := ReadFile(FReadPipe, FReadBuf[0], SizeOf(FReadBuf), FBytesRead, nil);
    if LOk and (FBytesRead > 0) then
    begin
      SetLength(FPending, FBytesRead);
      Move(FReadBuf[0], FPending[0], FBytesRead);
      // Marshal onto the main thread. libvterm buffers partial multibyte
      // sequences across calls, so a chunk boundary mid-character is fine.
      Synchronize(_FeedPending);
    end
    else
    begin
      // The pipe breaks once the pseudo-console and our read handle close
      // (Stop), which is our exit signal; any other transient just backs off.
      if (GetLastError = ERROR_BROKEN_PIPE) or (GetLastError = ERROR_NO_DATA) then
        Break;
      if not Terminated then
        Sleep(10);
    end;
  end;
end;

{ TAefosTerminalController }

constructor TAefosTerminalController.Create(ABuffer: TVTermBuffer);
begin
  inherited Create;
  FBuffer := ABuffer;
  FConPTY := TConPTY.Instance;
  FRunning := False;
  FAlive := False;
  FillChar(FProcInfo, SizeOf(FProcInfo), 0);
end;

destructor TAefosTerminalController.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TAefosTerminalController.Start(const ACommand, AStartDir: string);
var
  LPtyIn, LPtyOut: THandle;
  LSize: TCoord;
  LStartup: TStartupInfoEx;
  LAttrSize: NativeUInt;
  LStartDirPtr: Pointer;
  LStartDirW: WideString;
  LCmdW: WideString;
begin
  if FRunning then Exit;
  if not FConPTY.IsAvailable then
    raise Exception.Create('ConPTY not available (needs Windows 10 1809+)');

  LPtyIn := 0;
  LPtyOut := 0;

  try
    // Two anonymous pipes: LPtyIn/FWritePipe carry OUR input to the PTY;
    // FReadPipe/LPtyOut carry the PTY's output back to us. Both are inside the
    // try so a failing SECOND CreatePipe still routes to _Cleanup (which closes
    // the first pipe's FWritePipe) instead of leaking it.
    if not CreatePipe(LPtyIn, FWritePipe, nil, 0) then RaiseLastOSError;
    if not CreatePipe(FReadPipe, LPtyOut, nil, 0) then RaiseLastOSError;

    LSize.X := FBuffer.Cols;
    LSize.Y := FBuffer.Rows;
    if FConPTY.CreatePseudoConsole(LSize, LPtyIn, LPtyOut, 0, FHPCON) <> S_OK then
      RaiseLastOSError;

    // CreatePseudoConsole duplicated the PTY-side handles; drop our copies.
    // Keeping LPtyOut open would stop the child's output pipe ever signalling
    // EOF, hanging the reader on process exit.
    CloseHandle(LPtyIn);
    LPtyIn := 0;
    CloseHandle(LPtyOut);
    LPtyOut := 0;

    LAttrSize := 0;
    FConPTY.InitializeProcThreadAttributeList(nil, 1, 0, LAttrSize);

    FillChar(LStartup, SizeOf(TStartupInfoEx), 0);
    LStartup.StartupInfo.cb := SizeOf(TStartupInfoEx);
    LStartup.lpAttributeList := AllocMem(LAttrSize);
    try
      if not FConPTY.InitializeProcThreadAttributeList(
        LStartup.lpAttributeList, 1, 0, LAttrSize) then
        RaiseLastOSError;

      // The attribute takes the HPCON VALUE as lpValue, not a pointer to it.
      if not FConPTY.UpdateProcThreadAttribute(LStartup.lpAttributeList, 0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, Pointer(FHPCON), SizeOf(HPCON),
        nil, nil) then
        RaiseLastOSError;

      if AStartDir = '' then
        LStartDirPtr := nil
      else
      begin
        LStartDirW := WideString(AStartDir);
        LStartDirPtr := PWideChar(LStartDirW);
      end;

      LCmdW := WideString(ACommand);
      UniqueString(LCmdW);

      // bInheritHandles MUST be False for a ConPTY child: the connection is
      // established through the attribute list, not handle inheritance. Passing
      // the raw CreateProcessEx so @LStartup (the full EX struct) reaches the
      // kernel; friendly CreateProcess would drop lpAttributeList.
      if not CreateProcessEx(nil, PWideChar(LCmdW), nil, nil, False,
        EXTENDED_STARTUPINFO_PRESENT, nil, LStartDirPtr,
        @LStartup, @FProcInfo) then
        RaiseLastOSError;

      FRunning := True;
      FAlive := True;
      FReader := TAefosTerminalReaderThread.Create(FReadPipe, FBuffer, @FAlive);
    finally
      if LStartup.lpAttributeList <> nil then
      begin
        FConPTY.DeleteProcThreadAttributeList(LStartup.lpAttributeList);
        FreeMem(LStartup.lpAttributeList);
      end;
    end;
  except
    if LPtyIn <> 0 then CloseHandle(LPtyIn);
    if LPtyOut <> 0 then CloseHandle(LPtyOut);
    // If the child already spawned but a later step raised (e.g. OS thread
    // creation for the reader), kill it BEFORE _Cleanup - _Cleanup only
    // CloseHandles hProcess, which would orphan a live child AND lose our only
    // handle to it, leaving it unreachable by any later Stop.
    if FProcInfo.hProcess <> 0 then
    begin
      TerminateProcess(FProcInfo.hProcess, 0);
      WaitForSingleObject(FProcInfo.hProcess, 500);
    end;
    FRunning := False;
    FAlive := False;
    _Cleanup;
    raise;
  end;
end;

procedure TAefosTerminalController.Stop;
begin
  if not FRunning then Exit;

  // Clear the liveness token FIRST so any Synchronize serviced during the join
  // below no-ops instead of feeding a buffer we are tearing down.
  FAlive := False;

  if FProcInfo.hProcess <> 0 then
  begin
    TerminateProcess(FProcInfo.hProcess, 0);
    WaitForSingleObject(FProcInfo.hProcess, 500);
  end;

  // Break the output pipe BEFORE joining the reader: it is blocked in ReadFile,
  // which only returns once every WRITE end closes. ClosePseudoConsole closes the
  // PTY's write end, so the reader's ReadFile returns (broken pipe) - that alone
  // unblocks it. We must NOT close our own FReadPipe (the READ end) yet: the
  // reader is still in ReadFile on that exact handle, and closing it here would
  // race the in-flight call on the same handle number. Join first, close after.
  if FHPCON <> 0 then
  begin
    FConPTY.ClosePseudoConsole(FHPCON);
    FHPCON := 0;
  end;

  if Assigned(FReader) then
  begin
    FReader.Terminate;
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;

  // Reader is fully joined now - safe to close our read-end copy.
  if FReadPipe <> 0 then
  begin
    CloseHandle(FReadPipe);
    FReadPipe := 0;
  end;

  _Cleanup;
  FRunning := False;
end;

procedure TAefosTerminalController.WriteInput(const AText: string);
var
  LUtf8: RawByteString;
begin
  if AText = '' then Exit;
  LUtf8 := UTF8Encode(UnicodeString(AText));
  WriteBytes(BytesOf(LUtf8));
end;

procedure TAefosTerminalController.WriteBytes(const AData: TBytes);
var
  LWritten: Cardinal;
begin
  if not FRunning or (FWritePipe = 0) or (Length(AData) = 0) then Exit;
  WriteFile(FWritePipe, AData[0], Length(AData), LWritten, nil);
end;

procedure TAefosTerminalController.Resize(const ACols, ARows: Integer);
var
  LSize: TCoord;
begin
  if (ACols < 1) or (ARows < 1) then Exit;

  // Resize the screen model first so the grid matches the new geometry, then the
  // pseudo-console so the shell agrees on the size.
  if Assigned(FBuffer) then
    FBuffer.Resize(ACols, ARows);

  if not FRunning or (FHPCON = 0) then Exit;
  LSize.X := ACols;
  LSize.Y := ARows;
  FConPTY.ResizePseudoConsole(FHPCON, LSize);
end;

function TAefosTerminalController.IsRunning: Boolean;
begin
  Result := FRunning;
end;

function TAefosTerminalController.IsProcessAlive: Boolean;
begin
  Result := FRunning and (FProcInfo.hProcess <> 0) and
    (WaitForSingleObject(FProcInfo.hProcess, 0) = WAIT_TIMEOUT);
end;

procedure TAefosTerminalController._Cleanup;
begin
  if FHPCON <> 0 then
  begin
    FConPTY.ClosePseudoConsole(FHPCON);
    FHPCON := 0;
  end;
  if FWritePipe <> 0 then
  begin
    CloseHandle(FWritePipe);
    FWritePipe := 0;
  end;
  if FReadPipe <> 0 then
  begin
    CloseHandle(FReadPipe);
    FReadPipe := 0;
  end;
  if FProcInfo.hProcess <> 0 then
  begin
    CloseHandle(FProcInfo.hProcess);
    FProcInfo.hProcess := 0;
  end;
  if FProcInfo.hThread <> 0 then
  begin
    CloseHandle(FProcInfo.hThread);
    FProcInfo.hThread := 0;
  end;
end;

end.
