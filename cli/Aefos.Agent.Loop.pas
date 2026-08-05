unit Aefos.Agent.Loop;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Agent CLI - the agentic tool loop (pure logic, injected collaborators).

  This is the heart of local agent mode. One "turn" is:

    build /api/chat request (history + tool catalog) -> stream deltas out ->
    on tool_calls: run each tool, append role:"tool" results -> re-send ->
    repeat until the model answers with content and NO tool_calls.

  Everything the loop touches is injected so the whole thing runs headless in
  the pure suite: the chat transport (streams chunks), the tool executor
  (runs one MCP tool), and the output/notice sinks. No pipe, no HTTP, no IDE.

  Safety rails baked in:
    - iteration cap (a runaway model can't loop forever)
    - cancel check between hops (stop means stop, no extra send)
    - a tool that fails feeds its error back as the tool result, so the model
      can adapt instead of the turn dying
*)

interface

uses
  {$IFDEF FPC}
  SysUtils,
  {$ELSE}
  System.SysUtils,
  {$ENDIF}
  Aefos.Provider.Ollama.Core,
  Aefos.Agent.Compaction;

type
  // The loop's injected collaborators. On Delphi these are `reference to`
  // (a closure or a bound method binds); FPC 3.2.2 has no anonymous methods, so
  // `of object` method pointers - the CLI host passes carrier methods either
  // way. TProc/TFunc<string> likewise become of-object text-sink/provider twins.

  // Chunk callback (structurally identical to Ollama.TOllamaChunkEvent, so a
  // transport ChatStream method binds straight to it).
  {$IFDEF FPC}
  TAgentChunkEvent = procedure(const AChunk: TOllamaChunk) of object;
  {$ELSE}
  TAgentChunkEvent = reference to procedure(const AChunk: TOllamaChunk);
  {$ENDIF}

  // Streams ONE /api/chat request. The loop drives many of these per turn.
  // Mirrors IOllamaTransport.ChatStream minus the base URL (the loop host
  // binds that). Must guarantee exactly one terminal chunk, as the transport
  // does.
  {$IFDEF FPC}
  TAgentChatStreamProc = procedure(const ARequestBody: string;
    const AOnChunk: TAgentChunkEvent) of object;
  {$ELSE}
  TAgentChatStreamProc = reference to procedure(const ARequestBody: string;
    const AOnChunk: TAgentChunkEvent);
  {$ENDIF}

  // Runs one MCP tool. Returns the tool's text (success OR failure text) and
  // sets AIsError. A False return is a transport-level failure (pipe dead):
  // the loop surfaces AError and ends the turn.
  {$IFDEF FPC}
  TAgentToolExecutor = function(const AName,
    AArgumentsJson: string; out AResultText: string; out AIsError: Boolean;
    out AError: string): Boolean of object;
  {$ELSE}
  TAgentToolExecutor = reference to function(const AName,
    AArgumentsJson: string; out AResultText: string; out AIsError: Boolean;
    out AError: string): Boolean;
  {$ENDIF}

  // One-line text sink (assistant deltas / status notices) and the per-hop
  // tool-catalog provider - the of-object / reference-to twins of TProc<string>
  // and TFunc<string>.
  {$IFDEF FPC}
  TAgentTextSink = procedure(const AText: string) of object;
  TAgentToolsProvider = function: string of object;
  {$ELSE}
  TAgentTextSink = TProc<string>;
  TAgentToolsProvider = TFunc<string>;
  {$ENDIF}

  TAgentLoopConfig = record
    Model: string;
    ToolsJson: string;        // catalog offered every hop ('' = plain chat)
    MaxIterations: Integer;   // <=0 => default (25)
    // Harness P0-1: when assigned, queried at EVERY hop instead of ToolsJson -
    // so a GetToolSchema handled by the executor can expand the catalog the
    // model sees on its very next step.
    ToolsJsonProvider: TAgentToolsProvider;
    // Harness P0-3: the model's context window in tokens; <=0 disables
    // compaction. When the estimated history crosses the threshold, the old
    // middle is summarized (one extra non-streaming model call) and replaced.
    CtxWindow: Integer;
    KeepTailCount: Integer;   // <=0 => default (CDefaultKeepTail)
  end;

  TAgentLoopResult = record
    Ok: Boolean;
    FinalContent: string;     // assistant text of the terminating hop
    Iterations: Integer;      // hops actually run
    ToolCallCount: Integer;   // tools executed across the turn
    Error: string;            // set when Ok is False
    // The turn hit the iteration cap MID-WORK: the history is coherent
    // (complete hops), so the caller SHOULD persist it - a resumed turn then
    // continues where this one stopped instead of starting blind.
    BudgetExhausted: Boolean;
  end;

  // Sinks: OnDelta streams assistant text to the user as it arrives; OnNotice
  // is for one-line status ("running tool X", budget messages) - kept separate
  // so the caller can route notices to stderr and content to stdout.
  TAgentLoop = class
  private
    FStream: TAgentChatStreamProc;
    FExec: TAgentToolExecutor;
    FOnDelta: TAgentTextSink;
    FOnNotice: TAgentTextSink;
    FCancelledPtr: PInteger;
    function _Cancelled: Boolean;
    // Harness P0-3: when the history crosses the window threshold, summarize
    // the old middle with ONE extra model call (not streamed to the user) and
    // rebuild AMessages as leading-system + summary + verbatim tail. Failures
    // degrade to "no compaction" - they never kill the turn.
    procedure _CompactIfNeeded(var AMessages: TArray<TOllamaMessage>;
      const AConfig: TAgentLoopConfig);
  public
    constructor Create(const AStream: TAgentChatStreamProc;
      const AExec: TAgentToolExecutor; const AOnDelta, AOnNotice: TAgentTextSink;
      const ACancelledPtr: PInteger);
    // Runs the turn. AMessages is the full prior history + the new user
    // message; on success the assistant turn(s) are appended to it so the
    // caller can persist the session. Never raises - failures land in
    // Result.Error.
    function Run(var AMessages: TArray<TOllamaMessage>;
      const AConfig: TAgentLoopConfig): TAgentLoopResult;
  end;

