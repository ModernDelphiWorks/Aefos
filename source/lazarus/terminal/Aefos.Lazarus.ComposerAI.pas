unit Aefos.Lazarus.ComposerAI;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

{
  ONE-SHOT natural-language -> shell-command helper for the Lazarus terminal
  composer bar (Aefos -> Lazarus, terminal AI slice).

  The terminal composer lets the user type a natural-language request; this unit
  turns it into a SINGLE runnable cmd.exe command line and hands it back through a
  callback (the control then INSERTS it at the terminal input line for review --
  it never auto-runs). It is deliberately a ONE-SHOT: no history, no attach, no
  memory, no multi-turn -- a single request in, a single command out.

  IT REUSES THE SHARED CHAT SEAMS, it does NOT reimplement dispatch:
    * ekOllama (local model): drives the FPC-ready Ollama transport directly
      (NewOllamaTransport.ChatStream), the same special-case the chat controller
      uses for the local provider, and accumulates the streamed content.
    * every other provider (Codex/Claude/Gemini/Copilot): assembles the driver's
      per-CLI invocation through TAefosCliHarness.BuildDispatchRequest (so the
      subcommand / model / api-key env / timeout / output-filter are exactly what
      the chat sends) and spawns it through the SHARED Aefos.OTA.Chat.Core.
      CLIDispatcher, accumulating stdout to its single Complete event.
    * the PROMPT is NOT the chat's aefos-first agent preamble -- the composer
      supplies its OWN tight shell-command-generator framing (BuildPrompt) and
      passes it straight to BuildDispatchRequest as the request body (agent tools
      / MCP are deliberately OFF: this is a plain completion).

  The provider + model are read from the SAME %APPDATA%\Aefos\.aefos\config.json
  and models.json the chat and Options use (one brain across both IDEs).

  LIFETIME: a plain object owned by the terminal control (not refcounted). All
  transport callbacks marshal to the MAIN thread (Ollama via Synchronize, the CLI
  dispatcher via TThread.Queue) so the result callback is main-thread safe. The
  transport stores bare `of object` sinks and never refcounts them, so this unit
  mirrors the chat controller's discipline: a self-holding sink + a liveness token
  killed in Destroy, so a chunk marshalled back after the owner is freed is a safe
  no-op rather than a use-after-free. Cancel/teardown aborts any in-flight run so
  no spawned child outlives the control.

  All literals are ASCII: this file needs no BOM.
}

interface

uses
  Classes,
  SysUtils,
  Generics.Collections,   // TPair (TDispatchRequest.EnvOverrides items)
  LazUTF8,
  Aefos.Provider.Types,
  Aefos.Provider.Ollama.Core,
  Aefos.Provider.Ollama,
  Aefos.Chat.Core.CliHarness,
  Aefos.OTA.Chat.Core.Dispatcher.Types,
  Aefos.OTA.Chat.Core.CLIDispatcher,
  Aefos.OTA.Chat.Core.Config.Types;

