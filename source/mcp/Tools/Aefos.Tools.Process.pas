unit Aefos.Tools.Process;

(*
  Aefos.Tools.Process — pure subprocess runner.

  Runs an external program, feeds it a string on stdin, and captures stdout and
  stderr separately, with a hard timeout that kills the child. This is the base
  piece behind the "Python tool" mechanism (and any other shell-out tool): the
  agent calls a tool -> the MCP layer spawns a process here -> JSON in on stdin,
  JSON out on stdout. The runner is content-agnostic: it moves strings, it does
  not parse JSON (that stays in the caller).

  Deadlock-free by construction: stdout/stderr are drained with non-blocking
  PeekNamedPipe in the same poll loop that watches the process and the clock —
  no blocking ReadFile, no two-pipe deadlock, no helper threads. stdin is
  expected to be bounded (tool arguments), written then closed before draining.

  Boundary: RTL + Winapi only (CreateProcess/pipes). No ToolsAPI, no Vcl./FMX.
  Runs headless and from the IDE alike. MUST be called off the IDE main thread
  by the host (a long tool would otherwise freeze the IDE).

  Naming convention: MCP\Source\Tools\NAMING.md (domain `Process`).
*)

interface

type
  TToolProcessOutcome = (
    poCompleted,   // the child ran to completion; see ExitCode
    poTimedOut,    // killed after ATimeoutMs elapsed
    poSpawnError   // the process could not be started (bad path, etc.)
  );

  TToolProcessResult = record
    Outcome: TToolProcessOutcome;
    ExitCode: Cardinal;  // meaningful only when Outcome = poCompleted
    StdOut: string;      // captured standard output (UTF-8 decoded)
    StdErr: string;      // captured standard error (UTF-8 decoded)
    function Ok: Boolean; // poCompleted and ExitCode = 0
    function OutcomeText: string;
  end;

  // Pure subprocess runner as a sealed static namespace (see the unit header).
  // Never instantiated.
  TProcessRunner = class sealed
  public
    // Runs AExePath with AArgs, feeding AStdInput on stdin. AWorkDir = '' keeps the
    // caller's directory. ATimeoutMs = 0 means wait forever. AExePath is resolved
    // against PATH when not absolute (CreateProcess search semantics).
    class function Run(const AExePath, AArgs, AStdInput, AWorkDir: string;
      const ATimeoutMs: Cardinal): TToolProcessResult; static;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows;

{$IF not Declared(GetTickCount64)}
// GetTickCount64 is a Windows Vista API, but Winapi.Windows only began declaring
// it in a Delphi later than 10 Seattle - so on Seattle the call is an undeclared
// identifier even though the function sits in kernel32 on every machine able to
// run the IDE at all.
//
// Declared(), not a CompilerVersion number, on purpose: this asks the compiler in
// hand whether it already has the symbol, which is the actual question. A version
// guard would encode a GUESS about which release added it, and would quietly do
// the wrong thing on either side of a wrong guess.
function GetTickCount64: UInt64; stdcall; external 'kernel32.dll' name 'GetTickCount64';
{$IFEND}

{ TToolProcessResult }

function TToolProcessResult.Ok: Boolean;
begin
  Result := (Outcome = poCompleted) and (ExitCode = 0);
end;

function TToolProcessResult.OutcomeText: string;
begin
  case Outcome of
    poCompleted:  Result := 'completed';
    poTimedOut:   Result := 'timed-out';
    poSpawnError: Result := 'spawn-error';
  else
    Result := 'unknown';
  end;
end;

// Pulls everything currently buffered in AReadPipe into AStream without
// blocking. Returns False when the pipe is broken (child closed its write end).
function _DrainPipe(const AReadPipe: THandle; const AStream: TStream): Boolean;
var
  LAvail, LRead: DWORD;
  LBuf: array[0..4095] of Byte;
begin
  Result := True;
  while True do
  begin
    LAvail := 0;
    if not PeekNamedPipe(AReadPipe, nil, 0, nil, @LAvail, nil) then
      Exit(False); // pipe broken => child gone
    if LAvail = 0 then
      Break;
    if LAvail > Cardinal(Length(LBuf)) then
      LAvail := Length(LBuf);
    if not ReadFile(AReadPipe, LBuf, LAvail, LRead, nil) or (LRead = 0) then
      Exit(False);
    AStream.WriteBuffer(LBuf, LRead);
  end;
end;

function _Decode(const AStream: TBytesStream): string;
begin
  Result := TEncoding.UTF8.GetString(AStream.Bytes, 0, AStream.Size);
end;

function _Fail(const AOutcome: TToolProcessOutcome): TToolProcessResult;
begin
  Result := Default(TToolProcessResult);
  Result.Outcome := AOutcome;