const
  // 25 proved too small in live Fase E: a weak model building a UI calls ONE
  // tool per hop and got cut mid-work. 50 covers a real form build; the cap
  // remains overridable (--max-iterations / TAgentLoopConfig).
  CDefaultMaxIterations = 50;

implementation

type
  // Collects a NON-streamed summary hop's chunks (see _CompactIfNeeded). A
  // carrier with a bound OnChunk instead of a captured closure - FPC 3.2.2 has
  // no anonymous methods; single-source, the enclosing method reads the fields
  // back after the (synchronous) stream call returns.
  TCompactionSink = class
  public
    FSummary: string;
    FError: string;
    FDone: Boolean;
    procedure OnChunk(const AChunk: TOllamaChunk);
  end;

  // Drives ONE agent hop's streamed chunks (see Run): accumulates the assistant
  // text (echoing each delta to FOnDelta), the tool calls (across chunks), the
  // stream error and the terminal flag. Same carrier pattern.
  THopSink = class
  public
    FOnDelta: TAgentTextSink;
    FContent: string;
    FSawToolChunk: Boolean;
    FCalls: TArray<TOllamaToolCall>;
    FError: string;
    FDone: Boolean;
    procedure OnChunk(const AChunk: TOllamaChunk);
  end;

procedure TCompactionSink.OnChunk(const AChunk: TOllamaChunk);
begin
  if AChunk.Content <> '' then
    FSummary := FSummary + AChunk.Content;
  if AChunk.Error <> '' then
    FError := AChunk.Error;
  if AChunk.Done then
    FDone := True;
end;

procedure THopSink.OnChunk(const AChunk: TOllamaChunk);
begin
  if AChunk.Content <> '' then
  begin
    FContent := FContent + AChunk.Content;
    if Assigned(FOnDelta) then
      FOnDelta(AChunk.Content);
  end;
  // ACCUMULATE across chunks (review S2): streaming Ollama can deliver a hop's
  // tool calls over several NDJSON lines; overwriting kept only the last and
  // silently dropped the rest. Each chunk carries complete call objects (Ollama
  // args are whole objects, not OpenAI-style fragments), so appending is correct.
  if AChunk.ToolCallsJson <> '' then
  begin
    FSawToolChunk := True;
    FCalls := FCalls + OllamaParseToolCalls(AChunk.ToolCallsJson);
  end;
  if AChunk.Error <> '' then
    FError := AChunk.Error;
  if AChunk.Done then
    FDone := True;
