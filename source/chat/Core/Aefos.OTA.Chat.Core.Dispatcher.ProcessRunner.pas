unit Aefos.OTA.Chat.Core.Dispatcher.ProcessRunner;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Real Win32 IProcessRunner implementation (ESP-004, Epic 3/3 Demand 2/3 —
  ADR-260, ADR-262).

  This is the irreducibly OS- and real-process-coupled side of the dispatcher
  split: CreateProcess, anonymous pipes (CreatePipe + SetHandleInformation to
  revoke parent-side inheritance), STARTUPINFO with redirected stdio, the two
  ReadFile read threads (one per child stream, emitting RAW undecoded bytes —
  ADR-261), process wait / exit-code, TerminateProcess, and handle hygiene. All
  of it was lifted verbatim (C-2) from the pre-refactor Core.CLIDispatcher
  (TCLIDispatcherRun + TCLIDispatcherReadThread); behaviour is byte-identical.

  The stdin leg carries a payload now (TProcessStartSpec.StdinText). The pipe
  itself is not new -- this runner has always created one and closed it right
  after the spawn, so the child read end-of-input at once -- what is new is
  writing to it first, on its own thread, and letting THAT close signal the end.
  A caller that sends nothing takes the old path unchanged.
    Why it exists: a command line cannot exceed 32766 characters
  (MAX_COMMAND_LINE_CHARS), and the assembled chat prompt carries the rendered
  project context, whose active-unit body alone is capped at 32 KB. With a
  project open that overran the limit and CreateProcess failed every turn with
  ERROR_FILENAME_EXCED_RANGE (206). Off the command line there is no such cap.
  Which drivers use it is the drivers' call (IExecutorProfile.PromptViaStdin);
  the ones that stay on the command line now get an explicit over-length error
  from _RejectOverLongCommandLine instead of a bare 206.

  COVERAGE EXCLUSION (ADR-262 / BR-5, no-silent-caps):
    This unit is DELIBERATELY ABSENT from the coverage list. Its lines
    need a *real* child process to execute, which a 32-bit dcc32 runner debugged
    by CodeCoverage.exe cannot reliably drive under instrumentation (issue #13 /
    ADR-233 — ERROR_NOT_SUPPORTED 50). Folding these lines into a covered unit
    would only dilute the 80% gate. The behaviour of this unit is guarded
    instead by the retained real-subprocess TCLIDispatcherTests (routed through
    ShouldSkipRealSubprocessTests, run on the dev box with
    AEFOS_RUN_ALL_TESTS=1). The seam-decoupled, deterministic units
    (Dispatcher.Decode + the refactored CLIDispatcher) carry the coverage via a
    fake IProcessRunner.

  RN-001 / BR-2 single-spawn invariant: this is the only unit in the chat
  subprocess transport that calls CreateProcess.

  Portability (Aefos -> Lazarus, external-CLI slice): this unit is Win32 API all
  the way down, so the sweep is only spelling -- de-dotted RTL unit names and the
  FPC `Windows` unit. The callback types it stores (TProcessChunkProc /
  TProcessStreamEndProc) are already compiler-split in Dispatcher.Types
  (`reference to` on Delphi, `of object` on FPC), and this unit only STORES and
  CALLS them, so both spellings work unchanged.

  Constraints:
    - Windows only.
}

interface

uses
  Aefos.OTA.Chat.Core.Dispatcher.Types;

type
  // The real Win32 spawn seam. Constructed once and shared as the default
  // collaborator of TCLIDispatcher (Register.pas composition).
  TWin32ProcessRunner = class(TInterfacedObject, IProcessRunner)
  public
    function Start(const ASpec: TProcessStartSpec): IProcessSession;
  end;

implementation

uses
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  SysUtils,
  Classes;

const
  READ_BUFFER_SIZE = 4096;
  WRITE_BUFFER_SIZE = 4096;
  // Longest command line CreateProcess accepts with lpApplicationName = nil.
  // The documented cap is 32767 INCLUDING the terminating null, so 32766 is the
  // last length that spawns; 32767 and up fail with ERROR_FILENAME_EXCED_RANGE
  // (206). Measured, not assumed: 32766 -> success, 32767 -> 206.
  MAX_COMMAND_LINE_CHARS = 32766;

