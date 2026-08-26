unit Aefos.OTA.Chat.Core.CLIDispatcher;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Subprocess transport orchestration for external AI CLIs (ESP-002 demand 2/5;
  refactored under ESP-004 Epic 3/3 Demand 2/3).

  The single subsystem in Aefos that drives a child process for chat
  (RN-001). Every other unit must route through ICLIDispatcher.

  Architecture (post ESP-004 seam split — ADR-260/261/262):
    - Dispatch resolves the executor, builds the command line + env block via
      the pure decode seam (Dispatcher.Decode), and constructs a
      TCLIDispatcherRun bound to an injected IProcessRunner.
    - The OS spawn (CreateProcess, pipes, STARTUPINFO, the two ReadFile read
      threads, handle hygiene, wait/exit/terminate) lives behind the injectable
      IProcessRunner seam — by default the real Win32 runner
      (Dispatcher.ProcessRunner), or a fake in tests. The seam emits RAW bytes
      (ADR-261); this unit owns the decode.
    - Raw stdout/stderr byte chunks arrive via the session callbacks; this unit
      runs them through the per-stream UTF-8 carry decoder (Dispatcher.Decode),
      applies the defensive ANSI strip to stdout (ADR-005), and forwards chunks
      via TThread.Queue. Queued chunk callbacks check FCancelledFlag before
      invoking the user callback.
    - Cancel = IProcessSession.Terminate (TerminateProcess, ADR-005), idempotent.
    - Logs go to %APPDATA%\Aefos\logs\YYYY-MM-DD[-<executor>].log as JSON
      Lines. Local only (RN-002, RN-003); no outbound HTTP.

  Portability (Aefos -> Lazarus, external-CLI slice): this unit is now the SHARED
  external-CLI transport for BOTH IDEs -- the Lazarus chat dispatches through the
  very same ICLIDispatcher the RAD Studio plugin uses. FPC 3.2.2 has no anonymous
  methods, so the five closures this unit used are recast as CARRIER OBJECTS with
  bound `of object` methods, exactly the shape Aefos.Provider.Ollama was
  de-closured into. The recast is UNCONDITIONAL (not IFDEF'd): one code path, one
  behaviour, nothing to drift. What each closure captured now lives on a carrier
  field, and what each closure's `LKeepAlive` capture guaranteed -- that the run
  outlives the child's read threads -- is now an EXPLICIT interface reference held
  by the carrier and released as its last instruction (see TCLIDispatcherSink).
  Delphi runtime behaviour is unchanged: same threads, same TThread.Queue
  marshalling, same idempotent completion, same cancel semantics.

  Constraints:
    - Windows only.
}

interface

uses
  Aefos.OTA.Chat.Core.Dispatcher.Types;

type
  ICLIDispatcher = interface
    ['{D8B72A4F-9156-4B0D-B14F-7E3C8A2D1F62}']
    function Dispatch(const ARequest: TDispatchRequest;
      const AOnOutput: TDispatcherChunkCallback;
      const AOnComplete: TDispatcherCompleteCallback;
      const AOnError: TDispatcherErrorCallback): IDispatcherRunHandle;
  end;

  TCLIDispatcher = class(TInterfacedObject, ICLIDispatcher)
  private
    FRunner: IProcessRunner;
  public
    // Default ctor: composes with the real Win32 process runner so the
    // production composition site (Register.pas) is unchanged (ADR-260).
    constructor Create; overload;
    // Seam ctor: inject any IProcessRunner (e.g. a fake in headless tests).
    constructor Create(const ARunner: IProcessRunner); overload;
    function Dispatch(const ARequest: TDispatchRequest;
      const AOnOutput: TDispatcherChunkCallback;
      const AOnComplete: TDispatcherCompleteCallback;
      const AOnError: TDispatcherErrorCallback): IDispatcherRunHandle; reintroduce;
  end;

implementation

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
  Aefos.Compat.IO,
  Aefos.OTA.Chat.Core.Dispatcher.Decode,
  Aefos.OTA.Chat.Core.Dispatcher.ProcessRunner;

type
  // FPC 3.2.2's TStringBuilder is ALWAYS the Ansi one regardless of the string
  // mode; TUnicodeStringBuilder is the UTF-16 twin this unit needs (the stderr
  // buffer holds decoded text). On Delphi TStringBuilder already is that.
{$IFDEF FPC}
  TTextBuilder = TUnicodeStringBuilder;
{$ELSE}
  TTextBuilder = TStringBuilder;
{$ENDIF}