end;

constructor TAgentLoop.Create(const AStream: TAgentChatStreamProc;
  const AExec: TAgentToolExecutor; const AOnDelta, AOnNotice: TAgentTextSink;
  const ACancelledPtr: PInteger);
begin
  inherited Create;
  FStream := AStream;
  FExec := AExec;
  FOnDelta := AOnDelta;
  FOnNotice := AOnNotice;
  FCancelledPtr := ACancelledPtr;
end;

function TAgentLoop._Cancelled: Boolean;
begin
  Result := (FCancelledPtr <> nil) and (FCancelledPtr^ <> 0);
end;

procedure TAgentLoop._CompactIfNeeded(var AMessages: TArray<TOllamaMessage>;
  const AConfig: TAgentLoopConfig);
var
  LLeading, LHead, LTail, LReq: TArray<TOllamaMessage>;
  LSummary, LRequest, LErr: string;
  LDone: Boolean;
  LSink: TCompactionSink;
begin
  if not TAgentCompaction.IsNeeded(TAgentCompaction.ApproxMessagesTokens(AMessages),
    AConfig.CtxWindow) then
    Exit;
  if not TAgentCompaction.Split(AMessages, AConfig.KeepTailCount,
    LLeading, LHead, LTail) then
    Exit;
  if Assigned(FOnNotice) then
    FOnNotice('> compacting context (history near the model window)');
  // One summary hop: same model, NO tools, and a LOCAL chunk sink - the
  // summary must not stream to the user's stdout.
  LReq := TAgentCompaction.BuildRequestMessages(LHead);
  LRequest := OllamaBuildChatRequest(AConfig.Model, LReq, True, '', -1.0, 0);
  LSink := TCompactionSink.Create;
  try
    FStream(LRequest, LSink.OnChunk);
    LSummary := LSink.FSummary;
    LErr := LSink.FError;
    LDone := LSink.FDone;
  finally
    LSink.Free;
  end;
  if (LErr <> '') or (not LDone) or (Trim(LSummary) = '') then
  begin
    if Assigned(FOnNotice) then
      FOnNotice('> compaction skipped (summary unavailable)');
    Exit;
  end;
  AMessages := LLeading + [TAgentCompaction.MakeSummaryMessage(Trim(LSummary))] + LTail;
end;

function TAgentLoop.Run(var AMessages: TArray<TOllamaMessage>;
  const AConfig: TAgentLoopConfig): TAgentLoopResult;
var
  LMax, LIter, LCallIdx: Integer;
  LRequest, LToolsJson: string;
  LHopContent, LStreamError: string;
  LDone, LSawToolChunk: Boolean;
  LHopCalls, LCalls: TArray<TOllamaToolCall>;
  LToolText, LToolError: string;
  LToolIsError: Boolean;
  LHopSink: THopSink;