type
  // Feeds the child's stdin and closes the pipe, which is what signals end of
  // input. Runs OFF the spawn thread on purpose: a payload larger than the pipe
  // buffer (64 KB by default, and a prompt carrying the project context can pass
  // that) blocks in WriteFile until the child drains it, and the child may not
  // drain it before writing output of its own. On the spawn thread that is a
  // deadlock -- the parent has not started its stdout/stderr readers yet, so the
  // child would block on a full stdout pipe while the parent blocks on stdin.
  //   Owns the handle it is given: the session hands it over and forgets it, so
  // nothing else can close it underneath this thread.
  TWin32StdinWriteThread = class(TThread)
  private
    FPipeHandle: THandle;
    FPayload: TBytes;
  protected
    procedure Execute; override;
  public
    constructor Create(const APipeHandle: THandle; const APayload: TBytes);
  end;

  TWin32ReadThread = class(TThread)
  private
    FPipeHandle: THandle;
    FKind: TProcessStreamKind;
    FOnChunk: TProcessChunkProc;
    FOnStreamEnd: TProcessStreamEndProc;
    procedure _FireStreamEnd(ASender: TObject);
  protected
    procedure Execute; override;
  public
    constructor Create(const APipeHandle: THandle;
      const AKind: TProcessStreamKind; const AOnChunk: TProcessChunkProc;
      const AOnStreamEnd: TProcessStreamEndProc);
  end;

  TWin32ProcessSession = class(TInterfacedObject, IProcessSession)
  private
    FProcessHandle: THandle;
    FStdoutThread: TWin32ReadThread;
    FStderrThread: TWin32ReadThread;
    FStdoutWrite: THandle;
    FStderrWrite: THandle;
    FStdoutRead: THandle;
    FStderrRead: THandle;
    FStdinRead: THandle;
    FStdinWrite: THandle;
    procedure _OpenPipes;
    procedure _CloseChildSideAndStdin(const AStdinText: string);
    procedure _CloseAllHandles;
    procedure _PrepareStartupInfo(out AInfo: TStartupInfoW);
    procedure _RejectOverLongCommandLine(const ASpec: TProcessStartSpec);
    function _DoCreateProcess(const ASpec: TProcessStartSpec): Boolean;
    procedure _StartReadThreads(const AOnChunk: TProcessChunkProc;
      const AOnStreamEnd: TProcessStreamEndProc);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Spawn(const ASpec: TProcessStartSpec);
    { IProcessSession }
    function IsRunning: Boolean;
    procedure BeginRead(const AOnChunk: TProcessChunkProc;
      const AOnStreamEnd: TProcessStreamEndProc);
    procedure Terminate;
    function GetCompletionExitCode(const AGraceMs: Cardinal): Cardinal;
  end;

{ Helper functions (lifted verbatim) }

function _CreatePipePair(out AReadHandle, AWriteHandle: THandle;
  const AParentSideIsRead: Boolean): Boolean;
var
  LSecurity: TSecurityAttributes;
begin
  ZeroMemory(@LSecurity, SizeOf(LSecurity));
  LSecurity.nLength := SizeOf(TSecurityAttributes);
  LSecurity.bInheritHandle := True;
  LSecurity.lpSecurityDescriptor := nil;

  Result := CreatePipe(AReadHandle, AWriteHandle, @LSecurity, 0);
  if not Result then
    Exit;

  if AParentSideIsRead then
    SetHandleInformation(AReadHandle, HANDLE_FLAG_INHERIT, 0)
  else
    SetHandleInformation(AWriteHandle, HANDLE_FLAG_INHERIT, 0);
end;

procedure _CloseHandleSafe(var AHandle: THandle);
begin
  if (AHandle <> 0) and (AHandle <> INVALID_HANDLE_VALUE) then
  begin
    CloseHandle(AHandle);
    AHandle := INVALID_HANDLE_VALUE;
  end;
end;

var
  // Hidden desktop the CLI (and its children) run on. A process on a SEPARATE
  // desktop cannot steal the FOREGROUND of the visible desktop, so the console/
  // terminal window the CLI spawns (Win11 CASCADIA_HOSTING_WINDOW_CLASS) is born
  // invisible there and never deactivates the IDE -> the docked WebView2 stops
  // blanking. stdio pipes are desktop-independent, so output capture is unaffected.
  GCliDesktop: HDESK = 0;

const
  CLI_DESKTOP_NAME = 'AefosCliDesktop';