end;

class function TProcessRunner.Run(const AExePath, AArgs, AStdInput, AWorkDir: string;
  const ATimeoutMs: Cardinal): TToolProcessResult;
var
  LSa: TSecurityAttributes;
  LOutR, LOutW, LErrR, LErrW, LInR, LInW: THandle;
  LStartup: TStartupInfo;
  LProc: TProcessInformation;
  LCmd, LWorkDir: string;
  LWorkPtr: PChar;
  LOutBuf, LErrBuf: TBytesStream;
  LInBytes: TBytes;
  LWritten: DWORD;
  LStart: UInt64;
  LWait: DWORD;
  LExit: DWORD;
  LAlive: Boolean;
begin
  LSa := Default(TSecurityAttributes);
  LSa.nLength := SizeOf(LSa);
  LSa.bInheritHandle := True;

  // Three pipes; our ends must NOT be inheritable, the child ends must be.
  if not CreatePipe(LOutR, LOutW, @LSa, 0) then Exit(_Fail(poSpawnError));
  if not CreatePipe(LErrR, LErrW, @LSa, 0) then
  begin CloseHandle(LOutR); CloseHandle(LOutW); Exit(_Fail(poSpawnError)); end;
  if not CreatePipe(LInR, LInW, @LSa, 0) then
  begin
    CloseHandle(LOutR); CloseHandle(LOutW);
    CloseHandle(LErrR); CloseHandle(LErrW);
    Exit(_Fail(poSpawnError));
  end;
  SetHandleInformation(LOutR, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(LErrR, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(LInW, HANDLE_FLAG_INHERIT, 0);

  LStartup := Default(TStartupInfo);
  LStartup.cb := SizeOf(LStartup);
  LStartup.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  LStartup.wShowWindow := SW_HIDE;
  LStartup.hStdOutput := LOutW;
  LStartup.hStdError := LErrW;
  LStartup.hStdInput := LInR;

  if AArgs <> '' then
    LCmd := '"' + AExePath + '" ' + AArgs
  else
    LCmd := '"' + AExePath + '"';
  LWorkDir := AWorkDir;
  if LWorkDir <> '' then LWorkPtr := PChar(LWorkDir) else LWorkPtr := nil;

  LProc := Default(TProcessInformation);
  // UniqueString: CreateProcess may write to the command-line buffer.
  UniqueString(LCmd);
  if not CreateProcess(nil, PChar(LCmd), nil, nil, True,
    CREATE_NO_WINDOW, nil, LWorkPtr, LStartup, LProc) then
  begin
    CloseHandle(LOutR); CloseHandle(LOutW);
    CloseHandle(LErrR); CloseHandle(LErrW);
    CloseHandle(LInR); CloseHandle(LInW);
    Exit(_Fail(poSpawnError));
  end;

  // Parent does not need the child ends.
  CloseHandle(LOutW);
  CloseHandle(LErrW);
  CloseHandle(LInR);

  LOutBuf := TBytesStream.Create;
  LErrBuf := TBytesStream.Create;
  try
    // Feed stdin (bounded) then close so the child sees EOF.
    if AStdInput <> '' then
    begin
      LInBytes := TEncoding.UTF8.GetBytes(AStdInput);
      WriteFile(LInW, LInBytes[0], Length(LInBytes), LWritten, nil);
    end;
    CloseHandle(LInW);

    Result := Default(TToolProcessResult);
    Result.Outcome := poCompleted;
    LStart := GetTickCount64;
    while True do
    begin
      _DrainPipe(LOutR, LOutBuf);
      _DrainPipe(LErrR, LErrBuf);
      LWait := WaitForSingleObject(LProc.hProcess, 25);
      if LWait = WAIT_OBJECT_0 then
        Break;
      if (ATimeoutMs > 0) and (GetTickCount64 - LStart > ATimeoutMs) then
      begin
        TerminateProcess(LProc.hProcess, 1);
        WaitForSingleObject(LProc.hProcess, 2000);
        Result.Outcome := poTimedOut;
        Break;
      end;
    end;
    // Final drain after exit/kill to catch the tail.
    _DrainPipe(LOutR, LOutBuf);
    _DrainPipe(LErrR, LErrBuf);

    LAlive := Result.Outcome = poCompleted;
    if LAlive and GetExitCodeProcess(LProc.hProcess, LExit) then
      Result.ExitCode := LExit;
    Result.StdOut := _Decode(LOutBuf);
    Result.StdErr := _Decode(LErrBuf);
  finally
    LOutBuf.Free;
    LErrBuf.Free;
    CloseHandle(LOutR);
    CloseHandle(LErrR);
    CloseHandle(LProc.hThread);
    CloseHandle(LProc.hProcess);
  end;
end;

end.