begin
  Result := Default(TAgentLoopResult);
  LMax := AConfig.MaxIterations;
  if LMax <= 0 then
    LMax := CDefaultMaxIterations;

  for LIter := 1 to LMax do
  begin
    if _Cancelled then
    begin
      Result.Error := 'Cancelled.';
      Result.Iterations := LIter - 1;
      Exit;
    end;

    Result.Iterations := LIter;
    // Per-hop accumulators are (re)initialised by THopSink and read back after
    // the stream, so no manual reset is needed here.

    // Half-budget nudge (field report 2026-07-10: a weak model spent one tool
    // per hop and burned the cap mid-build): tell it to batch and converge.
    // One system line, injected exactly once per turn.
    if (LIter = (LMax div 2) + 1) and (LMax >= 8) then
    begin
      AMessages := AMessages + [TOllamaMessage.New('system',
        '[budget] Half of this turn''s tool budget is spent. Batch SEVERAL ' +
        'tool calls into each step where possible, prioritise what remains, ' +
        'and converge to a final answer.')];
      if Assigned(FOnNotice) then
        FOnNotice('> budget: half spent - nudging the model to batch');
    end;

    // Harness P0-3: shrink the history BEFORE building the request when it
    // nears the model's window (no-op when CtxWindow <= 0).
    _CompactIfNeeded(AMessages, AConfig);

    // Harness P0-1: a provider re-evaluates the catalog every hop, so a schema
    // loaded via GetToolSchema is callable on the model's very next step.
    if Assigned(AConfig.ToolsJsonProvider) then
      LToolsJson := AConfig.ToolsJsonProvider()
    else
      LToolsJson := AConfig.ToolsJson;

    LRequest := OllamaBuildChatRequest(AConfig.Model, AMessages, True,
      LToolsJson, -1.0, 0);

    // The hop's chunk accumulation runs on a carrier (see THopSink) rather than
    // a captured closure; read the results back after the synchronous stream.
    LHopSink := THopSink.Create;
    try
      LHopSink.FOnDelta := FOnDelta;
      FStream(LRequest, LHopSink.OnChunk);
      LHopContent := LHopSink.FContent;
      LHopCalls := LHopSink.FCalls;
      LSawToolChunk := LHopSink.FSawToolChunk;
      LStreamError := LHopSink.FError;
      LDone := LHopSink.FDone;
    finally
      LHopSink.Free;
    end;

    if LStreamError <> '' then
    begin
      Result.Error := LStreamError;
      Exit;
    end;
    if not LDone then
    begin
      Result.Error := 'The model stream ended without a terminal marker.';
      Exit;
    end;

    // No parsed tool calls. If the model sent NO tool_calls chunk at all, it
    // answered -> record and stop. If it DID send tool_calls but every entry
    // was unparseable, don't silently swallow it -> surface the diagnostic
    // (spot-check nit, 2026-07-09) rather than treat garbage as a final answer.
    if Length(LHopCalls) = 0 then
    begin
      if LSawToolChunk then
      begin
        Result.Error := 'The model requested tools in an unreadable form.';
        Exit;
      end;
      AMessages := AMessages + [TOllamaMessage.New('assistant', LHopContent)];
      Result.Ok := True;
      Result.FinalContent := LHopContent;
      Exit;
    end;

    // Tool calls: record the assistant's request (with its tool_calls, for
    // replay fidelity), then execute each and append its result. The tool_calls
    // are re-serialized from the accumulated set so a multi-chunk hop replays
    // faithfully.
    LCalls := LHopCalls;
    AMessages := AMessages +
      [TOllamaMessage.NewAssistantToolCalls(LHopContent,
        OllamaSerializeToolCalls(LCalls))];

    for LCallIdx := 0 to High(LCalls) do
    begin
      if _Cancelled then
      begin
        Result.Error := 'Cancelled.';
        Exit;
      end;
      if Assigned(FOnNotice) then
        FOnNotice('> tool: ' + LCalls[LCallIdx].Name);
      if not FExec(LCalls[LCallIdx].Name, LCalls[LCallIdx].ArgumentsJson,
        LToolText, LToolIsError, LToolError) then
      begin
        // Transport-level failure (pipe dead): can't continue the turn.
        Result.Error := LToolError;
        Exit;
      end;
      Inc(Result.ToolCallCount);
      // Success OR tool-reported error both go back as the tool result - the
      // model reads the error text and adapts on the next hop.
      if LToolIsError and (LToolText = '') then
        LToolText := 'The tool reported an error.';
      AMessages := AMessages +
        [TOllamaMessage.NewToolResult(LCalls[LCallIdx].Name, LToolText)];
    end;
    // loop: re-send with the tool results appended
  end;

  // Fell out of the loop = hit the iteration cap. The history is coherent
  // (whole hops), so the caller should persist it for a resumed continuation.
  Result.BudgetExhausted := True;
  Result.Error := Format('Tool budget exhausted after %d iterations.', [LMax]);
end;

end.