const
  COMPLETE_WAIT_MS = 500;
  // Synthetic exit code reported when the watchdog terminates a timed-out run
  // (ADR-288). Distinct from 0 (success) and from $FFFFFFFF (still-running grace
  // sentinel returned by GetCompletionExitCode), so the surface can tell a
  // timeout apart from a natural non-zero exit.
  EXIT_CODE_TIMEOUT: Cardinal = $FFFFFFFE;

type
  // Snapshot of a run's terminal state, collected once under the idempotent
  // completion gate and threaded through logging + callback queuing (keeps the
  // helper signatures to a single parameter — convention: a record over a long
  // positional list).
  TRunCompletion = record
    ExitCode: DWORD;
    Duration: Cardinal;
    StderrText: string;
    Cancelled: Boolean;
    TimedOut: Boolean;
  end;

  TCLIDispatcherRun = class(TInterfacedObject, IDispatcherRunHandle)
  private
    FRunner: IProcessRunner;
    FSession: IProcessSession;
    FOnOutput: TDispatcherChunkCallback;
    FOnComplete: TDispatcherCompleteCallback;
    FOnError: TDispatcherErrorCallback;
    FStderrBuffer: TTextBuilder;
    FStderrLock: TCriticalSection;
    FCancelledFlag: Integer;
    FCompletedFlag: Integer;
    FTimedOutFlag: Integer;
    FTerminatedCount: Integer;
    FStartTick: Cardinal;
    FRunId: TGUID;
    FCompleteEvent: TEvent;
    FExecutorPath: string;
    FExecutor: string;
    FPromptSummary: string;
    FTimeoutMs: Cardinal;
    { Kept whatever the exit code, so the session-id scrape can read it on a
      SUCCESSFUL run -- the error callback deliberately stays silent there. }
    FStderrText: string;
    FOutputFilter: TOutputFilterPolicy;
    FWatchdog: TThread;
    FStdoutDecoder: TStreamDecoder;
    FStderrDecoder: TStreamDecoder;
{$IFNDEF FPC}
    // Delphi-only: the regex-based defensive CSI strip (Dispatcher.Decode's
    // TAnsiStripper is IFDEF'd out of the FPC build). See _DispatchStdoutChunk.
    FAnsiStripper: TAnsiStripper;
{$ENDIF}
    procedure _AppendLogLine(const AEvent: string; const AData: string);
    procedure _OnChunk(const AKind: TProcessStreamKind; const ABytes: TBytes;
      const ACount: Integer);
    procedure _OnStreamEnd(const AKind: TProcessStreamKind);
    procedure _DispatchStdoutChunk(const AChunk: string);
    procedure _AppendStderr(const AChunk: string);
    procedure _OnReadThreadTerminate;
    procedure _MaybeFireComplete;
    procedure _HandleTimeout;
    function _CollectCompletionState: TRunCompletion;
    function _BuildErrorText(const AState: TRunCompletion): string;
    procedure _LogCompletionEvent(const AState: TRunCompletion);
    procedure _QueueCompletionCallbacks(const AState: TRunCompletion);
    procedure _WriteLogBytes(const APath: string; const ABytes: TBytes);
  public
    constructor Create(const ARunner: IProcessRunner;
      const ARequest: TDispatchRequest;
      const AOnOutput: TDispatcherChunkCallback;
      const AOnComplete: TDispatcherCompleteCallback;
      const AOnError: TDispatcherErrorCallback);
    destructor Destroy; override;
    procedure Spawn(const ARequest: TDispatchRequest);
    function IsRunning: Boolean;
    procedure Cancel;
    function WaitFor(const ATimeoutMs: Cardinal): Boolean;
    function RunId: TGUID;
    function StderrText: string;
  end;

  // Event-waiting watchdog (ADR-288). Waits on the run's manual-reset
  // FCompleteEvent for FTimeoutMs: a natural/cancel completion signals the event
  // (wrSignaled -> clean exit); a timeout (wrTimeout) drives _HandleTimeout.
  // No process coupling — a plain Delphi thread, so it stays coverage-gated
  // (R-2). Same-unit visibility lets it read TCLIDispatcherRun's privates.
  TWatchdogThread = class(TThread)
  private
    FRun: TCLIDispatcherRun;
  protected
    procedure Execute; override;
  public
    constructor Create(const ARun: TCLIDispatcherRun);
  end;

  // --- Carriers (the de-closured captures) ---------------------------------
  //
  // Each of these replaces one anonymous method. The rule they all share: a
  // carrier NEVER touches the run through a bare pointer alone -- it holds an
  // IDispatcherRunHandle (FKeepAlive) that keeps the run alive for exactly as
  // long as the carrier can still fire, and releases it as its LAST instruction.
  // That is what the closures' `LKeepAlive` capture did implicitly; making it
  // explicit is what keeps a mid-run teardown from becoming a use-after-free.

  // The IProcessSession read-callback sink (was the two BeginRead closures).
  // Handed to the session as two bound method pointers, it outlives the caller's
  // stack and holds the run alive until BOTH child streams have ended -- after
  // which no further chunk can arrive, so it releases the run and frees itself.
  TCLIDispatcherSink = class(TInterfacedObject)
  private
    FRun: TCLIDispatcherRun;
    FKeepAlive: IDispatcherRunHandle;
    FSelf: IInterface;
    FStreamEnds: Integer;
  public
    constructor Create(const ARun: TCLIDispatcherRun;
      const AKeepAlive: IDispatcherRunHandle);
    procedure OnChunk(const AKind: TProcessStreamKind; const ABytes: TBytes;
      const ACount: Integer);
    procedure OnStreamEnd(const AKind: TProcessStreamKind);
  end;

  // One main-thread stdout delivery (was the TThread.Queue closure in
  // _DispatchStdoutChunk). Carries a COPY of the decoded text so the delivery is
  // independent of the read thread that produced it.
  TCLIDispatcherChunkDispatch = class
  private
    FRun: TCLIDispatcherRun;
    FKeepAlive: IDispatcherRunHandle;
    FCallback: TDispatcherChunkCallback;
    FText: string;
  public
    constructor Create(const ARun: TCLIDispatcherRun;
      const AKeepAlive: IDispatcherRunHandle;
      const ACallback: TDispatcherChunkCallback; const AText: string);
    procedure Fire;
  end;

  // One main-thread completion delivery (was the TThread.Queue closure in
  // _QueueCompletionCallbacks): error-then-complete, then signal the run's
  // completion event -- the exact order the closure had.
  TCLIDispatcherCompletionDispatch = class
  private
    FRun: TCLIDispatcherRun;
    FKeepAlive: IDispatcherRunHandle;
    FOnComplete: TDispatcherCompleteCallback;
    FOnError: TDispatcherErrorCallback;
    FErrorText: string;
    FExitCode: Cardinal;
    FDuration: Cardinal;
  public
    constructor Create(const ARun: TCLIDispatcherRun;
      const AKeepAlive: IDispatcherRunHandle;
      const AOnComplete: TDispatcherCompleteCallback;
      const AOnError: TDispatcherErrorCallback;
      const AErrorText: string; const AState: TRunCompletion);
    procedure Fire;
  end;

