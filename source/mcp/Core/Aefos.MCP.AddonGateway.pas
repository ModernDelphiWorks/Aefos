unit Aefos.MCP.AddonGateway;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Addon-MCP gateway (ESP: `aefos install <mcp>` -> EVERY agent gets the tools).

  The problem this solves: an installed addon-MCP server lands in the aggregate
  %USERPROFILE%\.aefos\addons\mcp-servers.json, but historically only the Claude
  CLI driver consumed it (--mcp-config + a per-CLI --allowedTools loop). Codex,
  Gemini, Ollama, and any future executor never saw it, because the wiring lived
  in each CLI's provider. That does not scale.

  The fix lives at the ONE place every executor already talks to: the in-process
  TMCPServer (the `aefos` server, shared by Chat, Terminal and the Lazarus
  McpHost). This gateway is a small MCP CLIENT of the installed addon servers:
  it spawns each one as an stdio subprocess, handshakes, lists its tools, and
  re-exposes them on the aefos server's OWN tools/list under a namespaced name
  (<serverkey>__<toolname>). On tools/call the server routes a namespaced call
  back to the owning child. Because every executor connects to the aefos server,
  every executor gets the addon tools for free -- zero per-CLI code, and a new
  executor inherits it automatically.

  Injection (mirrors the FViewProvider/SetViewProvider DI seam): the host
  composition root calls TMCPServer.SetToolGateway(TMCPAddonGateway.Create).
  nil = off (the default), so the pure suites and a standalone terminal never
  spawn a child.

  Lifecycle / teardown (CLAUDE.md IDE-UNLOAD rules): children are spawned LAZILY
  on the first tools/list, kept for the session, and killed in Shutdown -- which
  TMCPServer.Stop/Destroy calls. A child that outlives the BPL unmap is a crash;
  Shutdown terminates every child under a lock, and each child is reference-
  counted so an in-flight tools/call keeps its child object alive until the call
  returns (Terminate merely flags + TerminateProcess -- it never frees). Every
  method degrades gracefully and NEVER raises across the MCP boundary.

  Consent is preserved: an addon's own guard (e.g. the Desktop MCP physical-key
  consent) runs INSIDE the child. The gateway only forwards frames; it never
  auto-approves.

  RTL-only + Winapi.Windows (no ToolsAPI, no Vcl/FMX): compiles into the RAD
  Studio Aefos.MCP.Core BPL AND the Lazarus FPC package. The stdio framing
  mirrors Aefos.MCP.Transport.Stdio (server side) and the child spawn mirrors the
  proven pipe/CreateProcessW pattern in
  Aefos.OTA.Chat.Core.Dispatcher.ProcessRunner.
}

interface

uses
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  Aefos.Compat.Json,
  Aefos.MCP.Types;

type
  // A spawned addon-MCP server this gateway speaks to over its stdin/stdout with
  // LF-delimited JSON-RPC frames. Reference-counted so an in-flight tools/call
  // can hold it alive across the gateway's Shutdown (which only flags + kills the
  // process). Every method is synchronous and internally serialised (FIoLock).
  IMCPStdioChild = interface
    ['{4F6B2E91-8C3D-4A57-9B10-6E2F7A0D4C81}']
    // Spawns ACommand with AArgs, working dir ACwd (empty = inherit), and the
    // pre-built AEnvBlock (empty = inherit the parent environment). False on
    // spawn failure. Never raises.
    function Spawn(const ACommand: string; const AArgs: TArray<string>;
      const ACwd, AEnvBlock: string): Boolean;
    // initialize -> read -> notifications/initialized. False when the server is
    // unreachable/incompatible within ATimeoutMs.
    function Handshake(const ATimeoutMs: Cardinal): Boolean;
    // tools/list -> the raw "tools" JSON array string. False on failure.
    function ListTools(out AToolsArrayJson: string;
      const ATimeoutMs: Cardinal): Boolean;
    // tools/call -> the child's raw JSON-RPC `result` object, verbatim (content,
    // structuredContent, isError all preserved). A JSON-RPC error answer is
    // turned into an isError text result so the agent still gets feedback. False
    // only on transport death.
    function CallTool(const AOriginalName, AArgumentsJson: string;
      const ATimeoutMs: Cardinal; out AResultObjJson: string): Boolean;
    // Best-effort: flag dead + TerminateProcess. Idempotent; never raises; never
    // frees (the destructor closes handles once the last ref is gone).
    procedure Terminate;
    function Alive: Boolean;
  end;

  // One re-exposed addon tool: which child owns it and its ORIGINAL name.
  TMCPAddonRoute = record
    Child: IMCPStdioChild;
    ToolName: string;
  end;

  // Injectable addon-MCP gateway. See the unit header. nil injection = off.
  TMCPAddonGateway = class(TInterfacedObject, IMCPToolGateway)
  private
    FLock: TCriticalSection;
    FStarted: Boolean;
    FShutDown: Boolean;
    FChildren: TList<IMCPStdioChild>;
    FRoutes: TDictionary<string, TMCPAddonRoute>;
    FListJson: string;
    procedure _EnsureStarted;   // caller holds FLock
    procedure _Discover;        // caller holds FLock
    procedure _StartServer(const AServerKey: string;
      const AServerObj: TJSONObject; const AListArray: TJSONArray);
    class function _AggregateJson: string; static;
    class function _SanitizeKey(const AKey: string): string; static;
    class function _BuildEnvBlock(const AEnvObj: TJSONObject;
      const AHostRenders: Boolean): string; static;
  private
    FHostRenders: Boolean;
  public
    { AHostRenders: does THIS host draw what the child reports? Only the chat
      panel does -- it feeds the visual scanner card from these very calls. The
      terminal hosts the same gateway and draws nothing, and the Lazarus edition
      is its own case. The flag reaches the child as an env var, so a tool can
      say "someone is watching" only where that is TRUE. Defaults to False: a
      host that does not say so does not claim it. }
    constructor Create(const AHostRenders: Boolean = False);
    destructor Destroy; override;
    // IMCPToolGateway
    function ListToolsJson: string;
    function OwnsTool(const AToolName: string): Boolean;
    function CallTool(const AToolName, AArgumentsJson: string): string;
    procedure Shutdown;
  end;

