unit Aefos.Provider.Ollama;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Ollama HTTP transport (phase 2 of meta\ollama-provider-plan.md): streams
  POST /api/chat NDJSON into per-chunk events and fetches /api/tags. The pure
  request/parse logic lives in Aefos.Provider.Ollama.Core; THIS unit owns the
  I/O and the threading, nothing else — no Vcl.*, no ToolsAPI.

  Portability (Aefos -> Lazarus, Phase D): the HTTP edge now runs through the
  Aefos.Compat.Http streaming seam (Delphi -> System.Net.HttpClient; FPC ->
  WinINet), and the six anonymous methods this unit used are recast as carrier
  objects with bound `of object` methods so FPC 3.2.2 (no anonymous methods,
  no TThread.CreateAnonymousThread) builds the same behaviour. Every per-run
  datum lives on a per-call carrier (TOllamaChatJob / TOllamaModelsJob), never a
  shared transport field - concurrent runs must not alias state. The Delphi
  runtime behaviour is unchanged (same threads, same main-thread marshalling,
  same single-terminal guarantee).

  Threading contract: ChatStream/FetchModels return immediately and run on a
  private worker thread; every event fires on the MAIN thread (TThread.Queue).
  ChatStream guarantees EXACTLY ONE terminal event per run (Done=True or
  Error<>''), including on connect failure and on Cancel (a cancel ends the
  stream as a normal Done — mirroring how a CLI kill drives the executor's
  stream-end path).

  ⛔ IDE-UNLOAD rules: nothing here may outlive the BPL. Workers are counted
  (GActiveWorkers), events are gated on GShuttingDown BEFORE queueing, and
  finalization flags shutdown + drains the workers with a bounded wait —
  teardown never raises. The streaming callback returns False to abort the
  transfer the moment Cancel or shutdown is seen, so a run unwinds fast. Residual
  risk accepted: a worker blocked in a silent connect/read can survive the
  drain window — the executor (phase 3) cancels the run during its own
  guarded shutdown, which closes that hole in practice.
}

interface

uses
  {$IFDEF FPC}
  SysUtils,
  {$ELSE}
  System.SysUtils,
  {$ENDIF}
  Aefos.Provider.Ollama.Core;

type
  // Both fire on the main thread. On Delphi a `reference to` (a capturing
  // closure or a bound method binds); FPC 3.2.2 has no anonymous methods, so an
  // `of object` method pointer - callers pass a bound method either way.
  {$IFDEF FPC}
  TOllamaChunkEvent = procedure(const AChunk: TOllamaChunk) of object;
  TOllamaModelsEvent = procedure(const AModels: TArray<string>;
    const AError: string) of object;
  {$ELSE}
  TOllamaChunkEvent = reference to procedure(const AChunk: TOllamaChunk);
  TOllamaModelsEvent = reference to procedure(const AModels: TArray<string>;
    const AError: string);
  {$ENDIF}

  IOllamaTransport = interface
    ['{7C1A9E44-52D3-4B6F-9A28-E3F0C6B815D7}']
    // Streams one /api/chat request (body built by OllamaBuildChatRequest with
    // stream=true). Exactly one terminal chunk is guaranteed.
    procedure ChatStream(const ABaseUrl, ARequestBody: string;
      const AOnChunk: TOllamaChunkEvent);
    // Lists the local models (GET /api/tags, short timeout). AModels may be
    // empty with AError = '' (endpoint up, nothing pulled yet).
    procedure FetchModels(const ABaseUrl: string;
      const AOnModels: TOllamaModelsEvent);
    // Aborts the in-flight ChatStream (no-op when idle). The terminal Done
    // chunk still arrives through the normal path.
    procedure Cancel;
    // True while a ChatStream run is in flight.
    function Busy: Boolean;
  end;

function NewOllamaTransport: IOllamaTransport;

implementation

uses
  {$IFDEF FPC}
  Classes,
  {$ELSE}
  System.Classes,
  {$ENDIF}
  Aefos.Compat.Http;