{ Helper functions }

// Atomic counter ops, spelled per compiler: Delphi has the TInterlocked class
// (System.SyncObjs), FPC 3.2.2 does NOT -- its RTL exposes the same atomics as
// plain global functions with identical semantics (_Inc returns the NEW value,
// _Exchange returns the OLD one). A thin wrapper keeps the call sites
// single-source.
function _AtomicInc(var ATarget: Integer): Integer;
begin
{$IFDEF FPC}
  Result := InterlockedIncrement(ATarget);
{$ELSE}
  Result := TInterlocked.Increment(ATarget);
{$ENDIF}
end;

function _AtomicExchange(var ATarget: Integer; const AValue: Integer): Integer;
begin
{$IFDEF FPC}
  Result := InterlockedExchange(ATarget, AValue);
{$ELSE}
  Result := TInterlocked.Exchange(ATarget, AValue);
{$ENDIF}
end;

// OutputDebugString wrapper: FPC's unqualified OutputDebugString is the ANSI
// overload (PAnsiChar), while this unit is delphiunicode, so FPC calls
// OutputDebugStringW. One helper keeps every diagnostic site portable.
procedure _DebugLog(const AMessage: string);
begin
{$IFDEF FPC}
  OutputDebugStringW(PWideChar(AMessage));
{$ELSE}
  OutputDebugString(PChar(AMessage));
{$ENDIF}
end;

function _ResolveExecutor(const ACandidate: string): string;
var
  LBuffer: array[0..MAX_PATH] of Char;
  LFilePart: PChar;
  LLen: DWORD;