function _EnsureCliDesktop: Boolean;
begin
  // CreateDesktopW, not the unqualified CreateDesktop: FPC's Windows unit maps
  // the unqualified name to the ANSI entry point (LPSTR), which does not take
  // this unit's PChar (= PWideChar under delphiunicode). On Delphi the
  // unqualified name already IS the W one, so naming it explicitly is a no-op
  // there and the two builds call the identical API. Same reason for
  // CreateProcessW / TStartupInfoW below.
  if GCliDesktop = 0 then
    GCliDesktop := CreateDesktopW(PChar(CLI_DESKTOP_NAME), nil, nil, 0,
      GENERIC_ALL, nil);
  Result := GCliDesktop <> 0;
end;

{ TWin32ProcessRunner }

function TWin32ProcessRunner.Start(
  const ASpec: TProcessStartSpec): IProcessSession;
var
  LSession: TWin32ProcessSession;
begin
  LSession := TWin32ProcessSession.Create;
  Result := LSession;
  LSession.Spawn(ASpec);
end;

{ TWin32ProcessSession }

constructor TWin32ProcessSession.Create;
begin
  inherited Create;
  FProcessHandle := 0;
  FStdoutRead := INVALID_HANDLE_VALUE;
  FStdoutWrite := INVALID_HANDLE_VALUE;
  FStderrRead := INVALID_HANDLE_VALUE;
  FStderrWrite := INVALID_HANDLE_VALUE;
  FStdinRead := INVALID_HANDLE_VALUE;
  FStdinWrite := INVALID_HANDLE_VALUE;
end;

destructor TWin32ProcessSession.Destroy;
begin
  // Handle hygiene only. The read threads are intentionally not joined/freed
  // here: they keep the dispatcher run alive (via the captured callbacks) for
  // the whole run, exactly as the pre-refactor TCLIDispatcherRun did — this
  // destructor runs only once that keep-alive chain is gone.
  _CloseAllHandles;
  inherited;
end;

procedure TWin32ProcessSession._OpenPipes;
begin
  if not _CreatePipePair(FStdoutRead, FStdoutWrite, True) then
    raise EDispatcherSpawnFailed.CreateFmt(
      'CreatePipe(stdout) failed (last error: %d)', [GetLastError]);
  if not _CreatePipePair(FStderrRead, FStderrWrite, True) then
    raise EDispatcherSpawnFailed.CreateFmt(
      'CreatePipe(stderr) failed (last error: %d)', [GetLastError]);
  if not _CreatePipePair(FStdinRead, FStdinWrite, False) then
    raise EDispatcherSpawnFailed.CreateFmt(
      'CreatePipe(stdin) failed (last error: %d)', [GetLastError]);
end;

procedure TWin32ProcessSession._CloseChildSideAndStdin(
  const AStdinText: string);
var
  LWriter: TWin32StdinWriteThread;
  LPayload: TBytes;
begin
  // The child holds its own copies now; the parent's ends must go or the read
  // loops never see end-of-stream.
  _CloseHandleSafe(FStdoutWrite);
  _CloseHandleSafe(FStderrWrite);
  _CloseHandleSafe(FStdinRead);
  if AStdinText = '' then
  begin
    // Nothing to send: close at once, byte-identical to what this runner has
    // always done -- the child reads end-of-input immediately. Every
    // command-line-prompt driver takes this branch, so their spawn is unchanged.
    _CloseHandleSafe(FStdinWrite);
    Exit;
  end;
  // Hand the write end to the writer thread and drop it from the session in the
  // same breath, so neither _CloseAllHandles nor the destructor can close it
  // out from under the write in progress. The thread closes it when the payload
  // is out -- that close IS the end-of-input signal.
  LPayload := TEncoding.UTF8.GetBytes(AStdinText);
  LWriter := TWin32StdinWriteThread.Create(FStdinWrite, LPayload);
  FStdinWrite := INVALID_HANDLE_VALUE;
  LWriter.Start;
end;

procedure TWin32ProcessSession._CloseAllHandles;
begin
  _CloseHandleSafe(FStdoutRead);
  _CloseHandleSafe(FStdoutWrite);
  _CloseHandleSafe(FStderrRead);
  _CloseHandleSafe(FStderrWrite);
  _CloseHandleSafe(FStdinRead);
  _CloseHandleSafe(FStdinWrite);
  if (FProcessHandle <> 0) and (FProcessHandle <> INVALID_HANDLE_VALUE) then
  begin
    CloseHandle(FProcessHandle);
    FProcessHandle := 0;
  end;
end;

