unit Aefos.Lazarus.ChatAgent;

(*
  Agent mode for the Lazarus chat: the local-model tool loop, hosted IN-PROCESS.

  WHY THIS EXISTS (and why it is NOT a copy of the Delphi chat).
  On RAD Studio, "Agent mode" is a FLAG, not a loop: TCommandExecutor.SetAgentMode
  flips TProviderDispatchContext.AgentMode, each provider turns that into CLI args
  (Claude gets --mcp-config/--allowedTools, the local model gets --mcp-pipe), and
  the tool loop then runs inside the SPAWNED PROCESS -- an external CLI, or
  AefosAgent.exe for the local model. The Delphi chat itself never executes a tool.

  The Lazarus chat has no such process: it drives the Ollama HTTP transport
  DIRECTLY (Aefos.Lazarus.ChatController._DispatchOllama). So there is no command
  line to add a flag to. For the local model, Agent mode here can only mean: we
  host the loop ourselves. That is what this unit does -- the in-process
  equivalent of AefosAgent.dpr, reusing the SAME pure cores that CLI runs on
  (Aefos.Agent.Loop / .MCP.Core / .MCP.Pipe / .Capability -- all already
  FPC-guarded and built on injected seams), talking to OUR OWN hosted MCP server
  (Aefos.Lazarus.McpHost) over its named pipe.

  Loopback over the pipe is deliberate, not laziness: it reuses the proven wire
  contract and -- critically -- keeps every request on the SERVER's rails, so
  RULE #1's view guard and the write-consent gate apply to us exactly as they
  apply to any other client. The chat gets no privileged back door.

  THREADING -- the part that must not be "simplified" later.
  The loop is SYNCHRONOUS (TAgentLoop.Run blocks; its TAgentChatStreamProc must
  not return before the stream's terminal chunk). AefosAgent.exe satisfies that on
  its MAIN thread with PumpUntil/CheckSynchronize, because a console main thread
  has nothing else to do. Doing that here would be a bug twice over:

    1. it would freeze the IDE for the whole turn, and
    2. it would DEADLOCK. Our MCP tool call blocks on a pipe read; the server
       answers it by marshalling the work (and, on the first write, the consent
       dialog) to the IDE MAIN thread. If the loop sat on the main thread, the
       thread that must service the tool call would be the thread parked waiting
       for it.

  So the loop runs on a private worker and NEVER on the main thread:
    - _StreamProc (worker) starts the async transport and parks on FStreamDone;
      the transport marshals each chunk to the MAIN thread (TThread.Synchronize),
      the LCL main loop drains that queue, and the relay signals the event. The
      IDE stays responsive; the loop still sees a blocking call.
    - _ToolExec (worker) does the blocking pipe I/O. The main thread is free to
      run the tool and the consent modal, so it completes.
    - the loop's chunk accumulation happens on the MAIN thread while the worker is
      parked in WaitFor; the event pair is the memory barrier.

  LIFETIME -- the UAF class PR #245/#246 paid for.
  The state lives in a REFCOUNTED session (TAefosAgentSession), never in the
  TThread: the controller holds IAefosAgentSession, the worker holds another ref,
  and the thread is FreeOnTerminate with no one pointing at it. So a chat window
  closed mid-turn cannot dangle -- there is no raw thread pointer to dangle ON,
  and the session simply outlives the controller until the worker unwinds. Every
  callback is additionally gated on the controller's liveness token: after the
  chat is freed the token is dead and each delta/notice/terminal is a safe no-op.
  Cancel() is safe at any time, including after the worker has already finished.

  This is why the controller never calls WaitFor: the worker can be parked in a
  blocking pipe read (Aefos.Agent.MCP.Core notes the read has no deadline yet), so
  a WaitFor on the main thread would be a hang, not a drain.

  SECURITY. This unit never grants anything. It starts the MCP host if it is not
  running (idempotent -- and starting a server is not consent), then every
  mutating tool still hits TAefosLazMcpToolsRegistrar._EnsureWriteConsent: a human
  Yes/No on the first write of the session. Reads are never gated. There is no
  bypass here, and none may be added.

  Mode delphiunicode: it matches the cores this drives (Aefos.Agent.*,
  Aefos.Provider.Ollama*, all delphiunicode => string = UnicodeString). The
  controller is {$mode delphi} (string = UTF-8 AnsiString), so the callbacks below
  are declared UnicodeString on purpose and the CONTROLLER converts through
  LazUTF8 (the _OnModels precedent). All literals are ASCII: no BOM needed.
*)

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}
{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  Aefos.Provider.Ollama.Core,
  Aefos.Provider.Ollama,
  Aefos.Agent.Loop,
  Aefos.Agent.MCP.Core;

type
  // Assistant text delta (streamed) and one-line status notice. Both fire on the
  // IDE MAIN thread. UnicodeString because this unit is delphiunicode; the
  // {$mode delphi} controller declares its handlers with the same explicit type
  // and converts to UTF-8 itself.
  TAefosAgentTextEvent = procedure(const AText: UnicodeString) of object;
  // Terminal: the turn settled. AError is '' on success.
  TAefosAgentDoneEvent = procedure(const AError: UnicodeString) of object;

  { The token every callback is gated on. Structurally the controller's
    IAefosLiveToken (published by Aefos.Lazarus.WebViewHost); redeclared here so
    this unit does not drag the LCL WebView host into the delphiunicode world.
    The controller passes its OWN token in -- one liveness truth per chat. }
  IAefosAgentLiveToken = interface
    ['{2F5C1A87-9D34-4E62-B0A1-7C63E85F49D2}']
    function IsAlive: Boolean;
  end;

  { One turn's inputs. A record with a constructor (house style) so a caller
    cannot half-fill it. }
  TAefosAgentTurn = record
    BaseUrl: UnicodeString;
    Model: UnicodeString;
    Prompt: UnicodeString;
    PipeName: UnicodeString;
    class function New(const ABaseUrl, AModel, APrompt,
      APipeName: UnicodeString): TAefosAgentTurn; static;
  end;

  { What the controller holds. Refcounted, so it is safe to keep across a window
    close and safe to drop mid-turn -- the worker holds its own ref. }
  IAefosAgentSession = interface
    ['{8A41E6D3-72B5-4C09-91F7-3D6820AE5C14}']
    // Cooperative stop: flips the loop's cancel rail, aborts the in-flight
    // stream and releases a parked hop. Idempotent; safe after the turn ended.
    procedure Cancel;
    // True once the turn has settled (the controller's teardown drain reads it).
    function Ended: Boolean;
  end;

  { Resolves the IDE's hosted MCP server for the loop.

    A SEAM, not a direct call, and deliberately so: Aefos.Lazarus.McpHost drags in
    the Lazarus IDE units (IDEIntf, the workspace facade, the MCP server), and the
    chat controller that uses this unit is ALSO compiled standalone by the runtime
    proof, which links neither. Depending on the host here
    would make the whole chat unbuildable outside the IDE package -- proven, not
    theorised: it broke lazchatproof before this seam existed. The IDE side
    installs the real provider; with none installed EnsureMcpHost honestly reports
    "no tools" and the turn degrades with a notice. }
  IAefosAgentMcpHostProvider = interface
    ['{6B3D9F52-84C1-4A70-B6E8-1F45C097A2D6}']
    // Ensures the host is running (must be idempotent and must never raise).
    // False => unavailable; APipeName is then meaningless.
    function EnsureStarted(out APipeName: UnicodeString): Boolean;
    // Why the last start failed, in words a user can act on ('' when unknown).
    // Must never raise. Without this the turn can only say "not reachable",
    // which is true and useless -- the usual cause (a second IDE already
    // holding the fixed pipe name) is invisible from here.
    function LastError: UnicodeString;
  end;

  { Static namespace for the Agent-mode preconditions the chat checks BEFORE it
    promises anything. Never instantiated. }
  TAefosLazAgentGate = class sealed
  public
    // Composition root: the IDE package installs its host provider here (see
    // Aefos.Lazarus.McpHost's initialization). Idempotent; nil uninstalls.
    class procedure InstallMcpHostProvider(
      const AProvider: IAefosAgentMcpHostProvider); static;
    // Ensures the in-process MCP host is running (idempotent). Starting a server
    // is NOT a grant: writes still meet the consent dialog. False when no provider
    // is installed or the host could not be started -- the caller must then say
    // so, never pretend.
    class function EnsureMcpHost(out APipeName: UnicodeString): Boolean; static;
    // The installed provider's reason for the last failed start ('' when there
    // is no provider or it has nothing to say). Never raises.
    class function McpUnavailableReason: UnicodeString; static;
    // True when AModel advertises Ollama's 'tools' capability. AReached tells a
    // definite "no tools" apart from "could not ask": the caller degrades
    // OPTIMISTICALLY on an unreachable probe (a blip must not silently strip
    // tools from a capable model), exactly as AefosAgent.dpr does.
    class function ModelSupportsTools(const ABaseUrl, AModel: UnicodeString;
      out AReached: Boolean): Boolean; static;
    // Starts ONE agent turn on a private worker and returns its session. Never
    // raises: a failure to even start is reported through AOnDone like any other
    // terminal, so the composer always comes back.
    class function StartTurn(const ATurn: TAefosAgentTurn;
      const ALive: IAefosAgentLiveToken;
      const AOnDelta, AOnNotice: TAefosAgentTextEvent;
      const AOnDone: TAefosAgentDoneEvent): IAefosAgentSession; static;
    // The aefos-first agent preamble (the Lazarus twin of the Delphi
    // TCommandExecutor._AssembleFinalPrompt agent branch): tells the model to
    // drive the LIVE IDE through the Aefos MCP tools -- AddComponent in the
    // Designer, EditUnit for code -- never its own file edits or a bulk .pas/.lfm
    // write. The local-model loop prepends it internally; the controller prepends
    // it to the EXTERNAL-CLI turn too, so every agentic model gets the same rule.
    class function Preamble: string; static;
  end;

implementation

uses
  Aefos.Agent.MCP.Pipe,
  Aefos.Agent.Capability,
  // THE shared, CLI-agnostic dispatch harness: the ONE owner of the aefos-first
  // preamble text. The local-model loop now prepends the SAME text the RAD Studio
  // and Lazarus external-CLI paths use (owner mandate 2026-07-20) instead of a
  // reduced local copy -- one preamble, three agentic paths.
  Aefos.Chat.Core.CliHarness;

var
  // The installed host provider (see IAefosAgentMcpHostProvider). A unit var
  // reached ONLY through TAefosLazAgentGate -- never exported, so no caller can
  // reach past the gate's guards. Written once at package registration, on the
  // main thread, before any turn can start.
  GMcpHostProvider: IAefosAgentMcpHostProvider = nil;

const
  // Per-hop stream wait. The transport owns its own recv timeout and guarantees
  // exactly one terminal chunk; this is the backstop for a transport that never
  // delivers one, which would otherwise park the worker indefinitely.
  CStreamWaitMs = 180000;
  CMcpConnectTimeoutMs = 5000;

  // Vendor-neutral, English-only (house rule): no CLI or model vendor is named.
  CNoticeNoMcp =
    'IDE tools are unavailable for this turn (the Aefos AI MCP server is not '
    + 'reachable). Answering without tools.';
  CNoticeNoTools =
    'The selected local model does not support tool calling, so it cannot act on '
    + 'the IDE. Answering as a plain chat turn -- pick a tools-capable model to '
    + 'use Agent mode.';
  CNoticeProbeBlind =
    'Could not confirm tool support for the selected local model; offering tools '
    + 'anyway.';

class function TAefosLazAgentGate.Preamble: string;
begin
  // The aefos-first preamble now has ONE owner across both IDEs: the shared
  // Aefos.Chat.Core.CliHarness. This edition passes the LAZARUS vocabulary so the
  // ONE text names Lazarus/.lfm (not RAD Studio/.dfm). This forwarder is kept so
  // any caller still resolves the SAME text the local-model loop prepends.
  Result := TAefosCliHarness.AgentPreamble(TAefosCliHarness.LazarusVocabulary);
end;

type
  { The whole turn's state, refcounted. Both the controller and the worker hold
    it, so neither owns the other and nothing dangles. Every field below is
    touched by exactly one thread at a time (see the header's threading note),
    except FTransport and FEnded, which FLock guards because Cancel may arrive
    from the main thread at any point in the run. }
  TAefosAgentSession = class(TInterfacedObject, IAefosAgentSession)
  private
    FTurn: TAefosAgentTurn;
    FLive: IAefosAgentLiveToken;
    FOnDelta: TAefosAgentTextEvent;
    FOnNotice: TAefosAgentTextEvent;
    FOnDone: TAefosAgentDoneEvent;
    FCancelled: Integer;          // the loop's cancel rail (passed as PInteger)
    FEnded: Boolean;
    FLock: TCriticalSection;      // guards FTransport + FEnded + FTerminalDone
    FTransport: IOllamaTransport;
    FStreamDone: TSimpleEvent;
    FStreamTerminal: Boolean;
    // Exactly-one-terminal claim. On cancel-mid-stream the worker synthesises a
    // terminal (below) while the transport's real terminal may still arrive on
    // the main thread via _Relay -- both would hit the same THopSink from two
    // threads, mutating its non-thread-safe content. Whoever claims this first
    // delivers the terminal to the hop; the other skips. Guarded by FLock.
    FTerminalDone: Boolean;
    FHopOnChunk: TAgentChunkEvent;
    FMcp: TAgentMcpClient;
    FToolsJson: UnicodeString;
    // Synchronize carriers (FPC 3.2.2 has no closures): the payload of the
    // pending main-thread hop. The worker is parked inside Synchronize while
    // these run and only one hop is ever in flight, so plain fields are safe.
    FPendingText: UnicodeString;
    FPendingIsNotice: Boolean;
    FPendingError: UnicodeString;
    procedure _RunText;
    procedure _RunDone;
    procedure _Deliver(const AText: UnicodeString; const AIsNotice: Boolean);
    procedure _DeliverDone(const AError: UnicodeString);
    // Loop seams (of object; FPC has no closures).
    procedure _StreamProc(const ARequestBody: UnicodeString;
      const AOnChunk: TAgentChunkEvent);
    function _ToolExec(const AName, AArgumentsJson: UnicodeString;
      out AResultText: UnicodeString; out AIsError: Boolean;
      out AError: UnicodeString): Boolean;
    procedure _OnDelta(const AText: UnicodeString);
    procedure _OnNotice(const AText: UnicodeString);
    function _ToolsProvider: UnicodeString;
    // Transport relay: fires on the MAIN thread, feeds the loop's hop sink and
    // releases the worker on the terminal chunk.
    procedure _Relay(const AChunk: TOllamaChunk);
    function _ConnectMcp(out AError: UnicodeString): Boolean;
    function _Cancelled: Boolean;
  public
    constructor Create(const ATurn: TAefosAgentTurn;
      const ALive: IAefosAgentLiveToken;
      const AOnDelta, AOnNotice: TAefosAgentTextEvent;
      const AOnDone: TAefosAgentDoneEvent);
    destructor Destroy; override;
    // The worker's body. Always delivers exactly one terminal.
    procedure Run;
    procedure Cancel;
    function Ended: Boolean;
  end;

  { The worker. Deliberately stateless beyond its ref to the session: nothing
    points at this object, so FreeOnTerminate cannot leave a dangling pointer
    behind (which is exactly what a controller-held TThread would). }
  TAefosAgentThread = class(TThread)
  private
    FHold: IAefosAgentSession;    // keeps the session alive for the whole run
    FSession: TAefosAgentSession; // raw view; valid while FHold holds
  protected
    procedure Execute; override;
  public
    constructor Create(const ASession: TAefosAgentSession);
  end;

{ TAefosAgentTurn }

class function TAefosAgentTurn.New(const ABaseUrl, AModel, APrompt,
  APipeName: UnicodeString): TAefosAgentTurn;
begin
  Result.BaseUrl := ABaseUrl;
  Result.Model := AModel;
  Result.Prompt := APrompt;
  Result.PipeName := APipeName;
end;

{ TAefosAgentThread }

constructor TAefosAgentThread.Create(const ASession: TAefosAgentSession);
begin
  inherited Create(True);   // suspended: the factory starts it once it is wired
  FHold := ASession;        // refcount +1 for the duration of the run
  FSession := ASession;
  FreeOnTerminate := True;
end;

procedure TAefosAgentThread.Execute;
begin
  try
    FSession.Run;
  finally
    // Drop the raw view before the ref, so nothing reads it after the session
    // may be freed by the release below.
    FSession := nil;
    FHold := nil;
  end;
end;

{ TAefosAgentSession }

constructor TAefosAgentSession.Create(const ATurn: TAefosAgentTurn;
  const ALive: IAefosAgentLiveToken;
  const AOnDelta, AOnNotice: TAefosAgentTextEvent;
  const AOnDone: TAefosAgentDoneEvent);
begin
  inherited Create;
  FTurn := ATurn;
  FLive := ALive;
  FOnDelta := AOnDelta;
  FOnNotice := AOnNotice;
  FOnDone := AOnDone;
  FCancelled := 0;
  FEnded := False;
  FLock := TCriticalSection.Create;
  FStreamDone := TSimpleEvent.Create;
end;

destructor TAefosAgentSession.Destroy;
begin
  // Runs only once BOTH the controller and the worker have dropped their refs,
  // so no thread is inside Run here.
  FreeAndNil(FMcp);
  FStreamDone.Free;
  FLock.Free;
  FTransport := nil;
  inherited Destroy;
end;

function TAefosAgentSession._Cancelled: Boolean;
begin
  Result := FCancelled <> 0;
end;

procedure TAefosAgentSession.Cancel;
begin
  // Callable from the main thread at ANY time -- including after Run finished
  // and after the controller is gone. Every step is guarded accordingly.
  FCancelled := 1;   // plain Integer write: the stop rail the loop polls
  FLock.Enter;
  try
    if Assigned(FTransport) then
      try
        FTransport.Cancel;
      except
        // Cancel runs from teardown: it must never raise.
      end;
  finally
    FLock.Leave;
  end;
  // Release a worker parked on the stream wait so it observes the cancel.
  if Assigned(FStreamDone) then
    FStreamDone.SetEvent;
end;

function TAefosAgentSession.Ended: Boolean;
begin
  FLock.Enter;
  try
    Result := FEnded;
  finally
    FLock.Leave;
  end;
end;

procedure TAefosAgentSession._RunText;
begin
  // MAIN thread (Synchronize). Re-check the token HERE, not only at the call
  // site: the controller can die between the worker's check and this hop.
  if (FLive = nil) or (not FLive.IsAlive) then
    Exit;
  if FPendingIsNotice then
  begin
    if Assigned(FOnNotice) then
      FOnNotice(FPendingText);
  end
  else if Assigned(FOnDelta) then
    FOnDelta(FPendingText);
end;

procedure TAefosAgentSession._RunDone;
begin
  if (FLive = nil) or (not FLive.IsAlive) then
    Exit;
  if Assigned(FOnDone) then
    FOnDone(FPendingError);
end;

procedure TAefosAgentSession._Deliver(const AText: UnicodeString;
  const AIsNotice: Boolean);
begin
  // WORKER -> MAIN via Synchronize (never Queue: FPC drops a Queue posted from a
  // FreeOnTerminate thread). The token short-circuit avoids paying for a marshal
  // to a dead controller.
  if (FLive = nil) or (not FLive.IsAlive) then
    Exit;
  FPendingText := AText;
  FPendingIsNotice := AIsNotice;
  try
    TThread.Synchronize(nil, _RunText);
  except
    // A marshalled hop must never throw back into the loop.
  end;
end;

procedure TAefosAgentSession._DeliverDone(const AError: UnicodeString);
begin
  FPendingError := AError;
  try
    if (FLive <> nil) and FLive.IsAlive then
      TThread.Synchronize(nil, _RunDone);
  except
    // Never raise out of the terminal: FEnded below MUST be set, or the
    // controller's teardown drain would spin for its whole budget.
  end;
  FLock.Enter;
  try
    FEnded := True;
  finally
    FLock.Leave;
  end;
end;

procedure TAefosAgentSession._Relay(const AChunk: TOllamaChunk);
var
  LIsTerminal: Boolean;
  LDeliver: Boolean;
  LHop: TAgentChunkEvent;
begin
  // MAIN thread (the transport marshals via Synchronize). Feed the loop's hop
  // sink FIRST -- it accumulates content/tool_calls and echoes deltas -- and only
  // then release the worker, so the worker never reads a half-filled hop.
  LIsTerminal := AChunk.Done or (AChunk.Error <> '');
  // Deltas always deliver (they flow ONLY through here, single-threaded on main).
  // The terminal is claimed once so a cancel-synthesised terminal on the worker
  // and this real one cannot both reach the hop.
  FLock.Enter;
  try
    LHop := FHopOnChunk;
    if LIsTerminal then
    begin
      LDeliver := Assigned(LHop) and (not FTerminalDone);
      if Assigned(LHop) then
        FTerminalDone := True;
    end
    else
      LDeliver := Assigned(LHop);
  finally
    FLock.Leave;
  end;
  try
    if LDeliver then
      LHop(AChunk);
  except
    // Never raise back into the transport's marshalled call.
  end;
  if LIsTerminal then
  begin
    FStreamTerminal := True;
    FStreamDone.SetEvent;
  end;
end;

procedure TAefosAgentSession._StreamProc(const ARequestBody: UnicodeString;
  const AOnChunk: TAgentChunkEvent);
var
  LFallback: TOllamaChunk;
  LWonTerminal: Boolean;
begin
  // WORKER. Start the async transport, then park until the MAIN-thread relay
  // signals the terminal chunk. We must NOT CheckSynchronize here: only the main
  // thread may drain that queue, and the LCL main loop already does.
  FStreamTerminal := False;
  FStreamDone.ResetEvent;
  FLock.Enter;
  try
    FHopOnChunk := AOnChunk;
    FTerminalDone := False;
    FTransport.ChatStream(FTurn.BaseUrl, ARequestBody, _Relay);
  finally
    FLock.Leave;
  end;
  FStreamDone.WaitFor(CStreamWaitMs);
  if not FStreamTerminal then
  begin
    // Either a cancel released us early, or the transport broke its
    // exactly-one-terminal promise. Abort the run and synthesise the terminal
    // the loop is contractually owed: returning without one would leave
    // TAgentLoop reading an empty hop and reporting an empty answer as success.
    FLock.Enter;
    try
      if Assigned(FTransport) then
        try
          FTransport.Cancel;
        except
        end;
    finally
      FLock.Leave;
    end;
    // Claim the terminal: if the real one already reached the hop via _Relay
    // (the transport's own Cancel-terminal winning the race), do NOT deliver a
    // second one into the same sink.
    FLock.Enter;
    try
      LWonTerminal := Assigned(AOnChunk) and (not FTerminalDone);
      if Assigned(AOnChunk) then
        FTerminalDone := True;
    finally
      FLock.Leave;
    end;
    if LWonTerminal then
    begin
      LFallback := Default(TOllamaChunk);
      LFallback.Done := True;
      if not _Cancelled then
        LFallback.Error := 'The local model did not answer in time.';
      AOnChunk(LFallback);
    end;
  end;
  FLock.Enter;
  try
    FHopOnChunk := nil;
  finally
    FLock.Leave;
  end;
end;

function TAefosAgentSession._ToolExec(const AName, AArgumentsJson: UnicodeString;
  out AResultText: UnicodeString; out AIsError: Boolean;
  out AError: UnicodeString): Boolean;
begin
  // WORKER. Blocking pipe I/O is correct HERE and nowhere else: the server
  // marshals the tool (and the first-write consent dialog) to the MAIN thread,
  // which is free precisely because we are not on it.
  AResultText := '';
  AIsError := False;
  AError := '';
  if FMcp = nil then
  begin
    AError := 'IDE tools are not connected.';
    Result := False;
    Exit;
  end;
  // A status line so the user can see WHY the IDE is moving. Vendor-neutral.
  _Deliver('Running IDE tool: ' + AName, True);
  try
    Result := FMcp.CallTool(AName, AArgumentsJson, AResultText, AIsError, AError);
  except
    on E: Exception do
    begin
      // A throw here must not kill the turn: report it as a transport failure and
      // let the loop end cleanly.
      Result := False;
      AError := UnicodeString(E.Message);
    end;
  end;
end;

procedure TAefosAgentSession._OnDelta(const AText: UnicodeString);
begin
  _Deliver(AText, False);
end;

procedure TAefosAgentSession._OnNotice(const AText: UnicodeString);
begin
  _Deliver(AText, True);
end;

function TAefosAgentSession._ToolsProvider: UnicodeString;
begin
  Result := FToolsJson;
end;

function TAefosAgentSession._ConnectMcp(out AError: UnicodeString): Boolean;
var
  LTransport: IAgentFrameTransport;
  LTools: TArray<TMcpToolDef>;
begin
  Result := False;
  AError := '';
  if not TAgentMcpPipe.Connect(FTurn.PipeName, CMcpConnectTimeoutMs,
       LTransport, AError) then
    Exit;
  FMcp := TAgentMcpClient.Create(LTransport);
  if not FMcp.Initialize(AError) then
  begin
    FreeAndNil(FMcp);
    Exit;
  end;
  if not FMcp.ListTools(LTools, AError) then
  begin
    FreeAndNil(FMcp);
    Exit;
  end;
  // MCP defs -> the Ollama /api/chat "tools" array. The same translation the CLI
  // uses, so the model sees an identical catalogue in both IDEs.
  FToolsJson := TMcpWire.OllamaToolsJson(LTools);
  Result := True;
end;

procedure TAefosAgentSession.Run;
var
  LLoop: TAgentLoop;
  LConfig: TAgentLoopConfig;
  LMessages: TArray<TOllamaMessage>;
  LResult: TAgentLoopResult;
  LMcpError: UnicodeString;
  LMcpReason: UnicodeString;
  LSupportsTools: Boolean;
  LReached: Boolean;
  LError: UnicodeString;
begin
  LError := '';
  try
    try
      // Under FLock: the class invariant is that FLock guards FTransport, and a
      // main-thread Cancel can race this first assignment (the user closes the
      // window a moment after Send). Without the lock, Cancel's guarded
      // Assigned(FTransport) could read the pre-assignment nil and skip the
      // transport's early cancel.
      FLock.Enter;
      try
        FTransport := NewOllamaTransport;
      finally
        FLock.Leave;
      end;

      // 1) Tools. A failure here DEGRADES to a plain turn with an honest notice
      //    -- it never fakes an agent that cannot act.
      if not _ConnectMcp(LMcpError) then
      begin
        FToolsJson := '';
        // Carry the host's OWN reason when it has one. "not reachable" alone is
        // true and useless: the usual cause is another IDE holding the fixed pipe
        // name, and the user has no way to guess that from here.
        LMcpReason := TAefosLazAgentGate.McpUnavailableReason;
        if LMcpReason <> '' then
          _OnNotice(CNoticeNoMcp + ' ' + LMcpReason)
        else
          _OnNotice(CNoticeNoMcp);
      end
      else
      begin
        // 2) Capability. A model without 'tools' silently ignores the catalogue
        //    and answers as a chat -- say so, rather than let the user believe
        //    Agent mode is working.
        LSupportsTools := TAefosLazAgentGate.ModelSupportsTools(FTurn.BaseUrl,
          FTurn.Model, LReached);
        if LReached and (not LSupportsTools) then
        begin
          FToolsJson := '';
          _OnNotice(CNoticeNoTools);
        end
        else if not LReached then
          // Optimistic, like AefosAgent.dpr: a blip must not strip tools from a
          // capable model -- but the user is told we could not confirm.
          _OnNotice(CNoticeProbeBlind);
      end;

      if _Cancelled then
        Exit;

      // 3) The turn. The preamble leads ONLY when tools are actually on the
      //    table: promising IDE tools to a tool-less hop would be a lie.
      if FToolsJson <> '' then
        LMessages := [TOllamaMessage.New('user',
          TAefosCliHarness.AgentPreamble(TAefosCliHarness.LazarusVocabulary)
            + FTurn.Prompt)]
      else
        LMessages := [TOllamaMessage.New('user', FTurn.Prompt)];

      LConfig.Model := FTurn.Model;
      LConfig.ToolsJson := FToolsJson;
      LConfig.MaxIterations := 0;         // loop default (CDefaultMaxIterations)
      LConfig.ToolsJsonProvider := _ToolsProvider;
      LConfig.CtxWindow := 0;             // compaction off in this slice
      LConfig.KeepTailCount := 0;

      LLoop := TAgentLoop.Create(_StreamProc, _ToolExec, _OnDelta, _OnNotice,
        @FCancelled);
      try
        LResult := LLoop.Run(LMessages, LConfig);
        // A cancel is a normal end, not an error: the user asked to stop.
        if (not LResult.Ok) and (not _Cancelled) then
          LError := LResult.Error;
      finally
        LLoop.Free;
      end;
    except
      on E: Exception do
        // The loop promises never to raise; this is the backstop, so a turn always
        // settles the composer instead of stranding it on "working...".
        LError := UnicodeString(E.Message);
    end;
  finally
    // ALWAYS exactly one terminal: cancel, crash or success. The composer must
    // come back, and the teardown drain waits on the FEnded this sets.
    _DeliverDone(LError);
  end;
end;

{ TAefosLazAgentGate }

class procedure TAefosLazAgentGate.InstallMcpHostProvider(
  const AProvider: IAefosAgentMcpHostProvider);
begin
  GMcpHostProvider := AProvider;
end;

class function TAefosLazAgentGate.EnsureMcpHost(
  out APipeName: UnicodeString): Boolean;
begin
  APipeName := '';
  Result := False;
  // No provider = not running inside the IDE package (e.g. the standalone
  // runtime proof). Honest "no": the caller degrades with a notice.
  if GMcpHostProvider = nil then
    Exit;
  try
    Result := GMcpHostProvider.EnsureStarted(APipeName);
    if Result and (APipeName = '') then
      // A provider that claims success without a pipe is unusable -- treat it as
      // unavailable rather than let the loop dial an empty name.
      Result := False;
  except
    Result := False;
  end;
end;

class function TAefosLazAgentGate.McpUnavailableReason: UnicodeString;
begin
  Result := '';
  if GMcpHostProvider = nil then
    Exit;
  try
    Result := GMcpHostProvider.LastError;
  except
    Result := '';
  end;
end;

class function TAefosLazAgentGate.ModelSupportsTools(const ABaseUrl,
  AModel: UnicodeString; out AReached: Boolean): Boolean;
var
  LError: UnicodeString;
begin
  AReached := False;
  try
    Result := TAgentCapabilityProbe.ModelSupportsTools(ABaseUrl, AModel,
      AReached, LError);
  except
    // A probe must never be the thing that kills a turn.
    Result := False;
    AReached := False;
  end;
end;

class function TAefosLazAgentGate.StartTurn(const ATurn: TAefosAgentTurn;
  const ALive: IAefosAgentLiveToken;
  const AOnDelta, AOnNotice: TAefosAgentTextEvent;
  const AOnDone: TAefosAgentDoneEvent): IAefosAgentSession;
var
  LSession: TAefosAgentSession;
  LThread: TAefosAgentThread;
begin
  LSession := TAefosAgentSession.Create(ATurn, ALive, AOnDelta, AOnNotice,
    AOnDone);
  Result := LSession;   // the caller's ref; the thread takes its own below
  LThread := TAefosAgentThread.Create(LSession);
  LThread.Start;
end;

end.