const
  CConnectTimeoutMs = 10000;
  CSendTimeoutMs = 30000;
  // First bytes can take a while on a cold model load; once streaming starts
  // the recv gaps are short. Applied per receive wait, not to the whole run.
  CResponseTimeoutMs = 120000;
  CTagsTimeoutMs = 5000;
  CShutdownDrainMs = 2000;
  CContentTypeJson = 'application/json';

var
  GShuttingDown: Boolean = False;
  GActiveWorkers: Integer = 0;

type
  // Non-2xx with the SERVER'S own reason (Ollama answers e.g. 404 with a
  // {"error":"..."} body). The message is surfaced VERBATIM - a class-name
  // prefix would bury the one line the user actually needs (caught by the CLI
  // E2E harness, 2026-07-09).
  EOllamaServerError = class(Exception);

  TOllamaTransport = class;

  // Runs a carrier's bound method on a private background thread, replacing
  // TThread.CreateAnonymousThread (unsupported on FPC 3.2.2). Owns AOwned (the
  // job carrier) and frees it when the run ends; holds an interface ref so the
  // transport outlives a caller that releases it mid-run; keeps GActiveWorkers
  // accurate for the finalization drain.
  TOllamaWorkerThread = class(TThread)
  private
    FRun: TThreadMethod;
    FOwned: TObject;
    FKeepAlive: IInterface;
  protected
    procedure Execute; override;
  public
    constructor Create(const ARun: TThreadMethod; const AOwned: TObject;
      const AKeepAlive: IInterface);
  end;

  // One main-thread chunk delivery: carries a COPY of the chunk plus the sink,
  // fires it on the main thread and frees itself. Replaces the queued closure;
  // a value copy keeps each delivery independent of the (possibly finished) job.
  TOllamaChunkDispatch = class
  private
    FOnChunk: TOllamaChunkEvent;
    FChunk: TOllamaChunk;
  public
    constructor Create(const AOnChunk: TOllamaChunkEvent;
      const AChunk: TOllamaChunk);
    procedure Fire;
  end;

  // One main-thread models delivery (see TOllamaChunkDispatch).
  TOllamaModelsDispatch = class
  private
    FOnModels: TOllamaModelsEvent;
    FModels: TArray<string>;
    FError: string;
  public
    constructor Create(const AOnModels: TOllamaModelsEvent;
      const AModels: TArray<string>; const AError: string);
    procedure Fire;
  end;

  // Per-request carrier for ONE ChatStream run: owns every per-call datum (never
  // a shared transport field - concurrent runs must not alias). Execute runs on
  // the worker thread; OnBytes is the Aefos.Compat.Http streaming callback.
  TOllamaChatJob = class
  private
    FOwner: TOllamaTransport;
    FUrl: string;
    FRequestBody: string;
    FOnChunk: TOllamaChunkEvent;
    FDecoder: TOllamaUtf8StreamDecoder;
    FBuffer: string;
    FTerminalSent: Boolean;
    procedure _EmitChunk(const AChunk: TOllamaChunk);
    procedure _EmitTerminalDone;
    procedure _DrainBuffer;
    function _StopRequested: Boolean;
  public
    constructor Create(const AOwner: TOllamaTransport;
      const AUrl, ARequestBody: string; const AOnChunk: TOllamaChunkEvent);
    destructor Destroy; override;
    function OnBytes(const AChunk: TBytes): Boolean;
    procedure Execute;
  end;

  // Per-request carrier for one FetchModels run (GET /api/tags).
  TOllamaModelsJob = class
  private
    FOwner: TOllamaTransport;
    FUrl: string;
    FOnModels: TOllamaModelsEvent;
  public
    constructor Create(const AOwner: TOllamaTransport; const AUrl: string;
      const AOnModels: TOllamaModelsEvent);
    procedure Execute;
  end;

  TOllamaTransport = class(TInterfacedObject, IOllamaTransport)
  private
    FCancelled: Integer;   // Interlocked flag: main thread sets, worker reads
    FChatActive: Integer;  // Interlocked count of in-flight ChatStream runs
    // Spawns a worker thread running ARun (a carrier method) that owns AOwned.
    procedure _StartJob(const ARun: TThreadMethod; const AOwned: TObject);
  public
    procedure ChatStream(const ABaseUrl, ARequestBody: string;
      const AOnChunk: TOllamaChunkEvent);
    procedure FetchModels(const ABaseUrl: string;
      const AOnModels: TOllamaModelsEvent);
    procedure Cancel;
    function Busy: Boolean;
  end;