begin
  if ACandidate = '' then
    Exit('');

  if TPath.IsPathRooted(ACandidate) then
  begin
    if TFile.Exists(ACandidate) then
      Exit(ACandidate);
    Exit('');
  end;

  // SearchPathW, not the unqualified SearchPath: FPC's Windows unit maps the
  // unqualified name to the ANSI entry point (LPSTR), which does not take this
  // unit's PChar (= PWideChar under delphiunicode). On Delphi the unqualified
  // name already IS the W one, so both builds call the identical API.
  LLen := SearchPathW(nil, PChar(ACandidate), '.exe',
    Length(LBuffer), LBuffer, LFilePart);
  if LLen > 0 then
    Exit(LBuffer);
  LLen := SearchPathW(nil, PChar(ACandidate), nil,
    Length(LBuffer), LBuffer, LFilePart);
  if LLen > 0 then
    Exit(LBuffer);
  Result := '';
end;

function _LogDirectory: string;
var
  LAppData: string;
begin
  // Qualified: `uses Windows` exports a 3-arg GetEnvironmentVariable that
  // SHADOWS the 1-arg SysUtils one.
  LAppData := SysUtils.GetEnvironmentVariable('APPDATA');
  if LAppData = '' then
  begin
    _DebugLog('Aefos: APPDATA unset; falling back to TEMP for logs');
    LAppData := TPath.GetTempPath;
  end;
  Result := TPath.Combine(LAppData, 'Aefos\logs');
end;

function _LogFilePath(const AExecutor: string): string;
begin
  Result := TPath.Combine(_LogDirectory,
    TCliLogNaming.Compose(FormatDateTime('yyyy-mm-dd', Now), AExecutor));
end;

{ TCLIDispatcher }

constructor TCLIDispatcher.Create;
begin
  Create(TWin32ProcessRunner.Create);
end;

constructor TCLIDispatcher.Create(const ARunner: IProcessRunner);
begin
  inherited Create;
  FRunner := ARunner;
end;

function TCLIDispatcher.Dispatch(const ARequest: TDispatchRequest;
  const AOnOutput: TDispatcherChunkCallback;
  const AOnComplete: TDispatcherCompleteCallback;
  const AOnError: TDispatcherErrorCallback): IDispatcherRunHandle;
var
  LRun: TCLIDispatcherRun;
  LResolved: string;
  LRequest: TDispatchRequest;
  LHandle: IDispatcherRunHandle;
begin
  LResolved := _ResolveExecutor(ARequest.ExecutorPath);
  if LResolved = '' then
    raise EDispatcherExecutorNotFound.CreateFmt(
      'Executor not found: "%s"', [ARequest.ExecutorPath]);

  LRequest := ARequest;
  LRequest.ExecutorPath := LResolved;

  LRun := TCLIDispatcherRun.Create(FRunner, LRequest,
    AOnOutput, AOnComplete, AOnError);
  LHandle := LRun;
  LRun.Spawn(LRequest);
  Result := LHandle;
end;

{ TCLIDispatcherRun }

constructor TCLIDispatcherRun.Create(const ARunner: IProcessRunner;
  const ARequest: TDispatchRequest;
  const AOnOutput: TDispatcherChunkCallback;
  const AOnComplete: TDispatcherCompleteCallback;
  const AOnError: TDispatcherErrorCallback);
begin
  inherited Create;
  FRunner := ARunner;
  FOnOutput := AOnOutput;
  FOnComplete := AOnComplete;
  FOnError := AOnError;
  FStderrBuffer := TTextBuilder.Create;
  FStderrLock := TCriticalSection.Create;
  FCompleteEvent := TEvent.Create(nil, True, False, '');
  CreateGUID(FRunId);
  FExecutorPath := ARequest.ExecutorPath;
  FExecutor := ARequest.Executor;
  FPromptSummary := TCliText.BuildPromptSummary(ARequest.Prompt);
  FTimeoutMs := ARequest.TimeoutMs;
  FOutputFilter := ARequest.OutputFilter;
  FStdoutDecoder := TStreamDecoder.Create;
  FStderrDecoder := TStreamDecoder.Create;
{$IFNDEF FPC}
  FAnsiStripper := TAnsiStripper.Create;
{$ENDIF}
end;

destructor TCLIDispatcherRun.Destroy;
begin
  // R-1: join the watchdog before freeing any field it touches. Signal the
  // event first so a still-waiting watchdog wakes wrSignaled and exits without
  // acting; Free then does Terminate + WaitFor + destroy. No lock is held here,
  // so the WaitFor inside Free cannot deadlock.
  if Assigned(FWatchdog) then
  begin
    FCompleteEvent.SetEvent;
    FWatchdog.Free;
    FWatchdog := nil;
  end;
{$IFNDEF FPC}
  FAnsiStripper.Free;
{$ENDIF}
  FStderrDecoder.Free;
  FStdoutDecoder.Free;
  FCompleteEvent.Free;
  FStderrLock.Free;
  FStderrBuffer.Free;
  inherited;