procedure TWin32ProcessSession._PrepareStartupInfo(out AInfo: TStartupInfoW);
begin
  ZeroMemory(@AInfo, SizeOf(AInfo));
  AInfo.cb := SizeOf(TStartupInfoW);
  AInfo.dwFlags := STARTF_USESTDHANDLES;
  AInfo.hStdInput := FStdinRead;
  AInfo.hStdOutput := FStdoutWrite;
  AInfo.hStdError := FStderrWrite;
  // Run the CLI on a hidden desktop so any console/terminal window it (or a child)
  // spawns cannot steal the foreground from the IDE -> the docked WebView2 never
  // blanks. lpDesktop is inherited by the whole child tree. Best-effort: falls
  // back to the default desktop if creation fails.
  if _EnsureCliDesktop then
    AInfo.lpDesktop := PChar(CLI_DESKTOP_NAME);
end;

procedure TWin32ProcessSession._RejectOverLongCommandLine(
  const ASpec: TProcessStartSpec);
begin
  if Length(ASpec.CommandLine) <= MAX_COMMAND_LINE_CHARS then
    Exit;
  // Checked BEFORE the pipes are opened, so nothing has to be cleaned up, and
  // before CreateProcess so the failure is named instead of arriving as a bare
  // "last error: 206" the reader has to look up. 206 is
  // ERROR_FILENAME_EXCED_RANGE, which reads like a path problem and is not one:
  // the command line simply does not fit.
  //   A driver only reaches this if it puts the prompt on the command line
  // (IExecutorProfile.PromptViaStdin = False) and the prompt outgrew it. The fix
  // is that flag, not a shorter prompt, so the message says so.
  raise EDispatcherSpawnFailed.CreateFmt(
    'Command line too long for "%s": %d characters, but CreateProcess accepts ' +
    'at most %d. The prompt (which carries the project context) does not fit ' +
    'as an argument for this executor; it has to be delivered on stdin ' +
    '(IExecutorProfile.PromptViaStdin).',
    [ASpec.ExecutorPath, Length(ASpec.CommandLine), MAX_COMMAND_LINE_CHARS]);
end;

function TWin32ProcessSession._DoCreateProcess(
  const ASpec: TProcessStartSpec): Boolean;
var
  LStartupInfo: TStartupInfoW;
  LProcessInfo: TProcessInformation;
  LCommandLine: string;
  LWorkDir: PChar;
begin
  _PrepareStartupInfo(LStartupInfo);
  ZeroMemory(@LProcessInfo, SizeOf(LProcessInfo));
  LCommandLine := ASpec.CommandLine;
  UniqueString(LCommandLine);
  if ASpec.WorkingDirectory = '' then
    LWorkDir := nil
  else
    LWorkDir := PChar(ASpec.WorkingDirectory);
  Result := CreateProcessW(nil, PChar(LCommandLine), nil, nil, True,
    CREATE_NO_WINDOW or CREATE_UNICODE_ENVIRONMENT,
    PChar(ASpec.EnvBlock), LWorkDir, LStartupInfo, LProcessInfo);
  if Result then
  begin
    FProcessHandle := LProcessInfo.hProcess;
    CloseHandle(LProcessInfo.hThread);
  end;
end;

procedure TWin32ProcessSession._StartReadThreads(
  const AOnChunk: TProcessChunkProc; const AOnStreamEnd: TProcessStreamEndProc);
begin
  FStdoutThread := TWin32ReadThread.Create(FStdoutRead, pskStdout,
    AOnChunk, AOnStreamEnd);
  FStdoutThread.Start;

  FStderrThread := TWin32ReadThread.Create(FStderrRead, pskStderr,
    AOnChunk, AOnStreamEnd);
  FStderrThread.Start;
end;

procedure TWin32ProcessSession.Spawn(const ASpec: TProcessStartSpec);
begin
  _RejectOverLongCommandLine(ASpec);

  _OpenPipes;

  if not _DoCreateProcess(ASpec) then
  begin
    _CloseAllHandles;
    raise EDispatcherSpawnFailed.CreateFmt(
      'CreateProcess failed for "%s" (last error: %d)',
      [ASpec.ExecutorPath, GetLastError]);
  end;

  _CloseChildSideAndStdin(ASpec.StdinText);
end;

procedure TWin32ProcessSession.BeginRead(const AOnChunk: TProcessChunkProc;
  const AOnStreamEnd: TProcessStreamEndProc);
begin
  _StartReadThreads(AOnChunk, AOnStreamEnd);