function NewOllamaTransport: IOllamaTransport;
begin
  Result := TOllamaTransport.Create;
end;

// Atomic counter ops, spelled per compiler: Delphi has the AtomicX intrinsics
// (System), FPC the global InterlockedX (System). Neither name is shared, so a
// thin wrapper keeps the call sites single-source.
procedure _AtomicInc(var ATarget: Integer);
begin
  {$IFDEF FPC}
  InterlockedIncrement(ATarget);
  {$ELSE}
  AtomicIncrement(ATarget);
  {$ENDIF}
end;

procedure _AtomicDec(var ATarget: Integer);
begin
  {$IFDEF FPC}
  InterlockedDecrement(ATarget);
  {$ELSE}
  AtomicDecrement(ATarget);
  {$ENDIF}
end;

procedure _AtomicSet(var ATarget: Integer; const AValue: Integer);
begin
  {$IFDEF FPC}
  InterlockedExchange(ATarget, AValue);
  {$ELSE}
  AtomicExchange(ATarget, AValue);
  {$ENDIF}
end;

// Delivers AMethod (a one-shot dispatch's Fire) to the main thread. Callers
// gate on GShuttingDown BEFORE building the dispatch, so nothing is marshalled
// past finalization (a proc run against an unmapped BPL - the keybinding lesson,
// in HTTP form - and, on FPC, a Synchronize the sleeping drain loop would never
// service).
//   Delphi: TThread.Queue (async, non-blocking) - the original behaviour.
//   FPC 3.2.2: TThread.Synchronize. FPC reaps a FreeOnTerminate thread's pending
//   Queue() entries when it terminates (Delphi does not), so an async post can
//   die unfired; Synchronize completes before the thread ends, and the blocking
//   is harmless for the pull-based CLI pump (CheckSynchronize services it).
procedure _MarshalToMain(const AMethod: TThreadMethod);
begin
  {$IFDEF FPC}
  TThread.Synchronize(nil, AMethod);
  {$ELSE}
  TThread.Queue(nil, AMethod);
  {$ENDIF}
end;

{ TOllamaWorkerThread }

constructor TOllamaWorkerThread.Create(const ARun: TThreadMethod;
  const AOwned: TObject; const AKeepAlive: IInterface);
begin
  FRun := ARun;
  FOwned := AOwned;
  FKeepAlive := AKeepAlive;
  FreeOnTerminate := True;
  inherited Create(False);   // start at once
end;

procedure TOllamaWorkerThread.Execute;
begin
  try
    FRun();
  finally
    FOwned.Free;             // free the job carrier once its run is done
    FKeepAlive := nil;
    _AtomicDec(GActiveWorkers);
  end;
end;

{ TOllamaChunkDispatch }

constructor TOllamaChunkDispatch.Create(const AOnChunk: TOllamaChunkEvent;
  const AChunk: TOllamaChunk);
begin
  inherited Create;
  FOnChunk := AOnChunk;
  FChunk := AChunk;
end;

procedure TOllamaChunkDispatch.Fire;
begin
  try
    if Assigned(FOnChunk) then
      FOnChunk(FChunk);
  finally
    Free;   // one-shot: freed after firing on the main thread
  end;
end;

{ TOllamaModelsDispatch }

constructor TOllamaModelsDispatch.Create(const AOnModels: TOllamaModelsEvent;
  const AModels: TArray<string>; const AError: string);
begin
  inherited Create;
  FOnModels := AOnModels;
  FModels := AModels;
  FError := AError;
end;

procedure TOllamaModelsDispatch.Fire;
begin
  try
    if Assigned(FOnModels) then
      FOnModels(FModels, FError);
  finally
    Free;
  end;
end;

{ TOllamaChatJob }