end;

procedure TCLIDispatcherRun.Spawn(const ARequest: TDispatchRequest);
var
  LOverrides: TArray<TPair<string, string>>;
  LSpec: TProcessStartSpec;
  LSink: TCLIDispatcherSink;
  LOnChunk: TProcessChunkProc;
  LOnStreamEnd: TProcessStreamEndProc;
begin
  LOverrides := ARequest.EnvOverrides;
  // ADR-289: NO_COLOR=1 is injected only under the strip policy; ofpRaw lets the
  // child emit escapes so the raw stream is preserved verbatim.
  if FOutputFilter = ofpStrip then
    TCliCommandLine.EnsureNoColorOverride(LOverrides);

  LSpec.ExecutorPath := ARequest.ExecutorPath;
  LSpec.CommandLine := TCliCommandLine.Build(ARequest);
  LSpec.EnvBlock := TCliCommandLine.BuildEnvBlock(LOverrides);
  LSpec.WorkingDirectory := ARequest.WorkingDirectory;
  // The prompt goes on exactly ONE of the two channels, never both: Build above
  // already left it off the command line for a PromptViaStdin driver, and this is
  // where it picks the other one up. A command-line driver gets '' here, which is
  // the same closed-stdin child the runner has always spawned.
  if ARequest.PromptViaStdin then
    LSpec.StdinText := ARequest.Prompt
  else
    LSpec.StdinText := '';

  FStartTick := GetTickCount;

  // Spawn (raises EDispatcherSpawnFailed on failure, before any reading).
  FSession := FRunner.Start(LSpec);

  // The head of the command line goes in the log, and it earns its place: it is
  // the only record of whether a turn resumed a conversation or started a new
  // one. A user reported the agent forgetting his first message, and answering
  // that meant knowing per turn whether the CLI was invoked as `exec` or
  // `exec resume <id>` -- which nothing recorded, so the question could only be
  // guessed at from behaviour.
  //   HEAD only (first 120 chars): the prompt is on this line too, and a session
  // log is not the place to copy the user's text. The flags and the session id
  // live at the front, which is exactly the part that answers the question.
  _AppendLogLine('spawn',
    Format('{"executor":"%s","cmd_head":"%s","prompt_summary":"%s"}',
    [TCliText.EscapeJsonString(FExecutorPath),
     TCliText.EscapeJsonString(Copy(LSpec.CommandLine, 1, 120)),
     TCliText.EscapeJsonString(FPromptSummary)]));

  // Keep the run alive while the session's read threads call back, exactly as
  // the pre-refactor read threads held an IDispatcherRunHandle reference -- the
  // sink now holds that reference EXPLICITLY (it was the closures' capture) and
  // drops it once both streams have ended, at which point no chunk can arrive.
  LSink := TCLIDispatcherSink.Create(Self, Self);
  LOnChunk := LSink.OnChunk;
  LOnStreamEnd := LSink.OnStreamEnd;
  FSession.BeginRead(LOnChunk, LOnStreamEnd);

  // ADR-288: arm the timeout watchdog only when a bound is requested. With
  // FTimeoutMs = 0 (default) no thread is created and the path is byte-identical
  // to the pre-change behaviour (BR-1).
  if FTimeoutMs > 0 then
    FWatchdog := TWatchdogThread.Create(Self);
end;

procedure TCLIDispatcherRun._OnChunk(const AKind: TProcessStreamKind;
  const ABytes: TBytes; const ACount: Integer);
var
  LDecoded: string;
begin
  if AKind = pskStdout then
  begin
    LDecoded := FStdoutDecoder.Decode(ABytes, ACount);
    if LDecoded <> '' then
      _DispatchStdoutChunk(LDecoded);
  end
  else
  begin
    LDecoded := FStderrDecoder.Decode(ABytes, ACount);
    if LDecoded <> '' then
      _AppendStderr(LDecoded);
  end;
end;

procedure TCLIDispatcherRun._OnStreamEnd(const AKind: TProcessStreamKind);
var
  LDecoded: string;
begin
  // Flush any incomplete trailing carry at end-of-stream (best effort), then
  // count the stream towards completion.
  if AKind = pskStdout then
  begin
    LDecoded := FStdoutDecoder.Flush;
    if LDecoded <> '' then
      _DispatchStdoutChunk(LDecoded);
  end
  else
  begin
    LDecoded := FStderrDecoder.Flush;
    if LDecoded <> '' then
      _AppendStderr(LDecoded);
  end;
  _OnReadThreadTerminate;
end;