type
  // Fired (main thread) with the single sanitized command line ready to insert.
  TAefosComposerResult = procedure(const ACommand: string) of object;
  // Fired (main thread) with a human-readable reason when the round-trip failed
  // (no provider configured, dispatch error, empty reply, ...).
  TAefosComposerError = procedure(const AMessage: string) of object;

  { Trivial liveness token. Local to this unit so the composer does not depend on
    the WebView host: killed at the top of Destroy so a late marshalled chunk
    becomes a no-op instead of touching a freed owner. }
  IAefosComposerLive = interface
    ['{2E7B1D4A-9C33-4F81-B6A0-5D2C8E31F740}']
    function IsAlive: Boolean;
  end;

  TAefosLazComposerAI = class
  private
    FLive: IAefosComposerLive;
    FLiveObj: TObject;                  // raw view of the token, for Kill in Destroy
    FTransport: IOllamaTransport;       // the in-flight Ollama stream (ekOllama)
    FCliDispatcher: ICLIDispatcher;
    FCliRun: IDispatcherRunHandle;      // the in-flight CLI run (external provider)
    FSinkHold: IInterface;              // keeps the current turn's sink alive
    FOnResult: TAefosComposerResult;
    FOnError: TAefosComposerError;
    FInFlight: Boolean;
    // Config-root resolver method (TConfigRootResolver = function: UnicodeString
    // of object): returns the SHARED %APPDATA%\Aefos root, the same file the chat
    // controller and Options read. Declared UnicodeString to bind the delphiunicode
    // core seam unambiguously (this unit is delphi-mode = UTF-8 AnsiString).
    function _ConfigRoot: UnicodeString;
    function _LoadConfig: TConfig;
    function _ResolveModel(const AConfig: TConfig): UnicodeString;
    procedure _DispatchOllama(const APrompt: string; const AConfig: TConfig);
    procedure _DispatchCli(const APrompt: string; const AConfig: TConfig);
    // The single settle point for both dispatch shapes: sanitizes ATextRaw and
    // fires OnResult, or fires OnError. AIsError short-circuits to OnError. A
    // no-op once the turn already settled or was cancelled (FInFlight gate).
    procedure _Settle(const ATextRaw, AErrorMessage: string;
      const AIsError: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    { Kicks off the round-trip for AUserText: frames the shell-command-generator
      prompt, reads the configured provider/model, and dispatches. Exactly one of
      AOnResult / AOnError fires later on the main thread. Any previous in-flight
      run is cancelled first (the composer is a single-shot). }
    procedure Ask(const AUserText: string; const AOnResult: TAefosComposerResult;
      const AOnError: TAefosComposerError);
    { Aborts an in-flight run (idempotent no-op when idle). Neither callback fires
      for a cancelled run. }
    procedure Cancel;
    { True while a round-trip is in flight (the bar shows its thinking state). }
    property InFlight: Boolean read FInFlight;
    { The shell-command-generator framing: wraps AUserText so the model returns
      ONLY a runnable cmd.exe command line. Exposed for tests. }
    class function BuildPrompt(const AUserText: string): string; static;
    { Reduces a model reply to a single command line: strips markdown fences /
      backticks / a leading prompt sigil / surrounding whitespace and takes the
      first non-empty command line. Exposed for tests. }
    class function Sanitize(const AResponse: string): string; static;
  end;

implementation

uses
  Aefos.Provider.Registry,
  Aefos.OTA.Chat.Core.Config,           // TConfigService / TConfigRootResolver
  Aefos.OTA.Chat.Core.CLIBinaryResolver, // ResolveCLIBinary
  Aefos.Executor.Models;                // TExecutorModelStore

type
  { Concrete liveness token (see IAefosComposerLive). }
  TAefosComposerLiveToken = class(TInterfacedObject, IAefosComposerLive)
  private
    FAlive: Boolean;
  public
    constructor Create;
    function IsAlive: Boolean;
    procedure Kill;
  end;

  { The IAefosCliHarnessInputs the composer feeds BuildDispatchRequest. Minimal
    and NON-agentic: agent tooling / MCP are OFF (this is a plain completion), no
    OTA context, no memory, no selection -- the prompt is supplied whole by the
    caller as APrompt, so the body members are never consulted. Only the model,
    working directory and (Claude) session id actually drive the request. }
  TAefosComposerHarnessInputs = class(TInterfacedObject, IAefosCliHarnessInputs)
  private
    FConfig: TConfig;
    FModel: UnicodeString;
    FSessionId: UnicodeString;
  public
    constructor Create(const AConfig: TConfig; const AModel: UnicodeString);
    function AgentMode: Boolean;
    function Vocabulary: TAefosIdeVocabulary;
    function MemoryText: UnicodeString;
    function RenderedContext: UnicodeString;
    function CommandBody: UnicodeString;
    function Selection: UnicodeString;
    function WorkingDirectory: UnicodeString;
    function DispatchModel: UnicodeString;
    procedure ResolveMcpWiring(const AProfileKind: TExecutorKind;
      var AWiring: TAefosCliMcpWiring);
    function EnsureSessionId: UnicodeString;
    function SessionStarted: Boolean;
    function ConversationId: UnicodeString;
  end;

  { The Ollama chunk sink (mirrors the chat controller's TAefosOllamaSink). The
    transport stores a bare `of object` pointer, so the sink self-holds via FSelf
    (released on the terminal chunk) and consults FLive before touching FOwner.
    Accumulates the content delta; on the terminal line it settles the owner. }
  TAefosComposerOllamaSink = class(TInterfacedObject)
  private
    FLive: IAefosComposerLive;
    FOwner: TAefosLazComposerAI;
    FSelf: IInterface;
    FBuffer: UnicodeString;
  public
    constructor Create(AOwner: TAefosLazComposerAI;
      const ALive: IAefosComposerLive);
    procedure Deliver(const AChunk: TOllamaChunk);
    // Drop the self-hold WITHOUT delivering (the sync-throw path); idempotent.
    procedure Abandon;
  end;

  { The CLI sink (mirrors the chat controller's TAefosCliSink). Accumulates stdout
    to Complete -- the dispatcher's single terminal event (fired after any Error
    and on cancel) -- then settles the owner. Self-holds + token-gates identically. }
  TAefosComposerCliSink = class(TInterfacedObject)
  private
    FLive: IAefosComposerLive;
    FOwner: TAefosLazComposerAI;
    FSelf: IInterface;
    FBuffer: UnicodeString;
    FError: UnicodeString;
  public
    constructor Create(AOwner: TAefosLazComposerAI;
      const ALive: IAefosComposerLive);
    procedure DeliverChunk(const AChunk: UnicodeString);
    procedure DeliverError(const AMessage: UnicodeString);
    procedure DeliverComplete(const AExitCode: Integer;
      const ADurationMs: Cardinal);
    procedure Abandon;
  end;

const
  // Provider-side notices (English, vendor-neutral -- never name a CLI product).
  CNoProviderNotice = 'No AI provider is configured. Set one in Aefos Options.';
  CNoModelNotice = 'No local model is selected. Pick one in Aefos Options.';
  CEmptyReplyNotice = 'The AI returned no command.';

{ TAefosComposerLiveToken }

constructor TAefosComposerLiveToken.Create;
begin
  inherited Create;
  FAlive := True;
end;

function TAefosComposerLiveToken.IsAlive: Boolean;
begin
  Result := FAlive;
end;

procedure TAefosComposerLiveToken.Kill;
begin
  FAlive := False;
end;

{ TAefosComposerHarnessInputs }

constructor TAefosComposerHarnessInputs.Create(const AConfig: TConfig;
  const AModel: UnicodeString);
begin
  inherited Create;
  FConfig := AConfig;
  FModel := AModel;
  // A fresh id: the composer never resumes a conversation, so a session-using
  // driver (Claude) gets a brand-new one and never --resume.
  FSessionId := TAefosCliHarness.NewSessionId;
end;

function TAefosComposerHarnessInputs.AgentMode: Boolean;
begin
  // Never agentic. (AssembleFinalPrompt is not used by the composer -- it supplies
  // its own prompt -- so this only documents intent; BuildDispatchRequest gates on
  // ResolveMcpWiring's AgentToolingActive, which stays False below.)
  Result := False;
end;

function TAefosComposerHarnessInputs.Vocabulary: TAefosIdeVocabulary;
begin
  Result := TAefosCliHarness.LazarusVocabulary;
end;

function TAefosComposerHarnessInputs.MemoryText: UnicodeString;
begin
  Result := '';
end;

function TAefosComposerHarnessInputs.RenderedContext: UnicodeString;
begin
  Result := '';
end;

function TAefosComposerHarnessInputs.CommandBody: UnicodeString;
begin
  Result := '';
end;

function TAefosComposerHarnessInputs.Selection: UnicodeString;
begin
  Result := '';
end;

function TAefosComposerHarnessInputs.WorkingDirectory: UnicodeString;
begin
  // '' = inherit the IDE cwd (the composer has no project-folder resolver).
  Result := '';
end;

function TAefosComposerHarnessInputs.DispatchModel: UnicodeString;
begin
  Result := FModel;
end;

procedure TAefosComposerHarnessInputs.ResolveMcpWiring(
  const AProfileKind: TExecutorKind; var AWiring: TAefosCliMcpWiring);
begin
  // The composer is a plain one-shot completion: NO agent tooling, NO MCP host is
  // started. AgentToolingActive stays False so every driver emits its plain-chat
  // (tools-disabled) flags and never a server it cannot reach.
  AWiring.AgentToolingActive := False;
  AWiring.McpConfigPath := '';
  AWiring.McpBridgePath := '';
  AWiring.McpSession := '';
  AWiring.McpServerName := '';
  AWiring.ExtraMcpNames := nil;
end;

function TAefosComposerHarnessInputs.EnsureSessionId: UnicodeString;
begin
  Result := FSessionId;
end;

function TAefosComposerHarnessInputs.SessionStarted: Boolean;
begin
  // Always a NEW session (never resume) -- see Create.
  Result := False;
end;

function TAefosComposerHarnessInputs.ConversationId: UnicodeString;
begin
  // '' on purpose, and it costs nothing: the composer is a ONE-SHOT (it writes
  // its own prompt and never calls AssembleFinalPrompt), so there is no
  // conversation for the model to be aware of. Stating an id here would only
  // invite the model to treat a single command completion as a thread.
  Result := '';
end;

{ TAefosComposerOllamaSink }

constructor TAefosComposerOllamaSink.Create(AOwner: TAefosLazComposerAI;
  const ALive: IAefosComposerLive);
begin
  inherited Create;
  FOwner := AOwner;
  FLive := ALive;
  FSelf := Self;   // survive independent of the owner until the terminal chunk
end;

procedure TAefosComposerOllamaSink.Deliver(const AChunk: TOllamaChunk);
var
  LTerminal: Boolean;
begin
  // Main thread (the transport marshals via Synchronize on FPC). Accumulate the
  // content delta; settle on the terminal line, gated on the liveness token.
  LTerminal := AChunk.Done or (AChunk.Error <> '');
  if AChunk.Content <> '' then
    FBuffer := FBuffer + AChunk.Content;
  try
    if LTerminal and (FLive <> nil) and FLive.IsAlive and (FOwner <> nil) then
    begin
      if AChunk.Error <> '' then
        FOwner._Settle('', UTF16ToUTF8(AChunk.Error), True)
      else
        FOwner._Settle(UTF16ToUTF8(FBuffer), '', False);
    end;
  except
    // Never raise across the transport's marshalled call.
  end;
  if LTerminal then
    FSelf := nil;   // MUST be the last statement -- may free Self here.
end;

procedure TAefosComposerOllamaSink.Abandon;
begin
  FSelf := nil;
end;

{ TAefosComposerCliSink }

constructor TAefosComposerCliSink.Create(AOwner: TAefosLazComposerAI;
  const ALive: IAefosComposerLive);
begin
  inherited Create;
  FOwner := AOwner;
  FLive := ALive;
  FSelf := Self;   // survive until the terminal Complete
end;

procedure TAefosComposerCliSink.DeliverChunk(const AChunk: UnicodeString);
begin
  // Main thread (the dispatcher marshals via TThread.Queue). Just accumulate.
  if AChunk <> '' then
    FBuffer := FBuffer + AChunk;
end;

procedure TAefosComposerCliSink.DeliverError(const AMessage: UnicodeString);
begin
  // The CLI's captured stderr on a non-zero exit; kept for the settle below.
  if AMessage <> '' then
    FError := AMessage;
end;

procedure TAefosComposerCliSink.DeliverComplete(const AExitCode: Integer;
  const ADurationMs: Cardinal);
begin
  // The single terminal event of a run (fires once, including on cancel/timeout).
  try
    if (FLive <> nil) and FLive.IsAlive and (FOwner <> nil) then
    begin
      if AExitCode <> 0 then
        FOwner._Settle('', UTF16ToUTF8(FError), True)
      else
        FOwner._Settle(UTF16ToUTF8(FBuffer), '', False);
    end;
  except
    // Never raise across the dispatcher's marshalled call.
  end;
  FSelf := nil;   // MUST be the last statement -- may free Self here.
end;

procedure TAefosComposerCliSink.Abandon;
begin
  FSelf := nil;
end;

{ TAefosLazComposerAI }

constructor TAefosLazComposerAI.Create;
var
  LToken: TAefosComposerLiveToken;
begin
  inherited Create;
  LToken := TAefosComposerLiveToken.Create;
  FLive := LToken;       // holds it alive
  FLiveObj := LToken;    // raw view so Destroy can Kill it
  FInFlight := False;
end;

destructor TAefosLazComposerAI.Destroy;
begin
  // Kill the token FIRST so any chunk marshalled back after this point is a no-op
  // (the sinks self-hold and outlive us). Then cancel the in-flight transports so
  // no spawned child outlives the control (mirrors the chat controller teardown).
  if FLiveObj <> nil then
    TAefosComposerLiveToken(FLiveObj).Kill;
  Cancel;
  inherited Destroy;
end;

function TAefosLazComposerAI._ConfigRoot: UnicodeString;
var
  LAppData: string;
begin
  // The SHARED, IDE-wide root %APPDATA%\Aefos -- the same file the chat controller
  // and the Options page use (one brain across both IDEs). Crossed to UnicodeString
  // (UTF8ToUTF16) exactly like the controller's FConfigRoot, so the resolver seam
  // (function: UnicodeString of object) binds.
  LAppData := SysUtils.GetEnvironmentVariable('APPDATA');
  Result := UTF8ToUTF16(LAppData + '\Aefos');
end;

function TAefosLazComposerAI._LoadConfig: TConfig;
var
  LResolver: TConfigRootResolver;
  LConfig: IConfig;
begin
  // Bound to a typed local so it binds as a method POINTER, not a call (the FPC
  // delphi-mode idiom the chat controller uses for the same resolver seam).
  LResolver := Self._ConfigRoot;
  LConfig := TConfigService.Create(LResolver);
  LConfig.Load;
  Result := LConfig.Snapshot;
end;

function TAefosLazComposerAI._ResolveModel(const AConfig: TConfig): UnicodeString;
begin
  // Same rule the chat header uses (_ResolveCurrentModel): prefer the model
  // remembered for THIS executor in the shared models.json, fall back to the
  // single configured Model. Kept in UnicodeString throughout (the delphiunicode
  // store + config fields) -- no lossy round-trip through this unit's AnsiString.
  Result := TExecutorModelStore.SelectedModelForKind(AConfig.Executor);
  if Trim(Result) = '' then
    Result := AConfig.Model;
end;

procedure TAefosLazComposerAI.Ask(const AUserText: string;
  const AOnResult: TAefosComposerResult; const AOnError: TAefosComposerError);
var
  LConfig: TConfig;
  LPrompt: string;
begin
  if Trim(AUserText) = '' then
    Exit;
  // Single-shot: abort any previous in-flight run before starting a new one.
  if FInFlight then
    Cancel;
  FOnResult := AOnResult;
  FOnError := AOnError;
  FInFlight := True;
  LPrompt := BuildPrompt(AUserText);
  try
    LConfig := _LoadConfig;
    if LConfig.Executor = ekOllama then
      _DispatchOllama(LPrompt, LConfig)
    else
      _DispatchCli(LPrompt, LConfig);
  except
    on E: Exception do
      // A synchronous throw (config read, arg build, spawn failure) settles as an
      // error now -- no async terminal event will ever come to settle it.
      _Settle('', E.Message, True);
  end;
end;

procedure TAefosLazComposerAI._DispatchOllama(const APrompt: string;
  const AConfig: TConfig);
var
  LModel: UnicodeString;
  LBaseUrl: UnicodeString;
  LBody: UnicodeString;
  LSink: TAefosComposerOllamaSink;
begin
  LModel := _ResolveModel(AConfig);
  if Trim(LModel) = '' then
  begin
    _Settle('', CNoModelNotice, True);
    Exit;
  end;
  // AConfig.OllamaBaseUrl is already UnicodeString (delphiunicode TConfig).
  LBaseUrl := AConfig.OllamaBaseUrl;
  // Build the /api/chat body (stream=true) -- cross the AnsiString prompt to
  // UTF-16 for the delphiunicode request builder; the single framed prompt is the
  // user turn.
  LBody := OllamaBuildChatRequest(LModel,
    [TOllamaMessage.New('user', UTF8ToUTF16(APrompt))], True);
  FTransport := NewOllamaTransport;
  LSink := TAefosComposerOllamaSink.Create(Self, FLive);
  FSinkHold := LSink;
  try
    FTransport.ChatStream(LBaseUrl, LBody, LSink.Deliver);
  except
    // A synchronous ChatStream throw means no terminal Deliver ever runs, so the
    // sink's own self-hold would leak -- release it before re-raising to Ask's
    // except (which settles the error).
    LSink.Abandon;
    FSinkHold := nil;
    raise;
  end;
end;

procedure TAefosLazComposerAI._DispatchCli(const APrompt: string;
  const AConfig: TConfig);
var
  LProfile: IExecutorProfile;
  LExecutorPath: UnicodeString;
  LModel: UnicodeString;
  LInputs: IAefosCliHarnessInputs;
  LRequest: TDispatchRequest;
  LSink: TAefosComposerCliSink;
  LOnChunk: TDispatcherChunkCallback;
  LOnComplete: TDispatcherCompleteCallback;
  LOnError: TDispatcherErrorCallback;
begin
  // Resolve the driver + binary through the SAME shared ladder the chat uses (all
  // delphiunicode, so path/model stay UnicodeString -- no lossy round-trip).
  LProfile := TProviderRegistry.ResolveExecutorProfile(AConfig.Executor);
  LExecutorPath := ResolveCLIBinary(AConfig.ExecutorPath, LProfile.BinaryName);
  if LExecutorPath = '' then
  begin
    _Settle('', CNoProviderNotice, True);
    Exit;
  end;
  LModel := _ResolveModel(AConfig);
  // DELEGATE the request assembly to the shared harness (driver args / api-key
  // env / timeout / filter). The composer's own framed prompt is the request body
  // (APrompt), so no aefos-first agent preamble is prepended and MCP stays off.
  LInputs := TAefosComposerHarnessInputs.Create(AConfig, LModel);
  LRequest := TAefosCliHarness.BuildDispatchRequest(LInputs, AConfig, LProfile,
    LExecutorPath, UTF8ToUTF16(APrompt));
  FCliDispatcher := TCLIDispatcher.Create;
  LSink := TAefosComposerCliSink.Create(Self, FLive);
  FSinkHold := LSink;
  // Bound to typed locals so each binds as a method POINTER (the FPC idiom).
  LOnChunk := LSink.DeliverChunk;
  LOnComplete := LSink.DeliverComplete;
  LOnError := LSink.DeliverError;
  try
    FCliRun := FCliDispatcher.Dispatch(LRequest, LOnChunk, LOnComplete, LOnError);
  except
    // A synchronous Dispatch throw (executor not found / spawn failed) means no
    // Deliver* ever runs, so drop the sink's own self-hold before re-raising to
    // Ask's except (which settles the error).
    LSink.Abandon;
    FSinkHold := nil;
    raise;
  end;
end;

procedure TAefosLazComposerAI._Settle(const ATextRaw, AErrorMessage: string;
  const AIsError: Boolean);
var
  LCommand: string;
begin
  // The single settle point. Idempotent: once a turn settled (or was cancelled)
  // FInFlight is False and a late marshalled terminal event is ignored.
  if not FInFlight then
    Exit;
  FInFlight := False;
  FTransport := nil;
  FCliRun := nil;
  if AIsError then
  begin
    if Assigned(FOnError) then
      FOnError(AErrorMessage);
    Exit;
  end;
  LCommand := Sanitize(ATextRaw);
  if LCommand = '' then
  begin
    if Assigned(FOnError) then
      FOnError(CEmptyReplyNotice);
    Exit;
  end;
  if Assigned(FOnResult) then
    FOnResult(LCommand);
end;

procedure TAefosLazComposerAI.Cancel;
begin
  // Aborts an in-flight run; neither callback fires (FInFlight is cleared BEFORE
  // the cancel so the driven terminal event settles into a no-op). Idempotent.
  if not FInFlight then
  begin
    // Still release any lingering transports (defensive; normally already nil).
    FTransport := nil;
    FCliRun := nil;
    Exit;
  end;
  FInFlight := False;
  if Assigned(FTransport) then
    try
      FTransport.Cancel;
    except
    end;
  if Assigned(FCliRun) then
    try
      FCliRun.Cancel;
    except
    end;
  FTransport := nil;
  FCliRun := nil;
end;

class function TAefosLazComposerAI.BuildPrompt(const AUserText: string): string;
begin
  // Tight framing: the Lazarus terminal spawns cmd.exe, so target cmd syntax and
  // demand ONLY the command line (models love to add prose / fences -- Sanitize is
  // the second line of defence, this is the first).
  Result :=
    'You are a shell-command generator for a Windows cmd.exe terminal. ' +
    'Output ONLY the single command line that accomplishes the user''s request -- ' +
    'no explanation, no markdown code fences, no backticks, no leading prompt ' +
    'characters ($ or >), nothing but the command itself. Use cmd.exe / Windows ' +
    'syntax. If the request cannot be a single command, output the closest single ' +
    'command.' + sLineBreak + sLineBreak +
    'Request: ' + AUserText;
end;

class function TAefosLazComposerAI.Sanitize(const AResponse: string): string;

  // Strips a leading shell-prompt sigil ('$ ', '> ', 'PS> ') and a pair of
  // wrapping inline backticks from one already-trimmed line.
  function _CleanLine(const ALine: string): string;
  begin
    Result := ALine;
    if (Copy(Result, 1, 2) = '$ ') or (Copy(Result, 1, 2) = '> ') then
      Result := Trim(Copy(Result, 3, Length(Result)))
    else if Copy(Result, 1, 4) = 'PS> ' then
      Result := Trim(Copy(Result, 5, Length(Result)));
    if (Length(Result) >= 2) and (Result[1] = '`') and
       (Result[Length(Result)] = '`') then
      Result := Trim(Copy(Result, 2, Length(Result) - 2));
  end;

var
  LLines: TStringList;
  LIndex: Integer;
  LLine: string;
  LFenced: string;         // first cleaned line strictly INSIDE a ``` fence
  LInFence: Boolean;
  LCandidates: TStringList; // cleaned non-empty, non-fence lines in order
begin
  // Reduce a (possibly chatty) reply to ONE runnable command line. Models wrap the
  // command in different ways, so this is defensive in three layers:
  //   1) prefer the first non-empty line INSIDE a ``` code fence (the most common
  //      and least ambiguous wrapper);
  //   2) otherwise take the first non-empty line, but skip a leading prose lead-in
  //      that ends with ':' ("Here is the command:") when a real line follows;
  //   3) every candidate has its prompt sigil / wrapping backticks / whitespace
  //      stripped (_CleanLine).
  Result := '';
  LFenced := '';
  LInFence := False;
  LLines := TStringList.Create;
  LCandidates := TStringList.Create;
  try
    LLines.Text := AResponse;
    for LIndex := 0 to LLines.Count - 1 do
    begin
      LLine := Trim(LLines[LIndex]);
      if LLine = '' then
        Continue;
      // A markdown fence line (``` / ```cmd / ```bat / ```sh ...) toggles the
      // in-fence state and is never itself a command.
      if Copy(LLine, 1, 3) = '```' then
      begin
        LInFence := not LInFence;
        Continue;
      end;
      LLine := _CleanLine(LLine);
      if LLine = '' then
        Continue;
      if LInFence and (LFenced = '') then
        LFenced := LLine;
      LCandidates.Add(LLine);
    end;
    if LFenced <> '' then
      Result := LFenced
    else if LCandidates.Count > 0 then
    begin
      // Skip a single trailing-':' prose lead-in when a following line exists.
      if (LCandidates.Count > 1) and
         (Copy(LCandidates[0], Length(LCandidates[0]), 1) = ':') then
        Result := LCandidates[1]
      else
        Result := LCandidates[0];
    end;
  finally
    LCandidates.Free;
    LLines.Free;
  end;
end;

end.