constructor TOllamaChatJob.Create(const AOwner: TOllamaTransport;
  const AUrl, ARequestBody: string; const AOnChunk: TOllamaChunkEvent);
begin
  inherited Create;
  FOwner := AOwner;
  FUrl := AUrl;
  FRequestBody := ARequestBody;
  FOnChunk := AOnChunk;
  FDecoder := TOllamaUtf8StreamDecoder.Create;
  FBuffer := '';
  FTerminalSent := False;
end;

destructor TOllamaChatJob.Destroy;
begin
  FDecoder.Free;
  inherited Destroy;
end;

function TOllamaChatJob._StopRequested: Boolean;
begin
  Result := GShuttingDown or (FOwner.FCancelled <> 0);
end;

procedure TOllamaChatJob._EmitChunk(const AChunk: TOllamaChunk);
var
  LDispatch: TOllamaChunkDispatch;
  LMethod: TThreadMethod;
begin
  if FTerminalSent then
    Exit;
  if AChunk.Done or (AChunk.Error <> '') then
    FTerminalSent := True;
  // Gate before building the dispatch: nothing marshals past finalization (and,
  // on FPC, no Synchronize the sleeping drain loop would deadlock on).
  if GShuttingDown then
    Exit;
  LDispatch := TOllamaChunkDispatch.Create(FOnChunk, AChunk);
  LMethod := LDispatch.Fire;
  _MarshalToMain(LMethod);
end;

procedure TOllamaChatJob._EmitTerminalDone;
var
  LChunk: TOllamaChunk;
begin
  LChunk := Default(TOllamaChunk);
  LChunk.Done := True;
  _EmitChunk(LChunk);
end;

procedure TOllamaChatJob._DrainBuffer;
var
  LLines: TArray<string>;
  LLine: string;
  LChunk: TOllamaChunk;
begin
  LLines := OllamaSplitBufferLines(FBuffer);
  for LLine in LLines do
    if OllamaParseChunk(LLine, LChunk) then
      _EmitChunk(LChunk);
end;

// Aefos.Compat.Http streaming callback (worker thread). Aborts (returns False)
// the instant Cancel or shutdown is seen - BEFORE processing the block, mirroring
// the old sink's raise-on-see. Otherwise decodes + drains complete NDJSON lines.
function TOllamaChatJob.OnBytes(const AChunk: TBytes): Boolean;
begin
  if _StopRequested then
    Exit(False);
  FBuffer := FBuffer + FDecoder.Decode(AChunk);
  _DrainBuffer;
  Result := True;
end;

procedure TOllamaChatJob.Execute;
var
  LStatus: Integer;
  LStatusText, LError, LServerError, LProbe, LLine: string;
  LChunk: TOllamaChunk;
  LOnBytes: TAefosHttpChunkProc;
  LOk: Boolean;
begin
  try
    try
      LOnBytes := OnBytes;
      LOk := TAefosHttp.TryPostStream(FUrl, FRequestBody, CContentTypeJson,
        LOnBytes, CConnectTimeoutMs, CSendTimeoutMs, CResponseTimeoutMs,
        LStatus, LStatusText, LError);

      // A cancel/shutdown ends the stream normally (Done), like a CLI kill.
      if _StopRequested then
      begin
        _EmitTerminalDone;
        Exit;
      end;
      if not LOk then
        raise EOllamaServerError.Create(LError);   // transport-level failure

      if LStatus <> 200 then
      begin
        // The error body already streamed into FBuffer (it sits there, usually
        // without a trailing LF). Lift the server's own message out of it; fall
        // back to the bare status line.
        LServerError := '';
        LProbe := FBuffer + #10;
        FBuffer := '';
        for LLine in OllamaSplitBufferLines(LProbe) do
          if OllamaParseChunk(LLine, LChunk) and (LChunk.Error <> '') then
            LServerError := LChunk.Error;
        if LServerError = '' then
          LServerError := Format('HTTP %d: %s', [LStatus, LStatusText]);
        raise EOllamaServerError.Create(LServerError);
      end;

      // Flush a trailing line the server sent without a final LF, then guarantee
      // the terminal event when the server never said done.
      if FBuffer <> '' then
      begin
        FBuffer := FBuffer + #10;
        _DrainBuffer;
      end;
      if not FTerminalSent then
        _EmitTerminalDone;
    except
      on E: Exception do
      begin
        if _StopRequested then
          _EmitTerminalDone
        else
        begin
          LChunk := Default(TOllamaChunk);
          // Server-reported reasons go out verbatim; only unexpected exceptions
          // keep the class-name prefix (diagnostic value).
          if E is EOllamaServerError then
            LChunk.Error := E.Message
          else
            LChunk.Error := E.ClassName + ': ' + E.Message;
          LChunk.Done := True;
          _EmitChunk(LChunk);
        end;
      end;
    end;
  finally
    _AtomicDec(FOwner.FChatActive);
  end;