procedure TCLIDispatcherRun._DispatchStdoutChunk(const AChunk: string);
var
  LStripped: string;
  LDispatch: TCLIDispatcherChunkDispatch;
  LMethod: TThreadMethod;
begin
  // ADR-289: strip CSI escapes only under ofpStrip; ofpRaw forwards the decoded
  // chunk verbatim. UTF-8 carry decode already ran upstream for both policies.
{$IFDEF FPC}
  // The ANSI CSI strip is regex-based (System.RegularExpressions) and is IFDEF'd
  // out of the FPC build of Dispatcher.Decode, so FPC forwards the decoded chunk
  // verbatim regardless of the policy. Harmless for the shipped Lazarus path:
  // NO_COLOR=1 is still injected into the child env under ofpStrip (Spawn), which
  // is what actually stops a well-behaved CLI emitting escapes -- the strip is
  // only the DEFENSIVE second line. Re-based on RegExpr when a CLI is found that
  // colours through NO_COLOR.
  LStripped := AChunk;
{$ELSE}
  if FOutputFilter = ofpStrip then
    LStripped := FAnsiStripper.Strip(AChunk)
  else
    LStripped := AChunk;
{$ENDIF}
  // Was a queued closure capturing (callback, text, self, keep-alive); every
  // capture is now a carrier field. TThread.Queue (not Synchronize) on BOTH
  // compilers: the read thread must never block on the main thread or it stops
  // pumping the child's pipe. The FPC "Queue dies unfired" trap does not apply --
  // it reaps a FreeOnTerminate thread's pending entries, and the read threads
  // (Dispatcher.ProcessRunner) are FreeOnTerminate=False.
  LDispatch := TCLIDispatcherChunkDispatch.Create(Self, Self, FOnOutput,
    LStripped);
  LMethod := LDispatch.Fire;
  TThread.Queue(nil, LMethod);
  _AppendLogLine('output', Format('{"len":%d}', [Length(LStripped)]));
end;

procedure TCLIDispatcherRun._AppendStderr(const AChunk: string);
begin
  FStderrLock.Enter;
  try
    FStderrBuffer.Append(AChunk);
  finally
    FStderrLock.Leave;
  end;
  _AppendLogLine('stderr', Format('{"len":%d}', [Length(AChunk)]));
end;

procedure TCLIDispatcherRun._WriteLogBytes(const APath: string;
  const ABytes: TBytes);
var
  LStream: TFileStream;
  LMode: Word;
begin
  if TFile.Exists(APath) then
    LMode := fmOpenWrite or fmShareDenyWrite
  else
    LMode := fmCreate or fmShareDenyWrite;
  LStream := TFileStream.Create(APath, LMode);
  try
    LStream.Seek(0, soEnd);
    LStream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    LStream.Free;
  end;
end;

procedure TCLIDispatcherRun._AppendLogLine(const AEvent: string;
  const AData: string);
var
  LDir: string;
  LPath: string;
  LLine: string;
  LBytes: TBytes;
begin
  try
    LDir := _LogDirectory;
    if not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
    LPath := _LogFilePath(FExecutor);
    LLine := Format(
      '{"ts":"%s","run_id":"%s","executor":"%s","event":"%s","data":%s}'#13#10,
      [FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now),
       GUIDToString(FRunId),
       TCliText.EscapeJsonString(FExecutorPath),
       AEvent,
       AData]);
    LBytes := TEncoding.UTF8.GetBytes(LLine);
    _WriteLogBytes(LPath, LBytes);
  except
    on E: Exception do
      _DebugLog('[Aefos] _AppendLogLine failed: ' + E.Message);
  end;
end;

procedure TCLIDispatcherRun._OnReadThreadTerminate;
begin
  // Each stream-end increments the counter exactly once; the second to fire
  // triggers completion. A counter avoids the OnTerminate/Finished race the
  // pre-refactor unit documented.
  if _AtomicInc(FTerminatedCount) < 2 then
    Exit;
  _MaybeFireComplete;
end;

function TCLIDispatcherRun._CollectCompletionState: TRunCompletion;
begin
  Result.TimedOut := FTimedOutFlag <> 0;
  // ADR-288: a timed-out run reports the synthetic timeout exit code rather than
  // the (terminated) child's code, so the surface can tell a timeout apart.
  if Result.TimedOut then
    Result.ExitCode := EXIT_CODE_TIMEOUT
  else
    Result.ExitCode := FSession.GetCompletionExitCode(COMPLETE_WAIT_MS);
  Result.Duration := GetTickCount - FStartTick;
  Result.Cancelled := FCancelledFlag <> 0;
  FStderrLock.Enter;
  try
    Result.StderrText := FStderrBuffer.ToString;
  finally
    FStderrLock.Leave;
  end;
