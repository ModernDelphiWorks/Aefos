program AefosAgent;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{$APPTYPE CONSOLE}

{
  Aefos Agent CLI - the agent shell for local models (Ollama endpoints).

  Phase A: chat parity. One streamed /api/chat turn per invocation, with a
  file-backed session (--resume) for multi-turn history - dispatched by the
  Aefos chat exactly like any CLI executor, and equally usable standalone in
  a terminal. The tool loop (MCP over the named pipe) arrives in Phases B/C.

  Output contract (the chat's dispatcher reads stdout):
    stdout = the model's text, streamed as it arrives. Nothing else.
    stderr = session id line + diagnostics.
    exit 0 = turn completed; 1 = runtime/stream error; 2 = usage error.
}

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  Windows,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  {$ENDIF}
  // Resolved via the unit search path (-U): source\providers for the Ollama
  // core+transport, cli\ for the CLI's own units (see scripts\build-agent-cli.ps1).
  Aefos.Provider.Ollama.Core,
  Aefos.Provider.Ollama,
  Aefos.Agent.Args,
  Aefos.Agent.Session,
  Aefos.Agent.MCP.Core,
  Aefos.Agent.MCP.Pipe,
  Aefos.Agent.Capability,
  Aefos.Agent.Catalog,
  Aefos.Agent.Orientation,
  Aefos.Agent.Attachments,
  Aefos.Agent.Loop;

const
  CAgentVersion = '0.1.0';
  // Generous turn watchdog: big local models can think for minutes; the IDE
  // side has its own configurable Run timeout on top of this.
  CTurnWaitMs = 15 * 60 * 1000;

var
  GArgs: TAgentArgs;
  GArgv: TArray<string>;
  GTransport: IOllamaTransport;
  GMessages: TArray<TOllamaMessage>;
  GSessionsRoot: string;
  GLoadError: string;
  GWaitMs: Cardinal;
  GPipeTransport: IAgentFrameTransport;
  GMcp: TAgentMcpClient;
  GTools: TArray<TMcpToolDef>;
  GMcpError: string;
  GToolsJson: string;
  GHasTools, GProbeReached: Boolean;
  GStreamProc: TAgentChatStreamProc;
  GToolExec: TAgentToolExecutor;
  GDelta: TAgentTextSink;   // assistant text -> stdout
  GNotice: TAgentTextSink;  // status/notice   -> stderr
  GLoop: TAgentLoop;
  GLoopCfg: TAgentLoopConfig;
  GLoopResult: TAgentLoopResult;
  GCancelled: Integer;
  GTurnStart: Cardinal;
  GTurnTimedOut: Boolean;
  // Harness P0-1/2/3 state: compact-catalog mode + the schemas expanded so
  // far, the context window driving compaction, and the orientation probes.
  GCompact: Boolean;
  GExpanded: TArray<string>;
  GCtx: Integer;
  GOrientLine, GOrientProj, GOrientFile, GOrientDebug, GOrientBranch: string;
  // Vision attachments: image paths from the prompt's attach block, loaded as
  // base64 onto the user message when the model advertises 'vision'.
  GAttachPaths: TArray<string>;
  GUserMsg: TOllamaMessage;
  GB64: string;
  LIndex: Integer;

// True when the history already carries a system message opening with AMarker
// (a resumed session must not get a second catalog preamble).
function HasSystemMarker(const AMessages: TArray<TOllamaMessage>;
  const AMarker: string): Boolean;
var
  LFor: Integer;
begin
  Result := False;
  for LFor := 0 to High(AMessages) do
    if SameText(AMessages[LFor].Role, 'system') and
      (Pos(AMarker, AMessages[LFor].Content) = 1) then
      Exit(True);
end;

// One orientation probe: a cheap read-only tool call whose JSON text feeds
// TAgentOrientation.BuildLine; any failure yields '' (the line just omits it).
function OrientProbe(const AMcp: TAgentMcpClient; const ATool: string): string;
var
  LText, LErr: string;
  LIsErr: Boolean;
begin
  Result := '';
  if AMcp = nil then
    Exit;
  if AMcp.CallTool(ATool, '{}', LText, LIsErr, LErr) and (not LIsErr) then
    Result := LText;
end;

procedure PrintUsage;
begin
  Writeln('Aefos Agent CLI ', CAgentVersion,
    ' - agent shell for local models (Ollama endpoints)');
  Writeln('');
  Writeln('Usage: AefosAgent "<prompt>" --model <id> [options]');
  Writeln('');
  Writeln('Options:');
  Writeln('  -m, --model <id>            model to run (required)');
  Writeln('  --endpoint <url>            Ollama base URL (default http://localhost:11434)');
  Writeln('  --resume <session-id>       continue an existing conversation');
  Writeln('  --mcp-pipe <name>           aefos MCP named pipe (default aefos-mcp-terminal)');
  Writeln('  --mcp-probe                 connect to the MCP, count tools and exit');
  Writeln('  --permission-mode <mode>    ask | auto-edits | auto-all (agent mode)');
  Writeln('  --turn-timeout <seconds>    give up on the turn after this long (default 900)');
  Writeln('  --sessions-root <dir>       session store location (default %APPDATA%\Aefos\sessions)');
  Writeln('  --tool-catalog <mode>       auto | full | compact (schema-on-demand; default auto)');
  Writeln('  --no-orientation            skip the IDE environment snapshot');
  Writeln('  --ctx <tokens>              context window for compaction (default: probe /api/show)');
  Writeln('  --max-iterations <n>        tool-loop hop budget (default 50)');
  Writeln('  -p, --print                 non-interactive single turn (default)');
  Writeln('  -h, --help                  this help');
  Writeln('  -v, --version               version');
end;

// Pumps the transport's main-thread queue (the console stand-in for a message
// loop) until AFlag turns True or the timeout expires.
function PumpUntil(var AFlag: Boolean; const ATimeoutMs: Cardinal): Boolean;
var
  LStart: Cardinal;
begin
  LStart := TThread.GetTickCount;
  while (not AFlag) and (TThread.GetTickCount - LStart < ATimeoutMs) do
    CheckSynchronize(50);
  Result := AFlag;
end;

// Ctrl+C / Ctrl+Break / console-close: request a GRACEFUL stop instead of the
// Windows default hard-kill (review: the loop's cancel rail was dead code).
// Returning True suppresses default termination for the interactive signals so
// the loop can unwind on its next _Cancelled check. Runs on a Windows-injected
// thread; the plain Integer write is atomic enough for a stop flag.
function ConsoleCtrlHandler(ACtrlType: DWORD): BOOL; stdcall;
begin
  case ACtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT:
      begin
        GCancelled := 1;
        Result := True;
      end;
  else
    Result := False;
  end;
end;

{$IFDEF FPC}
// FPC 3.2.2 has no anonymous methods, so the five sinks this program passes to
// the transport and the loop become bound methods on carriers (Delphi keeps the
// original closures in the {$ELSE} branches below). The carriers read the
// program globals directly - they are in scope here - so no captured state is
// needed beyond the per-stream relay's terminal flag.
type
  // Per-StreamProc-call relay: forwards each chunk to the loop's AOnChunk and
  // records the terminal so PumpUntil can stop. Replaces the nested closure.
  TStreamRelay = class
  public
    FOnChunk: TAgentChunkEvent;
    FLocalDone: Boolean;
    procedure Relay(const AChunk: TOllamaChunk);
  end;

  // Carrier for the four program-level sinks (stream/exec/delta/notice) plus the
  // per-hop tools provider. Signatures match the loop's callback types exactly.
  TAgentRunner = class
  public
    procedure StreamProc(const ARequestBody: string;
      const AOnChunk: TAgentChunkEvent);
    function ToolExec(const AName, AArgumentsJson: string;
      out AResultText: string; out AIsError: Boolean;
      out AError: string): Boolean;
    procedure Delta(const AText: string);
    procedure Notice(const AText: string);
    function ToolsProvider: string;
  end;

procedure TStreamRelay.Relay(const AChunk: TOllamaChunk);
begin
  FOnChunk(AChunk);
  if AChunk.Done then
    FLocalDone := True;
end;

// One /api/chat request, streamed, pumped to completion (see the {$ELSE} body).
procedure TAgentRunner.StreamProc(const ARequestBody: string;
  const AOnChunk: TAgentChunkEvent);
var
  LElapsed, LRemaining: Cardinal;
  LRelay: TStreamRelay;
begin
  // GWaitMs is the WHOLE-TURN budget: each hop gets only the time remaining.
  LElapsed := GetTickCount - GTurnStart;
  if LElapsed >= GWaitMs then
  begin
    GTurnTimedOut := True;
    Exit;
  end;
  LRemaining := GWaitMs - LElapsed;
  LRelay := TStreamRelay.Create;
  try
    LRelay.FOnChunk := AOnChunk;
    LRelay.FLocalDone := False;
    GTransport.ChatStream(GArgs.Endpoint, ARequestBody, LRelay.Relay);
    if not PumpUntil(LRelay.FLocalDone, LRemaining) then
      GTurnTimedOut := True;
  finally
    LRelay.Free;
  end;
end;

function TAgentRunner.ToolExec(const AName, AArgumentsJson: string;
  out AResultText: string; out AIsError: Boolean; out AError: string): Boolean;
begin
  if GCompact and SameText(AName, CGetToolSchemaName) then
  begin
    AIsError := TAgentCatalog.HandleGetToolSchema(GTools, AArgumentsJson,
      GExpanded, AResultText);
    AError := '';
    Result := True;
  end
  else
    Result := GMcp.CallTool(AName, AArgumentsJson, AResultText, AIsError, AError);
end;

procedure TAgentRunner.Delta(const AText: string);
begin
  Write(AText);
  Flush(Output);
end;

procedure TAgentRunner.Notice(const AText: string);
begin
  Writeln(ErrOutput, AText);
end;

function TAgentRunner.ToolsProvider: string;
begin
  if GToolsJson = '' then
    Result := ''
  else if GCompact then
    Result := TAgentCatalog.BuildCompactToolsJson(GTools, GExpanded)
  else
    Result := GToolsJson;
end;

var
  GRunner: TAgentRunner;
{$ENDIF}

begin
  try
    // The chat captures stdout as UTF-8 (every CLI executor speaks it).
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
    SetTextCodePage(Output, CP_UTF8);
    SetTextCodePage(ErrOutput, CP_UTF8);

    SetLength(GArgv, ParamCount);
    for LIndex := 1 to ParamCount do
      GArgv[LIndex - 1] := ParamStr(LIndex);
    GArgs := TAgentArgs.Parse(GArgv);

    if GArgs.ShowHelp then
    begin
      PrintUsage;
      Halt(0);
    end;
    if GArgs.ShowVersion then
    begin
      Writeln('AefosAgent ', CAgentVersion);
      Halt(0);
    end;
    if GArgs.Error <> '' then
    begin
      Writeln(ErrOutput, 'error: ', GArgs.Error);
      Halt(2);
    end;
    // MCP probe: prove the pipe + handshake + catalog, then leave. This is
    // the standalone truth test for agent-mode plumbing (and the E2E hook).
    if GArgs.McpProbe then
    begin
      if GArgs.McpPipe = '' then
        GArgs.McpPipe := 'aefos-mcp-terminal';
      if not TAgentMcpPipe.Connect(GArgs.McpPipe, 5000, GPipeTransport, GMcpError) then
      begin
        Writeln(ErrOutput, 'error: ', GMcpError);
        Halt(1);
      end;
      GMcp := TAgentMcpClient.Create(GPipeTransport);
      try
        if not GMcp.Initialize(GMcpError) then
        begin
          Writeln(ErrOutput, 'error: ', GMcpError);
          Halt(1);
        end;
        if not GMcp.ListTools(GTools, GMcpError) then
        begin
          Writeln(ErrOutput, 'error: ', GMcpError);
          Halt(1);
        end;
        if GMcp.ServerName <> '' then
          Writeln('aefos MCP: ', Length(GTools), ' tools (', GMcp.ServerName, ')')
        else
          Writeln('aefos MCP: ', Length(GTools), ' tools');
      finally
        GMcp.Free;
      end;
      Halt(0);
    end;

    if GArgs.Model = '' then
    begin
      Writeln(ErrOutput, 'error: no model specified. Pass --model <id>.');
      Halt(2);
    end;
    if GArgs.Prompt = '' then
    begin
      Writeln(ErrOutput, 'error: no prompt given. Pass it as the first argument.');
      Halt(2);
    end;

    // Session: resume loads the prior history; otherwise a fresh id.
    if GArgs.SessionsRoot <> '' then
      GSessionsRoot := GArgs.SessionsRoot
    else
      GSessionsRoot := TAgentSession.DefaultRoot;
    if GArgs.SessionId <> '' then
    begin
      if not TAgentSession.LoadMessages(GSessionsRoot, GArgs.SessionId,
        GMessages, GLoadError) then
      begin
        Writeln(ErrOutput, 'error: ', GLoadError);
        Halt(2);
      end;
    end
    else
      GArgs.SessionId := TAgentSession.NewId;
    // The id goes to stderr so resuming callers can pick it up without
    // polluting the model's stdout text.
    Writeln(ErrOutput, 'session: ', GArgs.SessionId);

    // The user message is appended AFTER the MCP block below, so the catalog
    // preamble and the orientation snapshot (harness P0-1/P0-2) can precede it.
    if GArgs.TurnTimeoutSec > 0 then
      GWaitMs := Cardinal(GArgs.TurnTimeoutSec) * 1000
    else
      GWaitMs := CTurnWaitMs;

    // Agent mode: --mcp-pipe wires the tool loop. Connect the MCP, list the
    // catalog and gate on the model's capabilities; without a pipe (or a
    // tool-less model) the same loop runs with an empty catalog == plain chat.
    GToolsJson := '';
    GMcp := nil;
    if GArgs.McpPipe <> '' then
    begin
      if not TAgentMcpPipe.Connect(GArgs.McpPipe, 5000, GPipeTransport, GMcpError) then
      begin
        Writeln(ErrOutput, 'error: ', GMcpError);
        Halt(1);
      end;
      GMcp := TAgentMcpClient.Create(GPipeTransport);
      if not GMcp.Initialize(GMcpError) then
      begin
        Writeln(ErrOutput, 'error: ', GMcpError);
        Halt(1);
      end;
      if not GMcp.ListTools(GTools, GMcpError) then
      begin
        Writeln(ErrOutput, 'error: ', GMcpError);
        Halt(1);
      end;
      // Capability gate: offer tools when the model advertises them OR when
      // the probe could not reach /api/show (optimistic - the endpoint sorts
      // it out); degrade to chat with a note ONLY on a definite "no tools".
      GHasTools := TAgentCapabilityProbe.ModelSupportsTools(GArgs.Endpoint,
        GArgs.Model, GProbeReached, GMcpError);
      if GHasTools then
        GToolsJson := TMcpWire.OllamaToolsJson(GTools)
      else if not GProbeReached then
      begin
        // Probe unreachable: offer tools optimistically (don't silently
        // downgrade a capable model on a transient blip) but SAY so - the
        // previous silent discard of the probe error was undiagnosable (L3c).
        GToolsJson := TMcpWire.OllamaToolsJson(GTools);
        if GMcpError <> '' then
          Writeln(ErrOutput, 'note: capability probe unreachable (', GMcpError,
            ') - offering tools optimistically.');
      end
      else
        Writeln(ErrOutput, 'note: model "', GArgs.Model,
          '" does not advertise tool support - running as chat.');

      // Harness P0-2: gather the environment snapshot with cheap read-only
      // calls (each degrades to omission on failure).
      if not GArgs.NoOrientation then
      begin
        GOrientProj := OrientProbe(GMcp, 'GetActiveProject');
        GOrientFile := OrientProbe(GMcp, 'GetEditorActiveFile');
        GOrientDebug := OrientProbe(GMcp, 'GetDebugState');
        GOrientBranch := OrientProbe(GMcp, 'GetGitCurrentBranch');
        GOrientLine := TAgentOrientation.BuildLine(GOrientProj, GOrientFile,
          GOrientDebug, GOrientBranch);
      end;
    end;

    // Harness P0-1: compact catalog when forced, or automatically for a large
    // one. GToolsJson non-empty = tools are on offer this turn.
    GCompact := (GToolsJson <> '') and
      ((GArgs.CatalogMode = cmCompact) or
       ((GArgs.CatalogMode = cmAuto) and
        (Length(GTools) > CCompactAutoThreshold)));
    if GCompact and
      (not HasSystemMarker(GMessages, TAgentCatalog.PreambleMarker)) then
      GMessages := GMessages +
        [TOllamaMessage.New('system', TAgentCatalog.BuildPreamble(GTools))];
    if GOrientLine <> '' then
      GMessages := GMessages + [TOllamaMessage.New('system', GOrientLine)];
    // Vision "eyes": the chat attaches files as paths in the prompt text - a
    // text-only model can't use them (Fase E showed one confabulating the
    // content). When the model advertises 'vision', load each image and ride
    // it on the user message's images member; otherwise say so honestly.
    GUserMsg := TOllamaMessage.New('user', GArgs.Prompt);
    GAttachPaths := TAgentAttachments.ExtractImagePaths(GArgs.Prompt);
    if Length(GAttachPaths) > 0 then
    begin
      if TAgentCapabilityProbe.ModelSupportsVision(GArgs.Endpoint, GArgs.Model) then
      begin
        for LIndex := 0 to High(GAttachPaths) do
          if TAgentAttachments.LoadImageBase64(GAttachPaths[LIndex], GB64) then
            GUserMsg.Images := GUserMsg.Images + [GB64]
          else
            Writeln(ErrOutput, 'note: attachment unreadable, skipped: ',
              GAttachPaths[LIndex]);
        if Length(GUserMsg.Images) > 0 then
          Writeln(ErrOutput, 'note: ', Length(GUserMsg.Images),
            ' image attachment(s) forwarded to the vision model.');
      end
      else
        Writeln(ErrOutput, 'note: model "', GArgs.Model,
          '" has no vision capability - image attachment(s) ignored.');
    end;
    GMessages := GMessages + [GUserMsg];

    // Harness P0-3: the compaction window - explicit --ctx wins; otherwise the
    // /api/show probe (0 = unknown = compaction off).
    if GArgs.CtxTokens > 0 then
      GCtx := GArgs.CtxTokens
    else
      GCtx := TAgentCapabilityProbe.ProbeContextWindow(GArgs.Endpoint, GArgs.Model);

    GTransport := NewOllamaTransport;
    // FStream: one /api/chat request, streamed, pumped to completion. The loop
    // calls this once per hop. FExec runs one MCP tool (only reached when a
    // catalog was offered, so GMcp is non-nil there); in compact mode the
    // GetToolSchema meta-tool is answered LOCALLY from the cached catalog.
    // On FPC these five sinks are carrier methods (see TAgentRunner); Delphi
    // keeps the original closures below.
    {$IFDEF FPC}
    GRunner := TAgentRunner.Create;
    GStreamProc := GRunner.StreamProc;
    GToolExec := GRunner.ToolExec;
    GDelta := GRunner.Delta;
    GNotice := GRunner.Notice;
    {$ELSE}
    GStreamProc :=
      procedure(const ARequestBody: string; const AOnChunk: TAgentChunkEvent)
      var
        LLocalDone: Boolean;
        LElapsed, LRemaining: Cardinal;
      begin
        // GWaitMs is the WHOLE-TURN budget (review S4): each hop gets only the
        // time remaining, so a 25-hop tool loop can't run 25x the advertised
        // timeout. Out of budget => skip the hop; the loop ends on the missing
        // terminal and the post-loop check reports the timeout.
        LElapsed := GetTickCount - GTurnStart;
        if LElapsed >= GWaitMs then
        begin
          GTurnTimedOut := True;
          Exit;
        end;
        LRemaining := GWaitMs - LElapsed;
        LLocalDone := False;
        GTransport.ChatStream(GArgs.Endpoint, ARequestBody,
          procedure(const AChunk: TOllamaChunk)
          begin
            AOnChunk(AChunk);
            if AChunk.Done then
              LLocalDone := True;
          end);
        if not PumpUntil(LLocalDone, LRemaining) then
          GTurnTimedOut := True;
      end;
    GToolExec :=
      function(const AName, AArgumentsJson: string; out AResultText: string;
        out AIsError: Boolean; out AError: string): Boolean
      begin
        if GCompact and SameText(AName, CGetToolSchemaName) then
        begin
          AIsError := TAgentCatalog.HandleGetToolSchema(GTools, AArgumentsJson,
            GExpanded, AResultText);
          AError := '';
          Result := True;
        end
        else
          Result := GMcp.CallTool(AName, AArgumentsJson, AResultText, AIsError,
            AError);
      end;
    GDelta := procedure(S: string) begin Write(S); Flush(Output); end;
    GNotice := procedure(S: string) begin Writeln(ErrOutput, S); end;
    {$ENDIF}

    GLoop := TAgentLoop.Create(GStreamProc, GToolExec, GDelta, GNotice,
      @GCancelled);
    try
      GLoopCfg := Default(TAgentLoopConfig);
      GLoopCfg.Model := GArgs.Model;
      GLoopCfg.ToolsJson := GToolsJson;
      GLoopCfg.MaxIterations := GArgs.MaxIterations; // 0 = loop default
      // P0-1: re-evaluated every hop so GetToolSchema loads land immediately.
      {$IFDEF FPC}
      GLoopCfg.ToolsJsonProvider := GRunner.ToolsProvider;
      {$ELSE}
      GLoopCfg.ToolsJsonProvider :=
        function: string
        begin
          if GToolsJson = '' then
            Result := ''
          else if GCompact then
            Result := TAgentCatalog.BuildCompactToolsJson(GTools, GExpanded)
          else
            Result := GToolsJson;
        end;
      {$ENDIF}
      // P0-3: compaction window (0 = off).
      GLoopCfg.CtxWindow := GCtx;
      GLoopCfg.KeepTailCount := 0; // default tail
      GTurnStart := GetTickCount;
      GTurnTimedOut := False;
      GLoopResult := GLoop.Run(GMessages, GLoopCfg);
    finally
      GLoop.Free;
      {$IFDEF FPC}
      GRunner.Free; // after the loop that held its bound sinks
      {$ENDIF}
      GMcp.Free; // nil-safe
      GPipeTransport := nil;
    end;

    if not GLoopResult.Ok then
    begin
      Writeln(ErrOutput, '');
      if GTurnTimedOut then
        Writeln(ErrOutput, 'error: the turn exceeded its ',
          GWaitMs div 1000, 's time budget.')
      else
        Writeln(ErrOutput, 'error: ', GLoopResult.Error);
      // Budget exhaustion is NOT a broken turn: every hop completed, so the
      // history is coherent. Persist it so the NEXT prompt (the chat resumes
      // this session automatically) continues where this one stopped instead
      // of starting blind - the live 25-hop UI build lost all its context.
      if GLoopResult.BudgetExhausted then
      begin
        TAgentSession.SaveMessages(GSessionsRoot, GArgs.SessionId, GMessages);
        Writeln(ErrOutput, 'note: progress saved to session ', GArgs.SessionId,
          ' - send a follow-up prompt to continue from here.');
      end;
      Halt(1);
    end;

    // The loop appended the assistant (and any tool) turns to GMessages;
    // persist so --resume carries the whole thread on. (No trailing stdout
    // newline: stdout carries ONLY the model's text - review S7.)
    TAgentSession.SaveMessages(GSessionsRoot, GArgs.SessionId, GMessages);
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'error: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
