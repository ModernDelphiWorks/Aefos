unit Aefos.OTA.Chat.Core.ExecutorProbe;

{
  Live MCP-support prober (ESP-005, Epic 4/5, Demand 2/5; ADR-078).

  ProbeMcpSupport spawns a resolved CLI binary with a capability-inspection
  argument (--help), captures stdout+stderr to process completion under a
  bounded timeout, and classifies whether the executor advertises the
  --mcp-config flag the plugin actually emits:

    msSupported   — the captured output advertises --mcp-config.
    msUnsupported — the binary ran to completion without advertising it.
    msUnknown     — empty path, failed spawn, or capture timeout.

  The probe is a wiring-compatibility check (BR-3): it confirms the resolved
  executor accepts the exact wiring the plugin produces, not a vague "mcp"
  mention. It never raises and never blocks indefinitely (BR-4): both pipe
  ends drain while the parent waits, so a full pipe buffer cannot deadlock,
  and a bounded deadline is the backstop.

  A .cmd/.bat target is routed through cmd.exe /c (ADR-077 consequence) so
  CreateProcess can launch an npm-distributed shim.

  C-3: this is a Core service — it spawns a process but touches no
  ToolsAPI/Vcl.* surface. C-4: no System.Net.HttpClient. Windows-only.
}

interface

uses
  Aefos.Provider.Types;

function ProbeMcpSupport(const ABinaryPath: string): TMcpSupport;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.Classes;

{$IF not Declared(GetTickCount64)}
// 10 Seattle's Winapi.Windows does not declare this Vista-era API yet.
// Declared() rather than a CompilerVersion number: it asks the compiler in
// hand whether the symbol exists, instead of encoding a guess about which
// release added it.
function GetTickCount64: UInt64; stdcall; external 'kernel32.dll' name 'GetTickCount64';
{$IFEND}

const
  CAPABILITY_ARG = '--help';
  MCP_CONFIG_FLAG = '--mcp-config';
  PROBE_TIMEOUT_MS = 5000;
  PROBE_POLL_MS = 20;
  PROBE_BUFFER_SIZE = 4096;

procedure _CloseHandleSafe(var AHandle: THandle);
begin
  if (AHandle <> 0) and (AHandle <> INVALID_HANDLE_VALUE) then
  begin
    CloseHandle(AHandle);
    AHandle := INVALID_HANDLE_VALUE;
  end;
end;

function _NeedsCommandProcessor(const ABinaryPath: string): Boolean;
var
  LExt: string;
begin
  LExt := LowerCase(ExtractFileExt(ABinaryPath));
  Result := (LExt = '.cmd') or (LExt = '.bat');
end;

function _BuildProbeCommandLine(const ABinaryPath: string): string;
begin
  // A .cmd/.bat shim cannot be launched directly by CreateProcess — it must
  // run under the command processor (ADR-077 / R-2).
  if _NeedsCommandProcessor(ABinaryPath) then
    Result := Format('cmd.exe /c ""%s" %s"', [ABinaryPath, CAPABILITY_ARG])
  else
    Result := Format('"%s" %s', [ABinaryPath, CAPABILITY_ARG]);
end;

function _AdvertisesMcpConfig(const AOutput: string): Boolean;
begin
  Result := ContainsText(AOutput, MCP_CONFIG_FLAG);
end;

function _CreateProbePipes(out ARead, AWrite, AStdIn: THandle): Boolean;
var
  LSecurity: TSecurityAttributes;
begin
  Result := False;
  ARead := INVALID_HANDLE_VALUE;
  AWrite := INVALID_HANDLE_VALUE;
  AStdIn := INVALID_HANDLE_VALUE;
  ZeroMemory(@LSecurity, SizeOf(LSecurity));
  LSecurity.nLength := SizeOf(LSecurity);
  LSecurity.bInheritHandle := True;
  if not CreatePipe(ARead, AWrite, @LSecurity, 0) then
    Exit;
  // The parent keeps the read end private; the child must not inherit it.
  SetHandleInformation(ARead, HANDLE_FLAG_INHERIT, 0);
  AStdIn := CreateFile('NUL', GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE, @LSecurity, OPEN_EXISTING, 0, 0);
  Result := AStdIn <> INVALID_HANDLE_VALUE;
end;

function _SpawnProbe(const ABinaryPath: string; const AStdOut,
  AStdIn: THandle; out AProcess: THandle): Boolean;
var
  LStartup: TStartupInfo;
  LProcInfo: TProcessInformation;
  LCommandLine: string;