end;

function TCLIDispatcherRun._BuildErrorText(
  const AState: TRunCompletion): string;
begin
  // A timeout surfaces an objective cause; a plain user cancel is intentional
  // and is never surfaced as an error (ADR-288). Otherwise a non-zero exit with
  // captured stderr is forwarded as before. The engine works in ms (A-3).
  if AState.TimedOut then
    Result := Format('Process timed out after %d ms and was terminated.',
      [FTimeoutMs])
  else if (not AState.Cancelled) and (AState.ExitCode <> 0) and
          (AState.StderrText <> '') then
    Result := AState.StderrText
  else
    Result := '';
end;

procedure TCLIDispatcherRun._LogCompletionEvent(const AState: TRunCompletion);
begin
  if AState.TimedOut then
    _AppendLogLine('complete',
      Format('{"exit_code":%d,"duration_ms":%d,"timed_out":true}',
        [AState.ExitCode, AState.Duration]))
  else if AState.Cancelled then
    _AppendLogLine('complete',
      Format('{"exit_code":%d,"duration_ms":%d,"cancelled":true}',
        [AState.ExitCode, AState.Duration]))
  else
    _AppendLogLine('complete',
      Format('{"exit_code":%d,"duration_ms":%d}',
        [AState.ExitCode, AState.Duration]));
end;

procedure TCLIDispatcherRun._QueueCompletionCallbacks(
  const AState: TRunCompletion);
var
  LDispatch: TCLIDispatcherCompletionDispatch;
  LMethod: TThreadMethod;
begin
  // Was a queued closure capturing (both callbacks, the error text, the state,
  // self, keep-alive); every capture is now a carrier field. The carrier holds
  // the run alive on its own, so the completion still fires (and still signals
  // FCompleteEvent) even if every other reference is dropped between here and
  // the main thread servicing the queue.
  FStderrText := AState.StderrText;
  LDispatch := TCLIDispatcherCompletionDispatch.Create(Self, Self, FOnComplete,
    FOnError, _BuildErrorText(AState), AState);
  LMethod := LDispatch.Fire;
  TThread.Queue(nil, LMethod);
end;

procedure TCLIDispatcherRun._MaybeFireComplete;
var
  LState: TRunCompletion;
begin
  if _AtomicExchange(FCompletedFlag, 1) <> 0 then
    Exit;
  LState := _CollectCompletionState;
  _LogCompletionEvent(LState);
  _QueueCompletionCallbacks(LState);
end;

procedure TCLIDispatcherRun._HandleTimeout;
begin
  // Already completed in the tiny window between WaitFor returning wrTimeout and
  // here -> nothing to do (the idempotent _MaybeFireComplete would no-op anyway).
  if FCompletedFlag <> 0 then
    Exit;
  // Mark before Terminate so whichever path wins _MaybeFireComplete (the forced
  // call below, or the post-terminate stream-end) reports the timeout state.
  _AtomicExchange(FTimedOutFlag, 1);
  if Assigned(FSession) then
    FSession.Terminate;
  _AppendLogLine('timeout', Format('{"timeout_ms":%d}', [FTimeoutMs]));
  _MaybeFireComplete;
end;

procedure TCLIDispatcherRun.Cancel;
begin
  if _AtomicExchange(FCancelledFlag, 1) <> 0 then
    Exit;
  if Assigned(FSession) then
    FSession.Terminate;
  _AppendLogLine('cancelled', '{}');
  // ADR-288 clean cancellation: force completion now so MCP teardown + panel
  // unblock fire promptly instead of waiting on the child to close its pipes.
  // Idempotent via FCompletedFlag; pending chunks stay suppressed (FCancelledFlag).
  _MaybeFireComplete;
end;

function TCLIDispatcherRun.IsRunning: Boolean;
begin
  Result := FCompletedFlag = 0;
end;

function TCLIDispatcherRun.WaitFor(const ATimeoutMs: Cardinal): Boolean;
begin
  Result := FCompleteEvent.WaitFor(ATimeoutMs) = wrSignaled;
end;

function TCLIDispatcherRun.RunId: TGUID;
begin
  Result := FRunId;
end;

function TCLIDispatcherRun.StderrText: string;
begin
  // Whatever the process wrote, independent of whether we chose to SHOW it. The
  // session-id header lives here on a successful run.
  Result := FStderrText;
end;

{ TCLIDispatcherSink }

