unit Aefos.OTA.Chat.Core.OllamaDispatcher;

{
  Ollama-backed ICLIDispatcher (phase 3 of meta\ollama-provider-plan.md).

  A SECOND implementation of the dispatcher contract: instead of spawning a
  CLI process it streams the prompt through the local Ollama HTTP transport
  (Aefos.Provider.Ollama). TCommandExecutor stays untouched - run lifecycle,
  Cancel, stream-to-surface and completion all flow through the same
  ICLIDispatcher/IDispatcherRunHandle channels the process dispatcher uses.

  Mapping: chunk content -> AOnOutput; terminal Done -> AOnComplete(0, ms);
  terminal Error -> AOnError (no completion after, mirroring the process
  dispatcher's spawn-failure shape). The transport guarantees exactly one
  terminal event, so exactly one of AOnComplete/AOnError fires per run.

  Model resolution: an Args pair ['--model', <name>] (what CommandExecutor
  emits when config.Model is set) overrides the resolver's Model; with
  neither present the run fails fast with a configuration error.

  The transport factory is injectable so headless tests drive the whole
  bridge with a scripted fake - no HTTP, no server.
}

interface

uses
  System.SysUtils,
  Aefos.OTA.Chat.Core.Dispatcher.Types,
  Aefos.OTA.Chat.Core.CLIDispatcher,
  Aefos.Provider.Ollama.Core,
  Aefos.Provider.Ollama;

type
  TOllamaDispatchSettings = record
    BaseUrl: string;  // '' falls back to COllamaDefaultBaseUrl
    Model: string;
  end;

  // Resolved per dispatch so Options edits apply to the NEXT turn without
  // recomposing the executor.
  TOllamaSettingsResolver = reference to function: TOllamaDispatchSettings;
  TOllamaTransportFactory = reference to function: IOllamaTransport;

  TOllamaDispatcher = class(TInterfacedObject, ICLIDispatcher)
  private
    FSettingsResolver: TOllamaSettingsResolver;
    FTransportFactory: TOllamaTransportFactory;
    class function _ArgsModelOverride(const AArgs: TArray<string>): string; static;
  public
    // ATransportFactory defaults to the real HTTP transport when nil.
    constructor Create(const ASettingsResolver: TOllamaSettingsResolver;
      const ATransportFactory: TOllamaTransportFactory = nil);
    function Dispatch(const ARequest: TDispatchRequest;
      const AOnOutput: TDispatcherChunkCallback;
      const AOnComplete: TDispatcherCompleteCallback;
      const AOnError: TDispatcherErrorCallback): IDispatcherRunHandle; reintroduce;
  end;

implementation

uses
  System.Classes;

type
  // State shared between the run handle and the stream callback. Everything
  // here is touched on the main thread only (the transport marshals events;
  // the scripted test fake fires synchronously on the calling thread).
  TOllamaRunState = class
  public
    Transport: IOllamaTransport;
    Done: Boolean;
    RunId: TGUID;
  end;

  TOllamaRunHandle = class(TInterfacedObject, IDispatcherRunHandle)
  private
    FState: TOllamaRunState;
  public
    constructor Create(const AState: TOllamaRunState);
    destructor Destroy; override;
    function IsRunning: Boolean;
    procedure Cancel;
    function WaitFor(const ATimeoutMs: Cardinal): Boolean;
    function RunId: TGUID;
    { Always '': this dispatcher speaks HTTP, it has no child process and
      therefore no stderr. Present only to satisfy the seam. }
    function StderrText: string;
  end;

{ TOllamaRunHandle }

constructor TOllamaRunHandle.Create(const AState: TOllamaRunState);
begin
  inherited Create;
  FState := AState;
end;

destructor TOllamaRunHandle.Destroy;
begin
  FState.Free;
  inherited;
end;

function TOllamaRunHandle.IsRunning: Boolean;
begin
  Result := not FState.Done;
end;

procedure TOllamaRunHandle.Cancel;
begin
  if Assigned(FState.Transport) then
    FState.Transport.Cancel;
end;

function TOllamaRunHandle.WaitFor(const ATimeoutMs: Cardinal): Boolean;
var
  LStart: Cardinal;
begin
  // The terminal event arrives through the main-thread queue, so pump it
  // while waiting (the IDE main loop equivalent during a blocking wait).
  LStart := TThread.GetTickCount;
  while (not FState.Done) and
    (TThread.GetTickCount - LStart < ATimeoutMs) do
    CheckSynchronize(20);
  Result := FState.Done;
end;

function TOllamaRunHandle.RunId: TGUID;
begin
  Result := FState.RunId;
end;

function TOllamaRunHandle.StderrText: string;
begin
  Result := '';
end;

{ TOllamaDispatcher }

constructor TOllamaDispatcher.Create(
  const ASettingsResolver: TOllamaSettingsResolver;
  const ATransportFactory: TOllamaTransportFactory);
begin
  inherited Create;
  FSettingsResolver := ASettingsResolver;
  FTransportFactory := ATransportFactory;
  if not Assigned(FTransportFactory) then
    FTransportFactory :=
      function: IOllamaTransport
      begin
        Result := NewOllamaTransport;
      end;
end;

class function TOllamaDispatcher._ArgsModelOverride(
  const AArgs: TArray<string>): string;
var
  LIndex: Integer;
begin
  Result := '';
  for LIndex := 0 to High(AArgs) - 1 do
    if SameText(AArgs[LIndex], '--model') then
      Exit(AArgs[LIndex + 1]);
end;

function TOllamaDispatcher.Dispatch(const ARequest: TDispatchRequest;
  const AOnOutput: TDispatcherChunkCallback;
  const AOnComplete: TDispatcherCompleteCallback;
  const AOnError: TDispatcherErrorCallback): IDispatcherRunHandle;
var
  LState: TOllamaRunState;
  LSettings: TOllamaDispatchSettings;
  LModel: string;
  LBody: string;
  LMessages: TArray<TOllamaMessage>;
  LStart: Cardinal;
  LKeepAlive: IDispatcherRunHandle;
begin
  LState := TOllamaRunState.Create;
  LState.Done := False;
  CreateGUID(LState.RunId);
  Result := TOllamaRunHandle.Create(LState);
  // The stream callback holds a handle ref (the handle owns LState), so a
  // caller releasing the handle mid-run cannot leave the closure touching a
  // freed state. Released on the terminal event; the closure's own death
  // (worker end) releases it on every other path.
  LKeepAlive := Result;

  LSettings := Default(TOllamaDispatchSettings);
  if Assigned(FSettingsResolver) then
    LSettings := FSettingsResolver();
  LModel := _ArgsModelOverride(ARequest.Args);
  if LModel = '' then
    LModel := LSettings.Model;
  if LModel = '' then
  begin
    // Fail fast and OUTSIDE the stream: no transport run to cancel.
    LState.Done := True;
    if Assigned(AOnError) then
      AOnError('No local model selected. Set the model for the local ' +
        'endpoint in Tools > Options > Aefos > AI Chat.');
    Exit;
  end;

  // Built into a typed local first, rather than passed as an inline [ ... ]
  // literal. OllamaBuildChatRequest is overloaded, and 10 Seattle's compiler
  // will not pick an overload from an open-array literal plus defaulted
  // parameters - it reports "no overloaded version can be called with these
  // arguments". Naming the type removes the ambiguity, and reads the same on
  // every version.
  LMessages := TArray<TOllamaMessage>.Create(
    TOllamaMessage.New('user', ARequest.Prompt));
  LBody := OllamaBuildChatRequest(LModel, LMessages, True);
  LStart := TThread.GetTickCount;
  LState.Transport := FTransportFactory();
  LState.Transport.ChatStream(LSettings.BaseUrl, LBody,
    procedure(const AChunk: TOllamaChunk)
    begin
      if LState.Done then
        Exit;
      if AChunk.Error <> '' then
      begin
        LState.Done := True;
        LKeepAlive := nil;
        if Assigned(AOnError) then
          AOnError(AChunk.Error);
        Exit;
      end;
      if (AChunk.Content <> '') and Assigned(AOnOutput) then
        AOnOutput(AChunk.Content);
      if AChunk.Done then
      begin
        LState.Done := True;
        LKeepAlive := nil;
        if Assigned(AOnComplete) then
          AOnComplete(0, TThread.GetTickCount - LStart);
      end;
    end);
end;

end.