end;

{ TOllamaModelsJob }

constructor TOllamaModelsJob.Create(const AOwner: TOllamaTransport;
  const AUrl: string; const AOnModels: TOllamaModelsEvent);
begin
  inherited Create;
  FOwner := AOwner;
  FUrl := AUrl;
  FOnModels := AOnModels;
end;

procedure TOllamaModelsJob.Execute;
var
  LStatus: Integer;
  LBody, LError: string;
  LModels: TArray<string>;
  LDispatch: TOllamaModelsDispatch;
  LMethod: TThreadMethod;
begin
  LError := '';
  SetLength(LModels, 0);
  try
    if TAefosHttp.TryGetText(FUrl, LStatus, LBody, LError, CTagsTimeoutMs) then
    begin
      if LStatus = 200 then
        LModels := OllamaParseTagsModels(LBody)
      else
        LError := Format('HTTP %d', [LStatus]);
    end;
    // On a transport failure TryGetText already set LError.
  except
    on E: Exception do
      LError := E.ClassName + ': ' + E.Message;
  end;
  if GShuttingDown then
    Exit;
  LDispatch := TOllamaModelsDispatch.Create(FOnModels, LModels, LError);
  LMethod := LDispatch.Fire;
  _MarshalToMain(LMethod);
end;

{ TOllamaTransport }

procedure TOllamaTransport._StartJob(const ARun: TThreadMethod;
  const AOwned: TObject);
begin
  _AtomicInc(GActiveWorkers);
  // Self (a TInterfacedObject) rides as the keep-alive interface ref.
  TOllamaWorkerThread.Create(ARun, AOwned, Self);
end;

procedure TOllamaTransport.Cancel;
begin
  _AtomicSet(FCancelled, 1);
end;

function TOllamaTransport.Busy: Boolean;
begin
  Result := FChatActive > 0;
end;

procedure TOllamaTransport.ChatStream(const ABaseUrl, ARequestBody: string;
  const AOnChunk: TOllamaChunkEvent);
var
  LJob: TOllamaChatJob;
  LRun: TThreadMethod;
begin
  _AtomicSet(FCancelled, 0);
  _AtomicInc(FChatActive);
  LJob := TOllamaChatJob.Create(Self, OllamaChatEndpoint(ABaseUrl),
    ARequestBody, AOnChunk);
  LRun := LJob.Execute;
  _StartJob(LRun, LJob);
end;

procedure TOllamaTransport.FetchModels(const ABaseUrl: string;
  const AOnModels: TOllamaModelsEvent);
var
  LJob: TOllamaModelsJob;
  LRun: TThreadMethod;
begin
  LJob := TOllamaModelsJob.Create(Self, OllamaTagsEndpoint(ABaseUrl), AOnModels);
  LRun := LJob.Execute;
  _StartJob(LRun, LJob);
end;

var
  GDrainStart: Cardinal;

initialization

finalization
  // ⛔ IDE-UNLOAD: flag first (gates new queue posts + aborts callbacks), then
  // drain the workers with a bounded wait. Never raises.
  GShuttingDown := True;
  try
    GDrainStart := TThread.GetTickCount;
    while (GActiveWorkers > 0) and
      (TThread.GetTickCount - GDrainStart < CShutdownDrainMs) do
      TThread.Sleep(20);
  except
    // Teardown must never raise.
  end;

end.
