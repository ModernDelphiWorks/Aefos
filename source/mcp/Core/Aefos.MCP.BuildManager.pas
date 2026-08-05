unit Aefos.MCP.BuildManager;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Session-scoped build-job registry (ESP-002, Epic 3/5 Demand 4/5).

  Asynchronous build model (ADR-068):
    - RunBuild registers a job here and returns its build_id immediately.
    - GetBuildStatus polls the job state through this registry.

  Cancellation token (RN-C02, ADR-069):
    - Each job carries an IMCPCancellationToken — a thread-safe flag.
    - notifications/cancelled flips it via IMCPCancellationSink.RequestCancel,
      keyed by build_id.

  The manager is pure RTL — no OTA, no VCL — so every operation runs on the
  MCP worker thread (BR-10) and the unit is fully unit-testable. The job
  registry and the tokens are guarded by a single critical section.

  Lifetime (ADR-056): one manager per TMCPServer session, discarded when the
  server stops. No build job survives a /agentname re-invocation.
}

interface

uses
  Aefos.MCP.Types;

type
  // Thread-safe one-shot cancellation flag carried by a build job (ADR-069).
  IMCPCancellationToken = interface
    ['{2B9E4C71-5A38-4D6F-8E02-7C1A3F9D4B65}']
    function IsCancelled: Boolean;
    procedure Cancel;
  end;

  // Session-scoped registry of asynchronous build jobs keyed by build_id
  // (ADR-070). HasActiveBuild gates a second concurrent RunBuild (BR-2).
  IMCPBuildManager = interface
    ['{8D4F1A93-6C27-4E5B-9A10-3F7E2D8B0C46}']
    function NewBuildId: string;
    procedure Register(const ABuildId: string);
    function GetState(const ABuildId: string;
      out AState: TMCPBuildState): Boolean;
    procedure SetState(const ABuildId: string; const AState: TMCPBuildState);
    function IsCancelled(const ABuildId: string): Boolean;
    function HasActiveBuild: Boolean;
  end;

  TMCPBuildManager = class(TInterfacedObject, IMCPBuildManager,
    IMCPCancellationSink)
  private
    FLock: TObject;       // TCriticalSection; opaque to keep uses lean
    FJobs: TObject;       // TDictionary<string, TBuildJob>
    FCounter: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    // IMCPBuildManager
    function NewBuildId: string;
    procedure Register(const ABuildId: string);
    function GetState(const ABuildId: string;
      out AState: TMCPBuildState): Boolean;
    procedure SetState(const ABuildId: string; const AState: TMCPBuildState);
    function IsCancelled(const ABuildId: string): Boolean;
    function HasActiveBuild: Boolean;
    // IMCPCancellationSink
    procedure RequestCancel(const ABuildId: string);
  end;

implementation

uses
  SysUtils,
  SyncObjs,
  Generics.Collections;

type
  // Thread-safe cancellation flag. Cancel is one-shot; IsCancelled is a
  // plain interlocked read so a worker-thread poll never blocks.
  TMCPCancellationToken = class(TInterfacedObject, IMCPCancellationToken)
  private
    FCancelled: Integer;
  public
    function IsCancelled: Boolean;
    procedure Cancel;
  end;

  // A single build job: its current state plus its cancellation token.
  TBuildJob = record
    State: TMCPBuildState;
    Token: IMCPCancellationToken;
  end;

  TJobMap = TDictionary<string, TBuildJob>;

{ TMCPCancellationToken }

function TMCPCancellationToken.IsCancelled: Boolean;
begin
  // FPC 3.2.2 has no TInterlocked class; the RTL exposes the same atomics as
  // plain System functions (identical semantics).
{$IFDEF FPC}
  Result := InterlockedCompareExchange(FCancelled, 0, 0) <> 0;
{$ELSE}
  Result := TInterlocked.CompareExchange(FCancelled, 0, 0) <> 0;
{$ENDIF}
end;

procedure TMCPCancellationToken.Cancel;
begin
{$IFDEF FPC}
  InterlockedExchange(FCancelled, 1);
{$ELSE}
  TInterlocked.Exchange(FCancelled, 1);
{$ENDIF}
end;

{ TMCPBuildManager }

constructor TMCPBuildManager.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FJobs := TJobMap.Create;
  FCounter := 0;
end;

destructor TMCPBuildManager.Destroy;
begin
  FJobs.Free;
  FLock.Free;
  inherited;
end;

function TMCPBuildManager.NewBuildId: string;
var
  LNext: Integer;
begin
  // Monotonic counter — every id is unique within the session and never
  // reused (BR-9). The counter never resets while the manager lives.
  TCriticalSection(FLock).Enter;
  try
    Inc(FCounter);
    LNext := FCounter;
  finally
    TCriticalSection(FLock).Leave;
  end;
  Result := 'build-' + IntToStr(LNext);
end;

procedure TMCPBuildManager.Register(const ABuildId: string);
var
  LJob: TBuildJob;
begin
  LJob.State := bsRunning;
  LJob.Token := TMCPCancellationToken.Create;
  TCriticalSection(FLock).Enter;
  try
    TJobMap(FJobs).AddOrSetValue(ABuildId, LJob);
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

function TMCPBuildManager.GetState(const ABuildId: string;
  out AState: TMCPBuildState): Boolean;
var
  LJob: TBuildJob;
begin
  AState := bsRunning;
  TCriticalSection(FLock).Enter;
  try
    Result := TJobMap(FJobs).TryGetValue(ABuildId, LJob);
    if Result then
      AState := LJob.State;
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

procedure TMCPBuildManager.SetState(const ABuildId: string;
  const AState: TMCPBuildState);
var
  LJob: TBuildJob;
begin
  // A no-op for an unknown id — records are value types, so a found job is
  // mutated and written back under the lock.
  TCriticalSection(FLock).Enter;
  try
    if TJobMap(FJobs).TryGetValue(ABuildId, LJob) then
    begin
      LJob.State := AState;
      TJobMap(FJobs).AddOrSetValue(ABuildId, LJob);
    end;
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

function TMCPBuildManager.IsCancelled(const ABuildId: string): Boolean;
var
  LJob: TBuildJob;
begin
  // Unknown id → False. The token read itself is lock-free.
  TCriticalSection(FLock).Enter;
  try
    if not TJobMap(FJobs).TryGetValue(ABuildId, LJob) then
      Exit(False);
  finally
    TCriticalSection(FLock).Leave;
  end;
  Result := LJob.Token.IsCancelled;
end;

function TMCPBuildManager.HasActiveBuild: Boolean;
var
  LJob: TBuildJob;
begin
  Result := False;
  TCriticalSection(FLock).Enter;
  try
    for LJob in TJobMap(FJobs).Values do
      if LJob.State = bsRunning then
        Exit(True);
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

procedure TMCPBuildManager.RequestCancel(const ABuildId: string);
var
  LJob: TBuildJob;
begin
  // IMCPCancellationSink seam (ADR-069): flip the target job's token.
  // An unknown build_id is a silent no-op (BR-6).
  TCriticalSection(FLock).Enter;
  try
    if not TJobMap(FJobs).TryGetValue(ABuildId, LJob) then
      Exit;
  finally
    TCriticalSection(FLock).Leave;
  end;
  LJob.Token.Cancel;
end;

end.