end;

function TWin32ProcessSession.IsRunning: Boolean;
begin
  if (FProcessHandle = 0) or (FProcessHandle = INVALID_HANDLE_VALUE) then
    Exit(False);
  Result := WaitForSingleObject(FProcessHandle, 0) = WAIT_TIMEOUT;
end;

procedure TWin32ProcessSession.Terminate;
begin
  if (FProcessHandle <> 0) and (FProcessHandle <> INVALID_HANDLE_VALUE) then
    TerminateProcess(FProcessHandle, 1);
end;

function TWin32ProcessSession.GetCompletionExitCode(
  const AGraceMs: Cardinal): Cardinal;
begin
  Result := 0;
  if (FProcessHandle <> 0) and (FProcessHandle <> INVALID_HANDLE_VALUE) then
  begin
    if WaitForSingleObject(FProcessHandle, AGraceMs) = WAIT_OBJECT_0 then
      GetExitCodeProcess(FProcessHandle, Result)
    else
      Result := DWORD(-1);
  end;
end;

{ TWin32StdinWriteThread }

constructor TWin32StdinWriteThread.Create(const APipeHandle: THandle;
  const APayload: TBytes);
begin
  inherited Create(True);
  // Self-freeing, unlike the read threads: this one keeps nothing alive and
  // nobody waits on it. It owns only its handle and its own copy of the payload,
  // touches no session state, and is done as soon as the bytes are out -- so
  // there is nothing left for anyone to join.
  FreeOnTerminate := True;
  FPipeHandle := APipeHandle;
  FPayload := APayload;
end;

procedure TWin32StdinWriteThread.Execute;
var
  LOffset: Integer;
  LChunk: DWORD;
  LWritten: DWORD;
begin
  try
    LOffset := 0;
    while LOffset < Length(FPayload) do
    begin
      LChunk := DWORD(Length(FPayload) - LOffset);
      if LChunk > WRITE_BUFFER_SIZE then
        LChunk := WRITE_BUFFER_SIZE;
      LWritten := 0;
      // A failure here is normal, not exceptional: a cancelled or crashed child
      // leaves a broken pipe. Stop writing and close, which is what a child that
      // is still alive is waiting for anyway.
      if not WriteFile(FPipeHandle, FPayload[LOffset], LChunk, LWritten, nil) then
        Break;
      if LWritten = 0 then
        Break;
      Inc(LOffset, Integer(LWritten));
    end;
  finally
    // Unconditional: the close is the end-of-input signal. Skipping it on an
    // error path would leave the child waiting for data that is never coming,
    // which looks exactly like a hang.
    _CloseHandleSafe(FPipeHandle);
  end;
end;

{ TWin32ReadThread }

constructor TWin32ReadThread.Create(const APipeHandle: THandle;
  const AKind: TProcessStreamKind; const AOnChunk: TProcessChunkProc;
  const AOnStreamEnd: TProcessStreamEndProc);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPipeHandle := APipeHandle;
  FKind := AKind;
  FOnChunk := AOnChunk;
  FOnStreamEnd := AOnStreamEnd;
  OnTerminate := _FireStreamEnd;
end;

procedure TWin32ReadThread._FireStreamEnd(ASender: TObject);
begin
  // TThread invokes OnTerminate via Synchronize, so the stream-end (and the
  // dispatcher's carry flush + completion fan-in) runs on the main thread —
  // identical to the pre-refactor _OnReadThreadTerminate timing.
  if Assigned(FOnStreamEnd) then
    FOnStreamEnd(FKind);
end;

procedure TWin32ReadThread.Execute;
var
  LBuffer: array[0..READ_BUFFER_SIZE - 1] of Byte;
  LBytesRead: DWORD;
  LChunk: TBytes;
  LSuccess: Boolean;
begin
  while not Terminated do
  begin
    LBytesRead := 0;
    LSuccess := ReadFile(FPipeHandle, LBuffer, READ_BUFFER_SIZE, LBytesRead, nil);
    if (not LSuccess) or (LBytesRead = 0) then
      Break;

    // Emit RAW, undecoded bytes (ADR-261). The UTF-8 carry decode + ANSI strip
    // run on the covered dispatcher side.
    SetLength(LChunk, LBytesRead);
    Move(LBuffer[0], LChunk[0], LBytesRead);
    if Assigned(FOnChunk) then
      FOnChunk(FKind, LChunk, Integer(LBytesRead));
  end;
end;

end.