begin
  AProcess := INVALID_HANDLE_VALUE;
  ZeroMemory(@LStartup, SizeOf(LStartup));
  LStartup.cb := SizeOf(LStartup);
  LStartup.dwFlags := STARTF_USESTDHANDLES;
  LStartup.hStdInput := AStdIn;
  LStartup.hStdOutput := AStdOut;
  LStartup.hStdError := AStdOut;
  LCommandLine := _BuildProbeCommandLine(ABinaryPath);
  UniqueString(LCommandLine);
  ZeroMemory(@LProcInfo, SizeOf(LProcInfo));
  Result := CreateProcess(nil, PChar(LCommandLine), nil, nil, True,
    CREATE_NO_WINDOW, nil, nil, LStartup, LProcInfo);
  if not Result then
    Exit;
  AProcess := LProcInfo.hProcess;
  CloseHandle(LProcInfo.hThread);
end;

procedure _DrainAvailable(const APipe: THandle; const AStream: TMemoryStream);
var
  LBuffer: array[0..PROBE_BUFFER_SIZE - 1] of Byte;
  LAvailable: DWORD;
  LRead: DWORD;
begin
  LAvailable := 0;
  while PeekNamedPipe(APipe, nil, 0, nil, @LAvailable, nil)
    and (LAvailable > 0) do
  begin
    LRead := 0;
    if not ReadFile(APipe, LBuffer, PROBE_BUFFER_SIZE, LRead, nil) then
      Break;
    if LRead = 0 then
      Break;
    AStream.WriteBuffer(LBuffer, LRead);
  end;
end;

function _DecodeStream(const AStream: TMemoryStream): string;
var
  LBytes: TBytes;
begin
  if AStream.Size = 0 then
    Exit('');
  // Probe output is always small (< 64 KB) — the Int64 stream size casts
  // safely to the NativeInt SetLength/Move expect on Win32.
  SetLength(LBytes, Integer(AStream.Size));
  Move(AStream.Memory^, LBytes[0], Integer(AStream.Size));
  Result := TEncoding.UTF8.GetString(LBytes);
end;

function _CaptureToCompletion(const AProcess, APipe: THandle;
  out ACompleted: Boolean): string;
var
  LStream: TMemoryStream;
  LDeadline: UInt64;
begin
  ACompleted := False;
  LStream := TMemoryStream.Create;
  try
    LDeadline := GetTickCount64 + PROBE_TIMEOUT_MS;
    repeat
      _DrainAvailable(APipe, LStream);
      if WaitForSingleObject(AProcess, 0) = WAIT_OBJECT_0 then
      begin
        ACompleted := True;
        Break;
      end;
      if GetTickCount64 >= LDeadline then
      begin
        TerminateProcess(AProcess, 1);
        Break;
      end;
      Sleep(PROBE_POLL_MS);
    until False;
    _DrainAvailable(APipe, LStream);
    Result := _DecodeStream(LStream);
  finally
    LStream.Free;
  end;
end;

function _RunCapability(const ABinaryPath: string; out AOutput: string;
  out ACompleted: Boolean): Boolean;
var
  LRead, LWrite, LStdIn, LProcess: THandle;
begin
  Result := False;
  AOutput := '';
  ACompleted := False;
  if not _CreateProbePipes(LRead, LWrite, LStdIn) then
    Exit;
  try
    if not _SpawnProbe(ABinaryPath, LWrite, LStdIn, LProcess) then
      Exit;
    // Release the parent's copies of the child-side handles so a closed
    // write end is observable once the child exits.
    _CloseHandleSafe(LWrite);
    _CloseHandleSafe(LStdIn);
    Result := True;
    try
      AOutput := _CaptureToCompletion(LProcess, LRead, ACompleted);
    finally
      _CloseHandleSafe(LProcess);
    end;
  finally
    _CloseHandleSafe(LWrite);
    _CloseHandleSafe(LStdIn);
    _CloseHandleSafe(LRead);
  end;
end;

function ProbeMcpSupport(const ABinaryPath: string): TMcpSupport;
var
  LOutput: string;
  LCompleted: Boolean;
begin
  Result := msUnknown;
  if ABinaryPath = '' then
    Exit;
  try
    if not _RunCapability(ABinaryPath, LOutput, LCompleted) then
      Exit;
    if not LCompleted then
      Exit;
    if _AdvertisesMcpConfig(LOutput) then
      Result := msSupported
    else
      Result := msUnsupported;
  except
    Result := msUnknown;
  end;
end;

end.