implementation

{$IF not Declared(GetTickCount64)}
// 10 Seattle's Winapi.Windows does not declare this Vista-era API yet.
// Declared() rather than a CompilerVersion number: it asks the compiler in
// hand whether the symbol exists, instead of encoding a guess about which
// release added it.
function GetTickCount64: UInt64; stdcall; external 'kernel32.dll' name 'GetTickCount64';
{$IFEND}

var
  // --- the trace ----------------------------------------------------------
  // The owner counted his own processes before we did: two requests, two
  // AefosDesktopMcp.exe. They die with the IDE (the kill-on-job-close job below
  // is doing its work, measured), but one child per request instead of one
  // reused child is a pile that grows all session.
  //
  // Whose child it is decides the fix, and only the spawn site can say. So
  // every child this gateway starts, hands back, or kills writes one line to
  // %APPDATA%\Aefos\aefos-gateway-trace.log with its PID -- the same number
  // Task Manager shows -- and the server key that asked for it. A gateway that
  // is built twice per turn shows up as two `gw.create` lines; a CLI starting
  // its own servers shows up as PIDs that never appear here at all.
  //
  // Same contract as the HTTP transport's trace: off with AEFOS_GATEWAY_TRACE=0,
  // one open-append-close per line under a lock, and it never raises.
  GGwTraceLock: TRTLCriticalSection;
  GGwTraceState: Integer;   // -1 not asked yet, 0 off, 1 on
  GGwTracePath: string;
  GGwSeq: Integer;          // gateway instances built in this process

const
  CGatewayProtocolVersion = '2025-06-18';
  CGatewayClientName      = 'aefos-gateway';
  CNamespaceSep           = '__';
  CHandshakeTimeoutMs     = 10000;
  CListTimeoutMs          = 10000;
  // Generous: an addon tool may block on a human consent gate (Desktop MCP
  // physical key). A bounded read still protects against a dead child.
  CCallTimeoutMs          = 300000;
  CMaxNotificationsSkip   = 64;

// One line, appended, never raising -- see the declarations above for why this
// exists and what it has to answer.
procedure _GwTrace(const AStep, ADetail: string);
var
  LDir, LLine: string;
  LFlag: string;
  LBytes: TBytes;
  LMode: Word;
  LStream: TFileStream;
begin
  if GGwTraceState < 0 then
  begin
    // Qualified: `uses Windows` hijacks the bare name, the same trap this unit
    // already documents further down.
    LFlag := Trim(SysUtils.GetEnvironmentVariable('AEFOS_GATEWAY_TRACE'));
    if (LFlag = '0') or SameText(LFlag, 'off') then
      GGwTraceState := 0
    else
      GGwTraceState := 1;
  end;
  if GGwTraceState <> 1 then
    Exit;
  EnterCriticalSection(GGwTraceLock);
  try
    try
      if GGwTracePath = '' then
      begin
        LDir := SysUtils.GetEnvironmentVariable('APPDATA');
        if LDir = '' then
          Exit;
        LDir := IncludeTrailingPathDelimiter(LDir) + 'Aefos';
        if not DirectoryExists(LDir) then
          ForceDirectories(LDir);
        GGwTracePath := IncludeTrailingPathDelimiter(LDir) +
          'aefos-gateway-trace.log';
      end;
      LLine := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now) +
        Format(' t=%d %s %s', [GetCurrentThreadId, AStep, ADetail]) + sLineBreak;
      LBytes := TEncoding.UTF8.GetBytes(LLine);
      if FileExists(GGwTracePath) then
        LMode := fmOpenWrite or fmShareDenyWrite
      else
        LMode := fmCreate or fmShareDenyWrite;
      LStream := TFileStream.Create(GGwTracePath, LMode);
      try
        LStream.Seek(0, soEnd);
        LStream.WriteBuffer(LBytes[0], Length(LBytes));
      finally
        LStream.Free;
      end;
    except
      // A diagnostic that can take the gateway down is worse than none.
    end;
  finally
    LeaveCriticalSection(GGwTraceLock);
  end;
end;

