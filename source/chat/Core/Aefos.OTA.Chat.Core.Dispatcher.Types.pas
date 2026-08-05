unit Aefos.OTA.Chat.Core.Dispatcher.Types;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Domain types for the CLI dispatcher contract (ESP-002, demand 2/5).

  Declares the request/callback shape, the run handle interface, and the
  exception family used by Core.CLIDispatcher. No Win32, no IO — pure
  contract definitions.

  Architectural baseline:
    - ADR-004: subprocess transport via Win32 process API + redirected pipes.
    - ADR-005: NO_COLOR=1 + defensive ANSI strip; never parse ANSI.
    - ADR-006: Delphi 13 only.
    - RN-002 / RN-003: zero outbound HTTP from this layer; logs stay local.
}

interface

uses
  SysUtils,
  Generics.Collections;

type
  // Anonymous-method callbacks on Delphi; FPC 3.2.2 has no anonymous methods,
  // so the port gets `of object` method-pointer twins. These callback types are
  // consumed only by the (Delphi-only) CLIDispatcher today; on FPC they need to
  // COMPILE (the type is pulled transitively via Config.Types) - they are wired
  // to a real dispatcher when the FPC dispatcher lands (Phase D).
{$IFDEF FPC}
  TDispatcherChunkCallback = procedure(const AChunk: string) of object;
  TDispatcherCompleteCallback = procedure(const AExitCode: Integer;
    const ADurationMs: Cardinal) of object;
  TDispatcherErrorCallback = procedure(const AMessage: string) of object;
{$ELSE}
  TDispatcherChunkCallback = reference to procedure(const AChunk: string);
  TDispatcherCompleteCallback = reference to procedure(const AExitCode: Integer;
    const ADurationMs: Cardinal);
  TDispatcherErrorCallback = reference to procedure(const AMessage: string);
{$ENDIF}

  // Stdout output-filter policy (ADR-289). ofpStrip (default) keeps today's
  // behaviour: inject NO_COLOR=1 in the child env and defensively strip CSI
  // escapes from stdout. ofpRaw forwards the decoded stdout verbatim (escapes
  // preserved) and does NOT inject NO_COLOR, so the child may emit colour.
  TOutputFilterPolicy = (ofpStrip, ofpRaw);

  // Record helper (XE3+): the policy's config.json token round-trip lives ON the
  // enum itself. The loose OutputFilterToString / ParseOutputFilter below now
  // delegate here.
  TOutputFilterPolicyHelper = record helper for TOutputFilterPolicy
    // config.json token: ofpStrip -> 'strip', ofpRaw -> 'raw'.
    function ToToken: string;
    // Parse a config.json token; any unrecognised value silently degrades to
    // ofpStrip (BR-4 — never raise on a malformed field).
    class function FromToken(const AValue: string): TOutputFilterPolicy; static;
  end;

  TDispatchRequest = record
    ExecutorPath: string;
    Prompt: string;
    WorkingDirectory: string;
    EnvOverrides: TArray<TPair<string, string>>;
    // Generic positional args emitted between executor and prompt
    // (ADR-037). Callers own the semantics: CommandExecutor sets
    // ['--model', <value>] when config.Model is non-empty.
    Args: TArray<string>;
    // Executor token (TProviderRegistry.ExecutorKindToString) — keys the per-executor session
    // log file (ADR-085). Additive: an empty value degrades to the
    // date-only log file name (C-5).
    Executor: string;
    // Maximum total run duration in milliseconds (ADR-288). 0 = disabled =
    // today's unbounded behaviour (BR-1). When > 0 the dispatcher arms an
    // event-waiting watchdog that terminates and completes a runaway child.
    TimeoutMs: Cardinal;
    // Stdout filter policy (ADR-289). Default ofpStrip preserves today.
    OutputFilter: TOutputFilterPolicy;
  end;

  IDispatcherRunHandle = interface
    ['{A2D5F1B8-7E33-4E0B-9A0F-3C9C8B6D5421}']
    function IsRunning: Boolean;
    procedure Cancel;
    function WaitFor(const ATimeoutMs: Cardinal): Boolean;
    function RunId: TGUID;
    { The run's raw stderr, whatever its exit code.

      NOT the same thing as the error callback, and that difference is a defect
      we shipped: stderr is only DELIVERED as an error when the process failed
      (CLIDispatcher._BuildErrorText), because showing CLI chatter as an error on
      a successful turn would be nonsense in the chat. But Codex prints its
      `session id:` header to stderr on EVERY run, including the successful ones
      -- so the conversation id was thrown away on exactly the runs that had one,
      and every turn started a brand-new session. The model kept answering with
      no memory of the previous message.

      So the panel still sees stderr only as an error; the executor reads it from
      here regardless. Empty when the run produced none. }
    function StderrText: string;
  end;

  // --- IProcessRunner spawn seam (ESP-004 / ADR-260, ADR-261) --------------
  //
  // The OS-process concern is abstracted behind IProcessRunner so the
  // dispatcher orchestration (decode, dispatch, cancel, completion, logging)
  // is drivable headless with a fake runner — no real child process. The seam
  // boundary is fixed at RAW, UNDECODED bytes (ADR-261 / BR-4): the UTF-8 carry
  // decode + ANSI strip stay on the covered dispatcher/decode side, so a fake
  // runner exercises the genuine transform. A runner that emitted decoded
  // strings is rejected by design.

  // Which redirected child stream a raw chunk / end-of-stream belongs to.
  TProcessStreamKind = (pskStdout, pskStderr);

  // Delivers a raw, undecoded byte chunk (first ACount bytes of ABytes) from
  // the named child stream. Invoked on the runner's read thread.
{$IFDEF FPC}
  TProcessChunkProc = procedure(const AKind: TProcessStreamKind;
    const ABytes: TBytes; const ACount: Integer) of object;
{$ELSE}
  TProcessChunkProc = reference to procedure(const AKind: TProcessStreamKind;
    const ABytes: TBytes; const ACount: Integer);
{$ENDIF}

  // Fires once per stream as that stream's read loop ends (so the dispatcher
  // can flush its per-stream decode carry and count completion). Delivered via
  // the read thread's terminate notification (main thread) like the
  // pre-refactor OnTerminate.
{$IFDEF FPC}
  TProcessStreamEndProc = procedure(const AKind: TProcessStreamKind) of object;
{$ELSE}
  TProcessStreamEndProc = reference to procedure(const AKind: TProcessStreamKind);
{$ENDIF}

  // Fully-resolved spawn parameters. The command line and env block are built
  // by the dispatcher via the pure decode seam and passed verbatim; the runner
  // only performs the OS spawn. ExecutorPath is carried for the spawn-failure
  // error message (byte-identical to the pre-refactor message).
  TProcessStartSpec = record
    ExecutorPath: string;
    CommandLine: string;
    EnvBlock: string;
    WorkingDirectory: string;
  end;

  // One started child process. Owns its OS handles and read threads; closes
  // them on release. Reading does not begin until BeginRead is called, so the
  // dispatcher can write the 'spawn' log line between a successful spawn and
  // the first output chunk — exactly the pre-refactor ordering.
  IProcessSession = interface
    ['{6F1C2E84-3A77-4D90-9B2A-71C5E0D8A3F4}']
    function IsRunning: Boolean;
    // Starts pumping raw stdout/stderr chunks via AOnChunk; AOnStreamEnd fires
    // once per stream as its read loop ends (delivered like the pre-refactor
    // OnTerminate, i.e. on the main thread).
    procedure BeginRead(const AOnChunk: TProcessChunkProc;
      const AOnStreamEnd: TProcessStreamEndProc);
    procedure Terminate;
    // Collects the child's exit code applying the dispatcher's grace wait.
    // Mirrors the pre-refactor _CollectCompletionState exit-code policy:
    //   - no real process            -> 0
    //   - exited within AGraceMs      -> the process exit code
    //   - still running after AGraceMs-> $FFFFFFFF (DWORD(-1))
    function GetCompletionExitCode(const AGraceMs: Cardinal): Cardinal;
  end;

  // Spawns a child process for ASpec (open pipes + create process). Raises
  // EDispatcherSpawnFailed if the OS spawn (or pipe setup) fails. The returned
  // session is not yet reading — the caller drives that via BeginRead.
  IProcessRunner = interface
    ['{B0E4D917-5C26-4A38-8E1D-2F9A6C4B07E5}']
    function Start(const ASpec: TProcessStartSpec): IProcessSession;
  end;

  EDispatcherError = class(Exception);
  EDispatcherExecutorNotFound = class(EDispatcherError);
  EDispatcherSpawnFailed = class(EDispatcherError);

// Maps the output-filter policy to its config.json token (ofpStrip -> 'strip',
// ofpRaw -> 'raw'). Pure; consumed by Core.Config serialisation (ADR-290).
function OutputFilterToString(const APolicy: TOutputFilterPolicy): string;

// Parses a config.json token to the policy. Any unrecognised value silently
// degrades to ofpStrip (BR-4 — never raise on a malformed field).
function ParseOutputFilter(const AValue: string): TOutputFilterPolicy;

implementation

{ TOutputFilterPolicyHelper }

function TOutputFilterPolicyHelper.ToToken: string;
begin
  if Self = ofpRaw then
    Result := 'raw'
  else
    Result := 'strip';
end;

class function TOutputFilterPolicyHelper.FromToken(
  const AValue: string): TOutputFilterPolicy;
begin
  if SameText(Trim(AValue), 'raw') then
    Result := ofpRaw
  else
    Result := ofpStrip;
end;

function OutputFilterToString(const APolicy: TOutputFilterPolicy): string;
begin
  Result := APolicy.ToToken;
end;

function ParseOutputFilter(const AValue: string): TOutputFilterPolicy;
begin
  Result := TOutputFilterPolicy.FromToken(AValue);
end;

end.