constructor TCLIDispatcherSink.Create(const ARun: TCLIDispatcherRun;
  const AKeepAlive: IDispatcherRunHandle);
begin
  inherited Create;
  FRun := ARun;
  FKeepAlive := AKeepAlive;
  FSelf := Self;   // survive the caller's stack; released on the last stream end
  FStreamEnds := 0;
end;

procedure TCLIDispatcherSink.OnChunk(const AKind: TProcessStreamKind;
  const ABytes: TBytes; const ACount: Integer);
begin
  // Runs on a read thread. FKeepAlive guarantees FRun is alive here: it is
  // released only after BOTH streams have ended, and a stream that has ended
  // cannot deliver another chunk.
  if Assigned(FRun) then
    FRun._OnChunk(AKind, ABytes, ACount);
end;

procedure TCLIDispatcherSink.OnStreamEnd(const AKind: TProcessStreamKind);
var
  LLast: Boolean;
begin
  // Delivered on the MAIN thread (the read thread's OnTerminate fires via
  // Synchronize), one call per stream. The SECOND one means the child can never
  // produce output again, so it is safe -- and necessary, or the run leaks -- to
  // drop the keep-alive and free this sink.
  LLast := _AtomicInc(FStreamEnds) >= 2;
  try
    if Assigned(FRun) then
      FRun._OnStreamEnd(AKind);
  except
    on E: Exception do
      // Never raise across the read thread's marshalled terminate notification.
      _DebugLog('[Aefos] CLI sink stream-end swallowed ' + E.ClassName);
  end;
  if LLast then
  begin
    FRun := nil;
    // Order matters: _OnStreamEnd above already queued the completion (whose own
    // carrier holds its own keep-alive), so releasing here cannot strand it.
    FKeepAlive := nil;
    FSelf := nil;   // MUST be the last statement -- may free Self here.
  end;
end;

{ TCLIDispatcherChunkDispatch }

constructor TCLIDispatcherChunkDispatch.Create(const ARun: TCLIDispatcherRun;
  const AKeepAlive: IDispatcherRunHandle;
  const ACallback: TDispatcherChunkCallback; const AText: string);
begin
  inherited Create;
  FRun := ARun;
  FKeepAlive := AKeepAlive;
  FCallback := ACallback;
  FText := AText;
end;

procedure TCLIDispatcherChunkDispatch.Fire;
begin
  // Main thread. The cancelled check is read through the run the keep-alive is
  // holding, so it is the same suppression the closure did.
  try
    if Assigned(FKeepAlive) and (FRun.FCancelledFlag = 0) and Assigned(FCallback) then
      FCallback(FText);
  finally
    Free;   // one-shot: freed after firing on the main thread
  end;
end;

{ TCLIDispatcherCompletionDispatch }

constructor TCLIDispatcherCompletionDispatch.Create(
  const ARun: TCLIDispatcherRun; const AKeepAlive: IDispatcherRunHandle;
  const AOnComplete: TDispatcherCompleteCallback;
  const AOnError: TDispatcherErrorCallback;
  const AErrorText: string; const AState: TRunCompletion);
begin
  inherited Create;
  FRun := ARun;
  FKeepAlive := AKeepAlive;
  FOnComplete := AOnComplete;
  FOnError := AOnError;
  FErrorText := AErrorText;
  FExitCode := AState.ExitCode;
  FDuration := AState.Duration;
end;

procedure TCLIDispatcherCompletionDispatch.Fire;
begin
  // Main thread. Error-then-complete-then-signal, the closure's exact order.
  try
    if Assigned(FKeepAlive) then
    begin
      if (FErrorText <> '') and Assigned(FOnError) then
        FOnError(FErrorText);
      if Assigned(FOnComplete) then
        FOnComplete(Integer(FExitCode), FDuration);
      FRun.FCompleteEvent.SetEvent;
    end;
  finally
    Free;
  end;
end;

{ TWatchdogThread }

constructor TWatchdogThread.Create(const ARun: TCLIDispatcherRun);
begin
  FRun := ARun;
  // FreeOnTerminate stays False: the owning run joins + frees this thread in its
  // destructor (R-1), so its lifetime is bounded by the run's.
  inherited Create(False);
end;

procedure TWatchdogThread.Execute;
begin
  // Natural/cancel completion (or the destructor) signals the event -> wrSignaled
  // -> exit cleanly. Only a genuine timeout drives the terminate/complete path.
  if FRun.FCompleteEvent.WaitFor(FRun.FTimeoutMs) = wrSignaled then
    Exit;
  FRun._HandleTimeout;
end;

end.