type
  TMCPStdioChild = class(TInterfacedObject, IMCPStdioChild)
  private
    FIoLock: TCriticalSection;
    FProcess: THandle;
    FThreadHandle: THandle;
    FStdinWrite: THandle;    // we write the child's stdin
    FStdoutRead: THandle;    // we read the child's stdout
    FTail: TBytes;           // bytes after the last LF, carried between reads
    FNextId: Integer;
    FAlive: Boolean;
    FPid: Cardinal;          // named in the trace, so a line matches Task Manager
    function _SendLine(const ALine: string): Boolean;
    function _ReadLine(out ALine: string; const ADeadline: UInt64): Boolean;
    function _Request(const AMethod, AParamsJson: string;
      const ATimeoutMs: Cardinal; out AResultJson, AErrText: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Spawn(const ACommand: string; const AArgs: TArray<string>;
      const ACwd, AEnvBlock: string): Boolean;
    function Handshake(const ATimeoutMs: Cardinal): Boolean;
    function ListTools(out AToolsArrayJson: string;
      const ATimeoutMs: Cardinal): Boolean;
    function CallTool(const AOriginalName, AArgumentsJson: string;
      const ATimeoutMs: Cardinal; out AResultObjJson: string): Boolean;
    procedure Terminate;
    function Alive: Boolean;
  end;

{ ---- kill-on-close job object --------------------------------------------- }
{
  Shutdown alone CANNOT keep this promise. It is driven from TMCPServer.Stop /
  Destroy, so it runs only when the host shuts down in an orderly way -- and the
  IDE does not always get that far. A crash, an access violation during teardown,
  or a Task-Manager kill leaves the child running with nobody left to terminate
  it, and the user accumulates one stray process per session.

  Observed 2026-07-27: an AefosDesktopMcp.exe from a crashed IDE session was
  still alive hours later, long after the IDE that spawned it was gone.

  So the guarantee is moved to where it cannot be skipped: every child is
  assigned to a Windows job object created with KILL_ON_JOB_CLOSE. When the last
  handle to that job closes -- which the kernel does when our process dies, by
  ANY route -- every process in the job is killed. Shutdown stays exactly as it
  was (orderly, prompt, and it still runs first); this is the floor underneath it.

  Best-effort by design: a failure to build or assign the job never fails the
  spawn. Losing the addon tools would be a worse outcome than a possible stray
  process, and Shutdown still covers the orderly path.

  Both editions: this unit is shared Core. Delphi needs it at least as much --
  there a child outliving the BPL unmap is the crash class CLAUDE.md's
  IDE-UNLOAD rules exist to prevent.
}
const
  { Frozen Win32 ABI, declared inline: FPC's and Delphi's Windows units do not
    agree on which of these they expose. }
  CJobObjectExtendedLimitInformation = 9;
  CJobObjectLimitKillOnJobClose      = $00002000;

type
  TAefosJobIoCounters = record
    ReadOperationCount: UInt64;
    WriteOperationCount: UInt64;
    OtherOperationCount: UInt64;
    ReadTransferCount: UInt64;
    WriteTransferCount: UInt64;
    OtherTransferCount: UInt64;
  end;

  TAefosJobBasicLimitInfo = record
    PerProcessUserTimeLimit: Int64;
    PerJobUserTimeLimit: Int64;
    LimitFlags: DWORD;
    MinimumWorkingSetSize: NativeUInt;
    MaximumWorkingSetSize: NativeUInt;
    ActiveProcessLimit: DWORD;
    Affinity: NativeUInt;
    PriorityClass: DWORD;
    SchedulingClass: DWORD;
  end;

  TAefosJobExtendedLimitInfo = record
    BasicLimitInformation: TAefosJobBasicLimitInfo;
    IoInfo: TAefosJobIoCounters;
    ProcessMemoryLimit: NativeUInt;
    JobMemoryLimit: NativeUInt;
    PeakProcessMemoryUsed: NativeUInt;
    PeakJobMemoryUsed: NativeUInt;
  end;

function _CreateJobObjectW(lpJobAttributes: Pointer;
  lpName: PWideChar): THandle; stdcall;
  external 'kernel32.dll' name 'CreateJobObjectW';
function _SetInformationJobObject(hJob: THandle; AInfoClass: DWORD;
  lpInfo: Pointer; cbInfo: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'SetInformationJobObject';
function _AssignProcessToJobObject(hJob, hProcess: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'AssignProcessToJobObject';

var
  GJobLock: TCriticalSection = nil;
  GChildJob: THandle = 0;

// The process-wide kill-on-close job, built on first use. 0 = unavailable, in
// which case the caller simply skips assignment.
function _AefosChildJob: THandle;
var
  LInfo: TAefosJobExtendedLimitInfo;
begin
  Result := 0;
  if GJobLock = nil then
    Exit;
  GJobLock.Enter;
  try
    if GChildJob = 0 then
    begin
      GChildJob := _CreateJobObjectW(nil, nil);
      if GChildJob <> 0 then
      begin
        ZeroMemory(@LInfo, SizeOf(LInfo));
        LInfo.BasicLimitInformation.LimitFlags := CJobObjectLimitKillOnJobClose;
        // A job WITHOUT the kill flag is worse than no job: it would look like
        // the guarantee holds while children still outlive us. Drop it instead.
        if not _SetInformationJobObject(GChildJob,
             CJobObjectExtendedLimitInformation, @LInfo, SizeOf(LInfo)) then
        begin
          CloseHandle(GChildJob);
          GChildJob := 0;
        end;
      end;
    end;
    Result := GChildJob;
  finally
    GJobLock.Leave;
  end;
end;

{ ---- small local helpers -------------------------------------------------- }

procedure _CloseHandleSafe(var AHandle: THandle);
begin
  if (AHandle <> 0) and (AHandle <> INVALID_HANDLE_VALUE) then
    CloseHandle(AHandle);
  AHandle := INVALID_HANDLE_VALUE;
end;

// Quotes a single command-line argument for CreateProcessW when it is empty or
// carries whitespace / a quote. Sufficient for the paths + simple flags an MCP
// server config uses (a raw MCP spawn -- no shell -- makes fancy escaping moot).
function _QuoteArg(const AArg: string): string;
var
  LNeedsQuote: Boolean;
  LIndex: Integer;
begin
  LNeedsQuote := AArg = '';
  for LIndex := 1 to Length(AArg) do
    if (AArg[LIndex] = ' ') or (AArg[LIndex] = #9) or (AArg[LIndex] = '"') then
    begin
      LNeedsQuote := True;
      Break;
    end;
  if not LNeedsQuote then
    Exit(AArg);
  Result := '"' + StringReplace(AArg, '"', '\"', [rfReplaceAll]) + '"';
end;

function _BuildCommandLine(const ACommand: string;
  const AArgs: TArray<string>): string;
var
  LIndex: Integer;
begin
  Result := _QuoteArg(ACommand);
  for LIndex := 0 to High(AArgs) do
    Result := Result + ' ' + _QuoteArg(AArgs[LIndex]);
end;

// True when ALine is a JSON-RPC NOTIFICATION (a method, no id) the server may
// broadcast (e.g. notifications/resources/updated) between our request and its
// response -- it must be skipped, not mistaken for the response.
function _IsNotificationFrame(const ALine: string): Boolean;
var
  LRoot: TJSONValue;
begin
  Result := False;
  LRoot := TJSONObject.ParseJSONValue(ALine);
  try
    if not (LRoot is TJSONObject) then
      Exit;
    Result := (TJSONObject(LRoot).GetValue('id') = nil) and
      (TJSONObject(LRoot).GetValue('method') <> nil);
  finally
    LRoot.Free;
  end;
end;

{ TMCPStdioChild }

constructor TMCPStdioChild.Create;
begin
  inherited Create;
  FIoLock := TCriticalSection.Create;
  FProcess := 0;
  FThreadHandle := 0;
  FStdinWrite := INVALID_HANDLE_VALUE;
  FStdoutRead := INVALID_HANDLE_VALUE;
  FNextId := 0;
  FAlive := False;
end;

destructor TMCPStdioChild.Destroy;
begin
  // Runs only when the last interface ref is gone -- so no worker is inside a
  // read. Now the handles are safe to close and the process safe to reap.
  try
    FAlive := False;
    if (FProcess <> 0) and (FProcess <> INVALID_HANDLE_VALUE) then
    begin
      if WaitForSingleObject(FProcess, 0) <> WAIT_OBJECT_0 then
        TerminateProcess(FProcess, 0);
      WaitForSingleObject(FProcess, 1000);
    end;
  except
  end;
  _CloseHandleSafe(FStdinWrite);
  _CloseHandleSafe(FStdoutRead);
  _CloseHandleSafe(FThreadHandle);
  _CloseHandleSafe(FProcess);
  FIoLock.Free;
  inherited;
end;

function TMCPStdioChild.Alive: Boolean;
begin
  Result := FAlive;
end;

function TMCPStdioChild.Spawn(const ACommand: string;
  const AArgs: TArray<string>; const ACwd, AEnvBlock: string): Boolean;
var
  LSec: TSecurityAttributes;
  LChildStdinRead, LChildStdoutWrite, LNul: THandle;
  LStartup: TStartupInfoW;
  LProcInfo: TProcessInformation;
  LCmdLine: string;
  LCwd, LEnv: PWideChar;
  LFlags: DWORD;
  LJob: THandle;
begin
  Result := False;
  LChildStdinRead := INVALID_HANDLE_VALUE;
  LChildStdoutWrite := INVALID_HANDLE_VALUE;
  LNul := INVALID_HANDLE_VALUE;
  try
    ZeroMemory(@LSec, SizeOf(LSec));
    LSec.nLength := SizeOf(LSec);
    LSec.bInheritHandle := True;
    LSec.lpSecurityDescriptor := nil;

    // stdin: child reads LChildStdinRead, we write FStdinWrite.
    if not CreatePipe(LChildStdinRead, FStdinWrite, @LSec, 0) then
      Exit;
    SetHandleInformation(FStdinWrite, HANDLE_FLAG_INHERIT, 0);
    // stdout: child writes LChildStdoutWrite, we read FStdoutRead.
    if not CreatePipe(FStdoutRead, LChildStdoutWrite, @LSec, 0) then
      Exit;
    SetHandleInformation(FStdoutRead, HANDLE_FLAG_INHERIT, 0);
    // stderr: discard to NUL (inheritable) so an addon logging to stderr can
    // never fill a pipe we do not drain and deadlock. Diagnostics loss is
    // acceptable for the gateway; stdout is the JSON-RPC protocol channel.
    LNul := CreateFileW('NUL', GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE, @LSec, OPEN_EXISTING, 0, 0);

    ZeroMemory(@LStartup, SizeOf(LStartup));
    LStartup.cb := SizeOf(LStartup);
    LStartup.dwFlags := STARTF_USESTDHANDLES;
    LStartup.hStdInput := LChildStdinRead;
    LStartup.hStdOutput := LChildStdoutWrite;
    if LNul <> INVALID_HANDLE_VALUE then
      LStartup.hStdError := LNul
    else
      LStartup.hStdError := LChildStdoutWrite;

    ZeroMemory(@LProcInfo, SizeOf(LProcInfo));
    LCmdLine := _BuildCommandLine(ACommand, AArgs);
    UniqueString(LCmdLine);
    if ACwd = '' then
      LCwd := nil
    else
      LCwd := PWideChar(ACwd);
    // CREATE_SUSPENDED so the child is assigned to the kill-on-close job BEFORE
    // it runs a single instruction. Assigning after it is already running leaves
    // a window in which it could spawn a grandchild outside the job -- and that
    // grandchild would survive us. The thread is resumed below, on every path.
    LFlags := CREATE_NO_WINDOW or CREATE_SUSPENDED;
    if AEnvBlock = '' then
      LEnv := nil
    else
    begin
      LEnv := PWideChar(AEnvBlock);
      LFlags := LFlags or CREATE_UNICODE_ENVIRONMENT;
    end;

    // CreateProcessW (not the unqualified CreateProcess): under {$mode
    // delphiunicode} PChar is PWideChar, and FPC maps the unqualified name to
    // the ANSI entry point. On Delphi the W name is already the default -- same
    // API both builds.
    if not CreateProcessW(nil, PWideChar(LCmdLine), nil, nil, True,
      LFlags, LEnv, LCwd, LStartup, LProcInfo) then
      Exit;

    FProcess := LProcInfo.hProcess;
    FThreadHandle := LProcInfo.hThread;
    FPid := LProcInfo.dwProcessId;
    FAlive := True;
    _GwTrace('spawn', Format('pid=%d cmd=%s', [FPid, LCmdLine]));

    // The child EXISTS but is still suspended, so from here on a raised
    // exception would strand a parked process. Reaping it must not be delegated
    // to the implicit "last interface ref drops -> destructor -> TerminateProcess"
    // chain: that depends on how the CALLER holds this object, which this method
    // cannot see. Own the failure locally and hand back a clean False.
    try
      // Kernel-enforced cleanup: from here the child dies with us no matter HOW
      // we die. Best-effort -- if the job is unavailable we still run the child
      // and fall back to Shutdown's orderly kill.
      LJob := _AefosChildJob;
      if LJob <> 0 then
        _AssignProcessToJobObject(LJob, FProcess);

      // Always resume, including when the assignment above failed: a child left
      // suspended would hang every handshake read until the deadline.
      ResumeThread(FThreadHandle);
      Result := True;
    except
      FAlive := False;
      TerminateProcess(FProcess, 0);
      _CloseHandleSafe(FThreadHandle);
      _CloseHandleSafe(FProcess);
      Result := False; // the finally below drops our pipe ends too
    end;
  finally
    // The child owns its copies of these ends now; the parent must drop them so
    // an EOF actually propagates when either side closes.
    _CloseHandleSafe(LChildStdinRead);
    _CloseHandleSafe(LChildStdoutWrite);
    _CloseHandleSafe(LNul);
    if not Result then
    begin
      _CloseHandleSafe(FStdinWrite);
      _CloseHandleSafe(FStdoutRead);
    end;
  end;
end;

function TMCPStdioChild._SendLine(const ALine: string): Boolean;
var
  LBytes: TBytes;
  LWritten: DWORD;
  LTotal: Integer;
begin
  Result := False;
  if FStdinWrite = INVALID_HANDLE_VALUE then
    Exit;
  LBytes := TEncoding.UTF8.GetBytes(ALine + #10);
  LTotal := 0;
  while LTotal < Length(LBytes) do
  begin
    if not WriteFile(FStdinWrite, LBytes[LTotal], Length(LBytes) - LTotal,
      LWritten, nil) then
      Exit;
    if LWritten = 0 then
      Exit;
    Inc(LTotal, Integer(LWritten));
  end;
  Result := True;
end;

function TMCPStdioChild._ReadLine(out ALine: string;
  const ADeadline: UInt64): Boolean;
var
  LIndex, LStart: Integer;
  LChunk: array[0..8191] of Byte;
  LAvail, LRead: DWORD;
  LOld: Integer;
begin
  ALine := '';
  repeat
    if not FAlive then
      Exit(False);
    // A whole frame may already sit in the tail from a previous read.
    for LIndex := 0 to High(FTail) do
      if FTail[LIndex] = 10 then
      begin
        ALine := TEncoding.UTF8.GetString(FTail, 0, LIndex);
        if (ALine <> '') and (ALine[Length(ALine)] = #13) then
          SetLength(ALine, Length(ALine) - 1);
        LStart := LIndex + 1;
        FTail := Copy(FTail, LStart, Length(FTail) - LStart);
        Exit(True);
      end;
    // Non-blocking: only ReadFile what is already buffered, so a slow/parked
    // child cannot hang this call past the deadline.
    LAvail := 0;
    if not PeekNamedPipe(FStdoutRead, nil, 0, nil, @LAvail, nil) then
      Exit(False); // pipe broken / child gone
    if LAvail > 0 then
    begin
      if LAvail > DWORD(SizeOf(LChunk)) then
        LAvail := SizeOf(LChunk);
      if not ReadFile(FStdoutRead, LChunk[0], LAvail, LRead, nil) then
        Exit(False);
      if LRead = 0 then
        Exit(False);
      LOld := Length(FTail);
      SetLength(FTail, LOld + Integer(LRead));
      Move(LChunk[0], FTail[LOld], LRead);
      Continue; // re-scan for a full line immediately
    end;
    // Nothing available: the child may have exited with no trailing newline.
    if (FProcess <> 0) and (FProcess <> INVALID_HANDLE_VALUE) and
      (WaitForSingleObject(FProcess, 0) = WAIT_OBJECT_0) then
      Exit(False);
    if GetTickCount64 >= ADeadline then
      Exit(False);
    Sleep(5);
  until False;
end;

function TMCPStdioChild._Request(const AMethod, AParamsJson: string;
  const ATimeoutMs: Cardinal; out AResultJson, AErrText: string): Boolean;
var
  LRoot, LObj, LErr: TJSONObject;
  LParams, LIdVal, LResult, LLineRoot: TJSONValue;
  LId: Integer;
  LFrame, LLine: string;
  LDeadline: UInt64;
  LSkipped: Integer;
begin
  Result := False;
  AResultJson := '';
  AErrText := '';
  Inc(FNextId);
  LId := FNextId;
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('jsonrpc', '2.0');
    LRoot.AddPair('id', TJSONNumber.Create(LId));
    LRoot.AddPair('method', AMethod);
    LParams := TJSONObject.ParseJSONValue(AParamsJson);
    if not (LParams is TJSONObject) then
    begin
      LParams.Free; // nil-safe
      LParams := TJSONObject.Create;
    end;
    LRoot.AddPair('params', LParams);
    LFrame := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
  if not _SendLine(LFrame) then
  begin
    AErrText := 'addon MCP send failed (child gone)';
    Exit;
  end;
  LDeadline := GetTickCount64 + ATimeoutMs;
  LSkipped := 0;
  repeat
    if not _ReadLine(LLine, LDeadline) then
    begin
      AErrText := 'addon MCP server did not answer';
      Exit;
    end;
    if _IsNotificationFrame(LLine) then
    begin
      Inc(LSkipped);
      if LSkipped > CMaxNotificationsSkip then
      begin
        AErrText := 'addon MCP server sent only notifications';
        Exit;
      end;
      Continue;
    end;
    LLineRoot := TJSONObject.ParseJSONValue(LLine);
    try
      if not (LLineRoot is TJSONObject) then
        Continue; // junk frame; keep looking
      LObj := TJSONObject(LLineRoot);
      LIdVal := LObj.GetValue('id');
      if not (LIdVal is TJSONNumber) or (TJSONNumber(LIdVal).AsInt <> LId) then
        Continue; // response for another id; skip
      LErr := nil;
      if LObj.GetValue('error') is TJSONObject then
        LErr := TJSONObject(LObj.GetValue('error'));
      if LErr <> nil then
      begin
        if LErr.GetValue('message') is TJSONString then
          AErrText := TJSONString(LErr.GetValue('message')).Value
        else
          AErrText := LErr.ToJSON;
        Result := True; // a well-formed error IS a response
        Exit;
      end;
      LResult := LObj.GetValue('result');
      if LResult = nil then
      begin
        AErrText := 'addon MCP response carried neither result nor error';
        Exit;
      end;
      AResultJson := LResult.ToJSON;
      Result := True;
      Exit;
    finally
      LLineRoot.Free;
    end;
  until False;
end;

function TMCPStdioChild.Handshake(const ATimeoutMs: Cardinal): Boolean;
var
  LParams: string;
  LResult, LErr: string;
begin
  FIoLock.Enter;
  try
    LParams :=
      '{"protocolVersion":"' + CGatewayProtocolVersion + '",' +
      '"capabilities":{},' +
      '"clientInfo":{"name":"' + CGatewayClientName + '","version":"1.0.0"}}';
    Result := _Request('initialize', LParams, ATimeoutMs, LResult, LErr) and
      (LErr = '');
    if not Result then
      Exit;
    // Fire-and-forget per spec: the initialized notification gets no response.
    _SendLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  finally
    FIoLock.Leave;
  end;
end;

function TMCPStdioChild.ListTools(out AToolsArrayJson: string;
  const ATimeoutMs: Cardinal): Boolean;
var
  LResult, LErr: string;
  LRoot: TJSONValue;
  LArr: TJSONValue;
begin
  AToolsArrayJson := '';
  FIoLock.Enter;
  try
    Result := _Request('tools/list', '{}', ATimeoutMs, LResult, LErr) and
      (LErr = '');
  finally
    FIoLock.Leave;
  end;
  if not Result then
    Exit;
  LRoot := TJSONObject.ParseJSONValue(LResult);
  try
    Result := False;
    if not (LRoot is TJSONObject) then
      Exit;
    LArr := TJSONObject(LRoot).GetValue('tools');
    if not (LArr is TJSONArray) then
      Exit;
    AToolsArrayJson := LArr.ToJSON;
    Result := True;
  finally
    LRoot.Free;
  end;
end;

function TMCPStdioChild.CallTool(const AOriginalName, AArgumentsJson: string;
  const ATimeoutMs: Cardinal; out AResultObjJson: string): Boolean;
var
  LParamsObj: TJSONObject;
  LArgs: TJSONValue;
  LParamsJson, LResult, LErr: string;
  LFallback: TJSONObject;
  LContent: TJSONArray;
  LItem: TJSONObject;
begin
  AResultObjJson := '';
  LParamsObj := TJSONObject.Create;
  try
    LParamsObj.AddPair('name', AOriginalName);
    LArgs := TJSONObject.ParseJSONValue(AArgumentsJson);
    if not (LArgs is TJSONObject) then
    begin
      LArgs.Free; // nil-safe
      LArgs := TJSONObject.Create;
    end;
    LParamsObj.AddPair('arguments', LArgs);
    LParamsJson := LParamsObj.ToJSON;
  finally
    LParamsObj.Free;
  end;
  FIoLock.Enter;
  try
    Result := _Request('tools/call', LParamsJson, ATimeoutMs, LResult, LErr);
  finally
    FIoLock.Leave;
  end;
  if not Result then
    Exit; // transport dead
  if LErr <> '' then
  begin
    // The child ANSWERED with a JSON-RPC error: surface it as an isError text
    // result so the agent gets feedback (mirrors TAgentMcpClient.CallTool).
    LItem := TJSONObject.Create;
    LItem.AddPair('type', 'text');
    LItem.AddPair('text', LErr);
    LContent := TJSONArray.Create;
    LContent.AddElement(LItem);
    LFallback := TJSONObject.Create;
    try
      LFallback.AddPair('content', LContent);
      LFallback.AddPair('isError', TJSONBool.Create(True));
      AResultObjJson := LFallback.ToJSON;
    finally
      LFallback.Free;
    end;
    Exit;
  end;
  AResultObjJson := LResult;
end;

procedure TMCPStdioChild.Terminate;
begin
  // Flag + kill only; NEVER free here (an in-flight CallTool may still hold a
  // ref and be inside a read -- the FAlive flag makes it bail on its next poll,
  // and the destructor closes the handles once that last ref is released).
  try
    FAlive := False;
    if (FProcess <> 0) and (FProcess <> INVALID_HANDLE_VALUE) then
      TerminateProcess(FProcess, 0);
    _GwTrace('terminate', Format('pid=%d', [FPid]));
  except
  end;
end;

{ TMCPAddonGateway }

constructor TMCPAddonGateway.Create(const AHostRenders: Boolean);
begin
  inherited Create;
  FHostRenders := AHostRenders;
  FLock := TCriticalSection.Create;
  FChildren := TList<IMCPStdioChild>.Create;
  FRoutes := TDictionary<string, TMCPAddonRoute>.Create;
  // The instance number is the question, not decoration: ONE gateway per IDE
  // session spawns its children once; one per request spawns them again every
  // time. The count answers that without anyone reading Task Manager.
  _GwTrace('gw.create', Format('n=%d hostRenders=%d',
    [InterlockedIncrement(GGwSeq), Ord(AHostRenders)]));
end;

destructor TMCPAddonGateway.Destroy;
begin
  _GwTrace('gw.destroy', Format('children=%d', [FChildren.Count]));
  Shutdown;
  FRoutes.Free;
  FChildren.Free;
  FLock.Free;
  inherited;
end;

class function TMCPAddonGateway._AggregateJson: string;
var
  LPath, LProfile: string;
  LStream: TFileStream;
  LBytes: TBytes;
  LStart: Integer;
begin
  Result := '';
  // Qualify SysUtils.GetEnvironmentVariable: `uses Windows` hijacks the bare
  // name with the 3-arg Win32 form.
  LProfile := SysUtils.GetEnvironmentVariable('USERPROFILE');
  if LProfile = '' then
    Exit;
  LPath := IncludeTrailingPathDelimiter(LProfile) + '.aefos' + PathDelim +
    'addons' + PathDelim + 'mcp-servers.json';
  if not FileExists(LPath) then
    Exit;
  try
    LStream := TFileStream.Create(LPath, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(LBytes, LStream.Size);
      if Length(LBytes) > 0 then
        LStream.ReadBuffer(LBytes[0], Length(LBytes));
    finally
      LStream.Free;
    end;
  except
    Exit; // locked/garbled -> contributes nothing
  end;
  LStart := 0;
  if (Length(LBytes) >= 3) and (LBytes[0] = $EF) and (LBytes[1] = $BB) and
    (LBytes[2] = $BF) then
    LStart := 3;
  Result := Trim(TEncoding.UTF8.GetString(LBytes, LStart, Length(LBytes) - LStart));
end;

class function TMCPAddonGateway._SanitizeKey(const AKey: string): string;
var
  LIndex: Integer;
  LCh: Char;
begin
  Result := '';
  for LIndex := 1 to Length(AKey) do
  begin
    LCh := AKey[LIndex];
    if ((LCh >= 'A') and (LCh <= 'Z')) or ((LCh >= 'a') and (LCh <= 'z')) or
      ((LCh >= '0') and (LCh <= '9')) or (LCh = '_') or (LCh = '-') then
      Result := Result + LCh
    else
      Result := Result + '_';
  end;
  if Result = '' then
    Result := 'addon';
end;

class function TMCPAddonGateway._BuildEnvBlock(const AEnvObj: TJSONObject;
  const AHostRenders: Boolean): string;
var
  LParentPtr, LScan: PWideChar;
  LEntry, LName: string;
  LEq: Integer;
  LOverrides: TDictionary<string, string>;
  LPair: TJSONPair;
  LMerged: TStringList;
  LIndex: Integer;
begin
  Result := '';
  if (AEnvObj = nil) or (AEnvObj.Count = 0) then
    Exit; // inherit the parent environment verbatim
  LOverrides := TDictionary<string, string>.Create;
  LMerged := TStringList.Create;
  try
    // This host RENDERS what the child reports: the chat panel draws a live
    // view of the window being driven, fed by the visual reporter watching these
    // very calls. The child cannot know that on its own -- the same server is
    // installed in front of agents with no UI at all -- so a tool that told
    // every caller "a human is watching" would be lying to most of them.
    // Marking it here is the only place that knows: WE spawned this child.
    if AHostRenders then
      LOverrides.AddOrSetValue('AEFOS_DESKTOP_HOST_RENDERS', '1');
    for LPair in AEnvObj do
      if LPair.JsonValue is TJSONString then
        LOverrides.AddOrSetValue(UpperCase(LPair.JsonString.Value),
          TJSONString(LPair.JsonValue).Value);
    // Copy the parent block, replacing any name the overrides also set.
    LParentPtr := GetEnvironmentStringsW;
    if LParentPtr <> nil then
    try
      LScan := LParentPtr;
      while LScan^ <> #0 do
      begin
        LEntry := LScan;
        Inc(LScan, Length(LEntry) + 1);
        // Skip the drive "=C:=..." pseudo-vars (leading '=').
        if (LEntry <> '') and (LEntry[1] <> '=') then
        begin
          LEq := Pos('=', LEntry);
          if LEq > 0 then
          begin
            LName := UpperCase(Copy(LEntry, 1, LEq - 1));
            if not LOverrides.ContainsKey(LName) then
              LMerged.Add(LEntry);
          end;
        end;
      end;
    finally
      FreeEnvironmentStringsW(LParentPtr);
    end;
    for LPair in AEnvObj do
      if LPair.JsonValue is TJSONString then
        LMerged.Add(LPair.JsonString.Value + '=' +
          TJSONString(LPair.JsonValue).Value);
    for LIndex := 0 to LMerged.Count - 1 do
      Result := Result + LMerged[LIndex] + #0;
    Result := Result + #0; // double-NUL terminates the block
  finally
    LMerged.Free;
    LOverrides.Free;
  end;
end;

procedure TMCPAddonGateway._StartServer(const AServerKey: string;
  const AServerObj: TJSONObject; const AListArray: TJSONArray);
var
  LChild: IMCPStdioChild;
  LCommand, LCwd, LEnvBlock, LToolsJson, LNs, LOrig: string;
  LArgs: TArray<string>;
  LArgsVal, LCmdVal: TJSONValue;
  LArr: TJSONArray;
  LIndex: Integer;
  LToolsRoot: TJSONValue;
  LTool: TJSONObject;
  LDesc: TJSONObject;
  LNameVal, LDescVal, LSchemaVal: TJSONValue;
  LRoute: TMCPAddonRoute;
begin
  LCmdVal := AServerObj.GetValue('command');
  if not (LCmdVal is TJSONString) then
    Exit;
  LCommand := TJSONString(LCmdVal).Value;
  // A command still carrying an unresolved token cannot be spawned raw.
  if (LCommand = '') or (Pos('${', LCommand) > 0) then
    Exit;

  SetLength(LArgs, 0);
  LArgsVal := AServerObj.GetValue('args');
  if LArgsVal is TJSONArray then
  begin
    LArr := TJSONArray(LArgsVal);
    for LIndex := 0 to LArr.Count - 1 do
      if LArr.Items[LIndex] is TJSONString then
      begin
        SetLength(LArgs, Length(LArgs) + 1);
        LArgs[High(LArgs)] := TJSONString(LArr.Items[LIndex]).Value;
      end;
  end;

  LCwd := '';
  if AServerObj.GetValue('cwd') is TJSONString then
    LCwd := TJSONString(AServerObj.GetValue('cwd')).Value;
  if AServerObj.GetValue('env') is TJSONObject then
    LEnvBlock := _BuildEnvBlock(TJSONObject(AServerObj.GetValue('env')),
      FHostRenders)
  else
    LEnvBlock := '';

  _GwTrace('server.start', Format('key=%s cmd=%s', [AServerKey, LCommand]));
  LChild := TMCPStdioChild.Create;
  if not LChild.Spawn(LCommand, LArgs, LCwd, LEnvBlock) then
  begin
    _GwTrace('server.fail', Format('key=%s step=spawn', [AServerKey]));
    Exit;
  end;
  if not LChild.Handshake(CHandshakeTimeoutMs) then
  begin
    _GwTrace('server.fail', Format('key=%s step=handshake', [AServerKey]));
    LChild.Terminate;
    Exit;
  end;
  if not LChild.ListTools(LToolsJson, CListTimeoutMs) then
  begin
    LChild.Terminate;
    Exit;
  end;

  LToolsRoot := TJSONObject.ParseJSONValue(LToolsJson);
  try
    if not (LToolsRoot is TJSONArray) then
    begin
      LChild.Terminate;
      Exit;
    end;
    FChildren.Add(LChild);
    LArr := TJSONArray(LToolsRoot);
    for LIndex := 0 to LArr.Count - 1 do
    begin
      if not (LArr.Items[LIndex] is TJSONObject) then
        Continue;
      LTool := TJSONObject(LArr.Items[LIndex]);
      LNameVal := LTool.GetValue('name');
      if not (LNameVal is TJSONString) then
        Continue;
      LOrig := TJSONString(LNameVal).Value;
      LNs := _SanitizeKey(AServerKey) + CNamespaceSep + LOrig;
      if FRoutes.ContainsKey(LNs) then
        Continue; // first server to claim the name wins
      LRoute.Child := LChild;
      LRoute.ToolName := LOrig;
      FRoutes.AddOrSetValue(LNs, LRoute);
      // Build the namespaced descriptor for tools/list.
      LDesc := TJSONObject.Create;
      LDesc.AddPair('name', LNs);
      LDescVal := LTool.GetValue('description');
      if LDescVal is TJSONString then
        LDesc.AddPair('description', TJSONString(LDescVal).Value);
      LSchemaVal := LTool.GetValue('inputSchema');
      if LSchemaVal is TJSONValue then
        LDesc.AddPair('inputSchema',
          TJSONObject.ParseJSONValue(LSchemaVal.ToJSON));
      AListArray.AddElement(LDesc);
    end;
  finally
    LToolsRoot.Free;
  end;
end;

procedure TMCPAddonGateway._Discover;
var
  LJson: string;
  LRoot, LServersVal: TJSONValue;
  LServers: TJSONObject;
  LPair: TJSONPair;
  LListArray: TJSONArray;
begin
  LJson := _AggregateJson;
  if LJson = '' then
    Exit;
  LRoot := TJSONObject.ParseJSONValue(LJson);
  try
    if not (LRoot is TJSONObject) then
      Exit;
    LServersVal := TJSONObject(LRoot).GetValue('mcpServers');
    if not (LServersVal is TJSONObject) then
      Exit;
    LServers := TJSONObject(LServersVal);
    LListArray := TJSONArray.Create;
    try
      for LPair in LServers do
        if LPair.JsonValue is TJSONObject then
          try
            _StartServer(LPair.JsonString.Value,
              TJSONObject(LPair.JsonValue), LListArray);
          except
            // One bad server never breaks discovery of the rest.
          end;
      FListJson := LListArray.ToJSON;
    finally
      LListArray.Free;
    end;
  finally
    LRoot.Free;
  end;
end;

procedure TMCPAddonGateway._EnsureStarted;
begin
  if FStarted or FShutDown then
    Exit;
  FStarted := True; // set first: a discovery failure must not retry-spam spawns
  try
    _Discover;
  except
    // Never let discovery raise into a tools/list.
  end;
end;

function TMCPAddonGateway.ListToolsJson: string;
begin
  Result := '';
  FLock.Enter;
  try
    _EnsureStarted;
    Result := FListJson;
  finally
    FLock.Leave;
  end;
end;

function TMCPAddonGateway.OwnsTool(const AToolName: string): Boolean;
begin
  FLock.Enter;
  try
    _EnsureStarted;
    Result := FRoutes.ContainsKey(AToolName);
  finally
    FLock.Leave;
  end;
end;

function TMCPAddonGateway.CallTool(const AToolName,
  AArgumentsJson: string): string;
var
  LRoute: TMCPAddonRoute;
  LChild: IMCPStdioChild;
  LToolName, LResult: string;
begin
  Result := '';
  // Resolve the route under the lock, then RELEASE it before the (possibly long)
  // child IO: the local interface ref keeps the child object alive even if
  // Shutdown clears the gateway's own refs meanwhile.
  FLock.Enter;
  try
    _EnsureStarted;
    if FShutDown then
      Exit;
    if not FRoutes.TryGetValue(AToolName, LRoute) then
      Exit;
    LChild := LRoute.Child;
    LToolName := LRoute.ToolName;
  finally
    FLock.Leave;
  end;
  if LChild = nil then
    Exit;
  try
    if not LChild.CallTool(LToolName, AArgumentsJson, CCallTimeoutMs, LResult) then
      Result := ''
    else
      Result := LResult;
  except
    Result := '';
  end;
end;

procedure TMCPAddonGateway.Shutdown;
var
  LIndex: Integer;
begin
  FLock.Enter;
  try
    if FShutDown then
      Exit;
    FShutDown := True;
    // Flag + kill every child (quick, non-blocking). An in-flight CallTool holds
    // its own ref, so Clear here does not free a child out from under it.
    for LIndex := 0 to FChildren.Count - 1 do
      try
        FChildren[LIndex].Terminate;
      except
      end;
    FRoutes.Clear;
    FChildren.Clear; // releases the gateway's refs
    FListJson := '';
    FStarted := False;
  finally
    FLock.Leave;
  end;
end;

initialization
  GJobLock := TCriticalSection.Create;
  { The trace's lock. INTENTIONALLY NEVER DELETED, for the same reason GJobLock
    below is intentionally leaked: teardown still writes trace lines (Shutdown,
    gw.destroy), and a critical section deleted while another thread is about to
    enter it corrupts memory to save one OS handle the process reclaims anyway. }
  InitializeCriticalSection(GGwTraceLock);
  GGwTraceState := -1;

finalization
  { Closing the last handle to a KILL_ON_JOB_CLOSE job kills everything still in
    it. On Delphi this runs at BPL unload -- which is exactly the moment a
    surviving child becomes the crash class the IDE-UNLOAD rules exist to
    prevent -- and on Lazarus at IDE shutdown. Shutdown has normally already
    terminated the children by now; this is the floor for when it did not run. }
  { Under GJobLock, like every other reader of GChildJob. _AefosChildJob hands
    the handle back and RELEASES the lock, and Spawn then calls
    _AssignProcessToJobObject with that bare value; closing the handle in that
    window lets the kernel recycle the number for an unrelated object, so the
    child would be assigned to the WRONG job and silently outlive us -- or be
    closed twice. Taking the lock keeps finalization ordered against that read. }
  if GJobLock <> nil then
  begin
    GJobLock.Enter;
    try
      if GChildJob <> 0 then
      begin
        CloseHandle(GChildJob);
        GChildJob := 0;
      end;
    finally
      GJobLock.Leave;
    end;
  end;
  { GJobLock is INTENTIONALLY LEAKED -- do NOT "fix" this into a FreeAndNil.
    Freeing it reintroduces a use-after-free: a thread can pass the `if GJobLock
    = nil` guard in _AefosChildJob, get preempted, and come back to call .Enter
    on a destroyed critical section. A TCriticalSection is one OS critical
    section, which the process reclaims on exit anyway, so the cost is nil next
    to corrupting memory during teardown -- the same "leak > corrupt" stance the
    transport layer already takes (see the KNOWN LIMITATION note in
    Aefos.Lazarus.McpHost._TeardownServer). }

end.
