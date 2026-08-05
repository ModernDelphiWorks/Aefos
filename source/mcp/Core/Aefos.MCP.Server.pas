unit Aefos.MCP.Server;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  In-process MCP server core (ESP-002, Epic 3/5 Demand 1/5).

  Responsibilities:
    - Own the tool registry.
    - Receive JSON-RPC frames from an IMCPTransport.
    - Implement initialize / tools/list / tools/call.
    - Truncate over-budget tool results at MCP_TOOL_RESULT_BUDGET; the
      handler is responsible for paginating the body (ADR-058 contract).
    - Convert uncaught exceptions to -32603 internal-error frames.

  Threading:
    - Frames arrive on the transport worker thread; handlers execute on
      that thread. Handlers marshal to the OTA main thread via the
      injected IMCPToolContext.

  Validation:
    - The input-schema check is intentionally minimal in 1/5: required
      field presence + top-level type check. Full JSON Schema is out of
      scope (called out in implement-report).
}

interface

uses
  SysUtils,
  Classes,
  Aefos.Compat.Json,
  SyncObjs,
  Generics.Collections,
  Aefos.MCP.Types,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.FlowGuide,
  Aefos.MCP.InspectorBridge;

type
  // Injected by the composition root (Delphi IDE host). FPC 3.2.2 lacks
  // anonymous methods; those roots are Delphi-only, so the FPC build gets
  // method-pointer forms purely so these seam types compile.
{$IFNDEF FPC}
  TMCPTransportFactory = reference to function: IMCPTransport;
  TMCPMainThreadMarshal = reference to procedure(const AProc: TThreadProcedure);
{$ELSE}
  TMCPTransportFactory = function: IMCPTransport of object;
  TMCPMainThreadMarshal = procedure(const AProc: TThreadProcedure) of object;
{$ENDIF}

  IMCPServer = interface
    ['{3D1F7B82-5A09-4C68-9E40-7B1A8F2D4C31}']
    procedure Start(const APipeName: string);
    procedure Stop;
    procedure RegisterTool(const ATool: TMCPToolDescriptor);
    function Started: Boolean;
    // RULE #1: the OTA layer injects how to read the IDE's current view so the
    // intent guard can reject a design/code command sent in the wrong view. The
    // provider is invoked on the main thread by the server; nil = guard off.
    procedure SetViewProvider(const AProvider: TMCPViewProvider);
    // Addon-MCP gateway (ESP: `aefos install <mcp>` -> every agent). Injected by
    // the host composition root; nil = off (default). When set, its tools appear
    // in tools/list (namespaced) and a namespaced tools/call is routed to it.
    // The server drives its Shutdown from Stop/Destroy so a child never outlives
    // the host (CLAUDE.md IDE-UNLOAD rules).
    procedure SetToolGateway(const AGateway: IMCPToolGateway);
    // Watches addon tool calls so a host can draw what the agent is doing to a
    // window. nil (the default) = nothing is watched, and nothing is drawn.
    procedure SetVisualReport(const AReport: TMCPVisualReport);
  end;

  TMCPServer = class(TInterfacedObject, IMCPServer, IMCPToolContext,
    IMCPNotificationPublisher, IMCPInspectorHost)
  private
    FTools: TDictionary<string, TMCPToolDescriptor>;
    FToolOrder: TList<string>;
    FTransport: IMCPTransport;
    FTransportFactory: TMCPTransportFactory;
    FMarshal: TMCPMainThreadMarshal;
    FStarted: Boolean;
    FInitialized: Boolean;
    FLock: TCriticalSection;
    FServerVersion: string;
    FCancelSink: IMCPCancellationSink;
    FViewProvider: TMCPViewProvider;
    FToolGateway: IMCPToolGateway;
    FVisualReport: TMCPVisualReport;
    FResourceRegistry: IMCPResourceRegistry;
    FSubscriptions: TDictionary<string, Boolean>;
    FSubLock: TCriticalSection;
    procedure _FreeSchemas;
    procedure _OnTransportFrame(const AFrame: string);
    procedure _HandleFrame(const AFrame: string);
    procedure _DispatchMethod(const ARequest: TMCPRequest);
    procedure _HandleInitialize(const ARequest: TMCPRequest);
    procedure _HandleToolsList(const ARequest: TMCPRequest);
    procedure _HandleToolsCall(const ARequest: TMCPRequest);
    procedure _AppendGatewayTools(const AArray: TJSONArray);
    procedure _HandleAddonToolCall(const ARequest: TMCPRequest;
      const AName: string; const AParams: TJSONObject);
    procedure _HandleNotificationsInitialized(const ARequest: TMCPRequest);
    procedure _HandleNotificationsCancelled(const ARequest: TMCPRequest);
    procedure _HandleResourcesList(const ARequest: TMCPRequest);
    procedure _HandleResourcesRead(const ARequest: TMCPRequest);
    procedure _HandleResourcesSubscribe(const ARequest: TMCPRequest);
    procedure _HandleResourcesUnsubscribe(const ARequest: TMCPRequest);
    procedure _RequireRegistry(const AMethod: string);
    function _ReadRequiredUri(const ARequest: TMCPRequest): string;
    function _IsSubscribed(const AUri: string): Boolean;
    procedure _EmitNotification(const AMethod: string;
      const AParams: TJSONObject);
    function _BuildToolDescriptorJson(const ATool: TMCPToolDescriptor): TJSONObject;
    function _ValidateAgainstSchema(const AArgs: TJSONObject;
      const ASchema: TJSONObject; out AMessage: string): Boolean;
    function _CheckRequiredFields(const AArgs: TJSONObject;
      const ASchema: TJSONObject; out AMessage: string): Boolean;
    function _CheckPropertyTypes(const AArgs: TJSONObject;
      const ASchema: TJSONObject; out AMessage: string): Boolean;
    function _JsonTypeMatches(const AExpectedType: string;
      const AValue: TJSONValue): Boolean;
    function _CloneJson(const AValue: TJSONValue): TJSONValue;
    procedure _EmitResult(const AId: TJSONValue; const AResult: TJSONValue);
    procedure _EmitError(const AId: TJSONValue; const ACode: Integer;
      const AMessage: string);
    procedure _EmitErrorFromException(const AId: TJSONValue;
      const AException: Exception);
    function _ApplyBudget(const AResult: TMCPToolResult): TMCPToolResult;
  public
    constructor Create(const ATransportFactory: TMCPTransportFactory;
      const AMarshal: TMCPMainThreadMarshal;
      const AServerVersion: string;
      const ACancelSink: IMCPCancellationSink = nil;
      const AResourceRegistry: IMCPResourceRegistry = nil);
    destructor Destroy; override;
    // IMCPServer
    procedure Start(const APipeName: string);
    procedure Stop;
    procedure RegisterTool(const ATool: TMCPToolDescriptor);
    function Started: Boolean;
    procedure SetViewProvider(const AProvider: TMCPViewProvider);
    procedure SetToolGateway(const AGateway: IMCPToolGateway);
    procedure SetVisualReport(const AReport: TMCPVisualReport);
    // IMCPToolContext
    procedure MarshalToMainThread(const AProc: TThreadProcedure);
    function BudgetBytes: Integer;
    // IMCPNotificationPublisher
    procedure NotifyResourceUpdated(const AUri: string);
    // Public helpers (used by tests; not part of the interface contract).
    procedure InjectFrameForTests(const AFrame: string);
    // IMCPInspectorHost — synchronous dispatch surface for the MCP Tool
    // Inspector (Epic 7/7 Demand 1/8, ADR-117). Processes a JSON-RPC frame
    // without touching the live transport and returns the response frame
    // string. Dev-only — not part of IMCPServer.
    function DispatchInspectorFrame(const AFrame: string): string;
  end;

implementation

type
  // Per-call carrier for the marshalled view read. The transport allows several
  // simultaneous clients, each dispatching tool calls on its own worker thread —
  // a shared scratch field on the server would let one client's marshalled read
  // clobber another's and silently defeat the RULE #1 view guard. Each call
  // creates its own instance, so the result slot is never shared. (A carrier
  // object instead of an inline closure: FPC 3.2.2 has no anonymous methods.)
  TMarshalledViewRead = class
  private
    FProvider: TMCPViewProvider;
    FView: TMCPToolIntent;
  public
    constructor Create(const AProvider: TMCPViewProvider);
    procedure Run;
    property View: TMCPToolIntent read FView;
  end;

constructor TMarshalledViewRead.Create(const AProvider: TMCPViewProvider);
begin
  inherited Create;
  FProvider := AProvider;
  FView := tiNeutral;
end;

procedure TMarshalledViewRead.Run;
begin
  // Runs on the IDE main thread (marshalled). The provider crosses BPL
  // boundaries and reads live IDE state — a nil ref or OTA hiccup must degrade
  // to tiNeutral (guard off = allow), never crash the whole tool dispatch.
  try
    FView := FProvider();
  except
    FView := tiNeutral;
  end;
end;

{ TMCPServer }

constructor TMCPServer.Create(const ATransportFactory: TMCPTransportFactory;
  const AMarshal: TMCPMainThreadMarshal;
  const AServerVersion: string;
  const ACancelSink: IMCPCancellationSink;
  const AResourceRegistry: IMCPResourceRegistry);
begin
  inherited Create;
  if not Assigned(ATransportFactory) then
    raise EArgumentNilException.Create('TMCPServer: ATransportFactory');
  if not Assigned(AMarshal) then
    raise EArgumentNilException.Create('TMCPServer: AMarshal');
  FTransportFactory := ATransportFactory;
  FMarshal := AMarshal;
  FServerVersion := AServerVersion;
  // Optional (ADR-069): no sink → notifications/cancelled is a no-op.
  FCancelSink := ACancelSink;
  // Optional (ADR-071): no registry → the resources capability is absent.
  FResourceRegistry := AResourceRegistry;
  FTools := TDictionary<string, TMCPToolDescriptor>.Create;
  FToolOrder := TList<string>.Create;
  FLock := TCriticalSection.Create;
  FSubscriptions := TDictionary<string, Boolean>.Create;
  FSubLock := TCriticalSection.Create;
end;

destructor TMCPServer.Destroy;
begin
  Stop;
  // Belt to Stop's braces: kill any addon children before the object (and, for
  // the RAD Studio host, the BPL) goes away. Idempotent + never raises.
  if Assigned(FToolGateway) then
    try
      FToolGateway.Shutdown;
    except
    end;
  FToolGateway := nil;
  _FreeSchemas;
  FTools.Free;
  FToolOrder.Free;
  FLock.Free;
  FSubscriptions.Free;
  FSubLock.Free;
  inherited;
end;

procedure TMCPServer._FreeSchemas;
var
  LPair: TPair<string, TMCPToolDescriptor>;
begin
  for LPair in FTools do
  begin
    LPair.Value.InputSchema.Free;
    LPair.Value.OutputSchema.Free;
  end;
  FTools.Clear;
  FToolOrder.Clear;
end;

procedure TMCPServer.RegisterTool(const ATool: TMCPToolDescriptor);
var
  LTool: TMCPToolDescriptor;
begin
  if ATool.Name = '' then
    raise EArgumentException.Create('TMCPServer.RegisterTool: name required');
  if not Assigned(ATool.Handler) then
    raise EArgumentNilException.Create('TMCPServer.RegisterTool: handler');
  LTool := ATool;
  {$IFDEF DEBUG}
  // Intent self-test (correct by construction): a tool whose name looks mutating
  // but declares no design/code intent has almost certainly forgotten to set
  // Descriptor.Intent — and would silently lose BOTH the guard and the rule
  // suffix. Fail LOUD here in DEBUG so it can never ship that way. A genuinely
  // view-neutral mutating-prefixed tool is allowlisted in Aefos.MCP.IntentGuard.
  if TIntentGuard.MutatingNameNeedsIntent(LTool.Name, LTool.Intent) then
    raise Exception.Create(
      'Aefos intent self-test: tool "' + LTool.Name + '" looks mutating but ' +
      'declares no design/code intent. Set Result.Intent in its _Build, or (if ' +
      'it is genuinely view-neutral) add it to CNeutralMutators in ' +
      'Aefos.MCP.IntentGuard.');
  {$ENDIF}
  // RULE #1, single source of truth: a design/code tool carries the view rule in
  // its own description (the only channel that reaches the raw terminal). The
  // text lives ONCE in Aefos.MCP.IntentGuard, appended here by the intent the
  // tool DECLARED in its _Build — never copied into the per-tool calls.
  LTool.Description := LTool.Description +
    TIntentGuard.IntentRuleSuffix(LTool.Intent);
  FLock.Enter;
  try
    if FTools.ContainsKey(LTool.Name) then
      raise EArgumentException.Create(
        'TMCPServer.RegisterTool: duplicate name ' + LTool.Name);
    FTools.Add(LTool.Name, LTool);
    FToolOrder.Add(LTool.Name);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPServer.SetViewProvider(const AProvider: TMCPViewProvider);
begin
  FViewProvider := AProvider;
end;

procedure TMCPServer.SetToolGateway(const AGateway: IMCPToolGateway);
begin
  FToolGateway := AGateway;
end;

procedure TMCPServer.SetVisualReport(const AReport: TMCPVisualReport);
begin
  FVisualReport := AReport;
end;

procedure TMCPServer.Start(const APipeName: string);
begin
  if FStarted then
    Exit;
  FTransport := FTransportFactory();
  if not Assigned(FTransport) then
    raise EMCPInternalError.Create('TMCPServer.Start: transport factory returned nil');
  // Method pointer instead of an inline closure (FPC 3.2.2 has no anonymous
  // methods): _OnTransportFrame already has the exact TMCPFrameCallback shape,
  // so pass it directly. Assigning a method to the callback type works on both
  // compilers (Delphi auto-wraps a method into the reference-to type).
  FTransport.SetOnFrame(_OnTransportFrame);
  FTransport.Start(APipeName);
  FStarted := True;
end;

procedure TMCPServer.Stop;
var
  LTransport: IMCPTransport;
begin
  if not FStarted then
    Exit;
  LTransport := FTransport;
  FTransport := nil;
  FStarted := False;
  FInitialized := False;
  if Assigned(LTransport) then
    LTransport.Stop;
  // Addon-MCP children die WITH the server (CLAUDE.md IDE-UNLOAD rules): a child
  // that outlives the BPL unmap is a crash. Done AFTER the transport joins so no
  // in-flight worker is dispatching a tools/call; guarded so teardown never
  // raises. Shutdown is idempotent (Destroy calls it too).
  if Assigned(FToolGateway) then
    try
      FToolGateway.Shutdown;
    except
    end;
end;

function TMCPServer.Started: Boolean;
begin
  Result := FStarted;
end;

procedure TMCPServer.MarshalToMainThread(const AProc: TThreadProcedure);
begin
  FMarshal(AProc);
end;

function TMCPServer.BudgetBytes: Integer;
begin
  Result := MCP_TOOL_RESULT_BUDGET;
end;

procedure TMCPServer._OnTransportFrame(const AFrame: string);
begin
  _HandleFrame(AFrame);
end;

procedure TMCPServer.InjectFrameForTests(const AFrame: string);
begin
  _HandleFrame(AFrame);
end;

type
  // Capture-only transport used by DispatchInspectorFrame to harvest the
  // server's response synchronously without touching the live transport.
  // Lifetime: instantiated and freed within DispatchInspectorFrame.
  TInspectorCaptureTransport = class(TInterfacedObject, IMCPTransport)
  strict private
    FFrame: string;
  public
    procedure Start(const APipeName: string);
    procedure Stop;
    procedure Send(const AFrame: string);
    procedure SetOnFrame(const ACallback: TMCPFrameCallback);
    property Frame: string read FFrame;
  end;

procedure TInspectorCaptureTransport.Start(const APipeName: string);
begin
end;

procedure TInspectorCaptureTransport.Stop;
begin
end;

procedure TInspectorCaptureTransport.Send(const AFrame: string);
begin
  // The server calls Send exactly once per request via _EmitResult / _EmitError.
  // Last write wins on the unlikely off chance a notification escapes through.
  FFrame := AFrame;
end;

procedure TInspectorCaptureTransport.SetOnFrame(const ACallback: TMCPFrameCallback);
begin
end;

function TMCPServer.DispatchInspectorFrame(const AFrame: string): string;
var
  LCapture: TInspectorCaptureTransport;
  LCaptureRef: IMCPTransport;
  LSavedTransport: IMCPTransport;
begin
  // The transport swap is serialised by FLock so a concurrent named-pipe
  // worker thread never observes a half-swapped FTransport. The capture
  // transport receives _EmitResult / _EmitError synchronously inside
  // _HandleFrame; the live transport is restored before any other thread
  // can re-enter the server.
  LCapture := TInspectorCaptureTransport.Create;
  LCaptureRef := LCapture;
  FLock.Enter;
  try
    LSavedTransport := FTransport;
    FTransport := LCaptureRef;
    try
      _HandleFrame(AFrame);
    finally
      FTransport := LSavedTransport;
    end;
  finally
    FLock.Leave;
  end;
  Result := LCapture.Frame;
end;

procedure TMCPServer._HandleFrame(const AFrame: string);
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
  LRequest: TMCPRequest;
  LIdValue: TJSONValue;
  LMethodPair: TJSONPair;
  LParamsValue: TJSONValue;
begin
  LRoot := nil;
  try
    try
      LRoot := TJSONObject.ParseJSONValue(AFrame);
    except
      on E: Exception do
      begin
        _EmitError(nil, MCP_ERR_PARSE, 'parse error: ' + E.Message);
        Exit;
      end;
    end;
    // ParseJSONValue returns nil (no exception) for malformed input.
    if not Assigned(LRoot) then
    begin
      _EmitError(nil, MCP_ERR_PARSE, 'parse error: malformed JSON');
      Exit;
    end;
    if not (LRoot is TJSONObject) then
    begin
      _EmitError(nil, MCP_ERR_INVALID_REQUEST, 'request must be a JSON object');
      Exit;
    end;
    LObj := TJSONObject(LRoot);
    LIdValue := LObj.GetValue('id');
    LMethodPair := LObj.Get('method');
    if not Assigned(LMethodPair) or not (LMethodPair.JsonValue is TJSONString) then
    begin
      _EmitError(LIdValue, MCP_ERR_INVALID_REQUEST, 'missing or non-string method');
      Exit;
    end;
    LRequest.Id := LIdValue;
    LRequest.Method := TJSONString(LMethodPair.JsonValue).Value;
    LParamsValue := LObj.GetValue('params');
    if Assigned(LParamsValue) and (LParamsValue is TJSONObject) then
      LRequest.Params := TJSONObject(LParamsValue)
    else
      LRequest.Params := nil;
    try
      _DispatchMethod(LRequest);
    except
      on E: EMCPError do
        _EmitErrorFromException(LRequest.Id, E);
      on E: Exception do
        _EmitError(LRequest.Id, MCP_ERR_INTERNAL,
          'internal error: ' + E.ClassName + ': ' + E.Message);
    end;
  finally
    LRoot.Free;
  end;
end;

procedure TMCPServer._DispatchMethod(const ARequest: TMCPRequest);
begin
  if ARequest.Method = 'initialize' then
    _HandleInitialize(ARequest)
  else if ARequest.Method = 'notifications/initialized' then
    _HandleNotificationsInitialized(ARequest)
  else if ARequest.Method = 'notifications/cancelled' then
    _HandleNotificationsCancelled(ARequest)
  else if ARequest.Method = 'tools/list' then
    _HandleToolsList(ARequest)
  else if ARequest.Method = 'tools/call' then
    _HandleToolsCall(ARequest)
  else if ARequest.Method = 'resources/list' then
    _HandleResourcesList(ARequest)
  else if ARequest.Method = 'resources/read' then
    _HandleResourcesRead(ARequest)
  else if ARequest.Method = 'resources/subscribe' then
    _HandleResourcesSubscribe(ARequest)
  else if ARequest.Method = 'resources/unsubscribe' then
    _HandleResourcesUnsubscribe(ARequest)
  else
    raise EMCPMethodNotFound.Create(ARequest.Method);
end;

procedure TMCPServer._HandleNotificationsInitialized(const ARequest: TMCPRequest);
begin
  // Spec: client-side initialized notification; no response.
end;

procedure TMCPServer._HandleNotificationsCancelled(const ARequest: TMCPRequest);
var
  LRequestId: TJSONValue;
  LBuildId: string;
begin
  // RN-C02 (ADR-069): params.requestId is the build_id whose cancellation
  // token must be flipped. It is a JSON-RPC notification — no response is
  // emitted. With no cancel sink injected, this is a silent no-op; a
  // missing / malformed requestId is swallowed (a notification never errors).
  if not Assigned(FCancelSink) then
    Exit;
  if not Assigned(ARequest.Params) then
    Exit;
  LRequestId := ARequest.Params.GetValue('requestId');
  if not Assigned(LRequestId) then
    Exit;
  if LRequestId is TJSONString then
    LBuildId := TJSONString(LRequestId).Value
  else if LRequestId is TJSONNumber then
    LBuildId := TJSONNumber(LRequestId).ToString
  else
    Exit;
  if LBuildId <> '' then
    FCancelSink.RequestCancel(LBuildId);
end;

procedure TMCPServer._HandleInitialize(const ARequest: TMCPRequest);
var
  LParams: TJSONObject;
  LVersionValue: TJSONValue;
  LResult: TJSONObject;
  LCapabilities: TJSONObject;
  LToolsCap: TJSONObject;
  LResourcesCap: TJSONObject;
  LServerInfo: TJSONObject;
begin
  LParams := ARequest.Params;
  if not Assigned(LParams) then
    raise EMCPInvalidParams.Create('initialize: params required');
  LVersionValue := LParams.GetValue('protocolVersion');
  if not Assigned(LVersionValue) or not (LVersionValue is TJSONString) then
    raise EMCPInvalidParams.Create('initialize: protocolVersion missing or not a string');
  // MCP version negotiation (spec, Lifecycle): when the client requests a
  // version the server does not speak, the server MUST answer with a version
  // it DOES support — the client then proceeds or disconnects. It must NOT
  // error: erroring broke every raw stdio client newer than the pin (Claude
  // Code sends 2025-11-25 and the Desktop MCP addon failed to connect,
  // live-test 2026-07-13). The in-process 'aefos' server never surfaced this
  // because mcp-bridge.ps1 rewrites the requested version to the pin — a
  // shield an out-of-process addon exe does not have. The response below
  // always carries MCP_PROTOCOL_VERSION, which is the negotiation.
  FInitialized := True;
  LToolsCap := TJSONObject.Create;
  LToolsCap.AddPair('listChanged', TJSONBool.Create(False));
  LCapabilities := TJSONObject.Create;
  LCapabilities.AddPair('tools', LToolsCap);
  // The resources capability is present iff a registry was injected (BR-2,
  // ADR-071). The resource set is fixed, so listChanged is false.
  if Assigned(FResourceRegistry) then
  begin
    LResourcesCap := TJSONObject.Create;
    LResourcesCap.AddPair('subscribe', TJSONBool.Create(True));
    LResourcesCap.AddPair('listChanged', TJSONBool.Create(False));
    LCapabilities.AddPair('resources', LResourcesCap);
  end;
  LServerInfo := TJSONObject.Create;
  LServerInfo.AddPair('name', MCP_SERVER_NAME);
  LServerInfo.AddPair('version', FServerVersion);
  LResult := TJSONObject.Create;
  LResult.AddPair('protocolVersion', MCP_PROTOCOL_VERSION);
  LResult.AddPair('capabilities', LCapabilities);
  LResult.AddPair('serverInfo', LServerInfo);
  _EmitResult(ARequest.Id, LResult);
end;

function TMCPServer._CloneJson(const AValue: TJSONValue): TJSONValue;
begin
  if not Assigned(AValue) then
    Result := TJSONNull.Create
  else
    Result := TJSONObject.ParseJSONValue(AValue.ToJSON);
end;

function TMCPServer._BuildToolDescriptorJson(
  const ATool: TMCPToolDescriptor): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', ATool.Name);
  if ATool.Title <> '' then
    Result.AddPair('title', ATool.Title);
  if ATool.Description <> '' then
    Result.AddPair('description', ATool.Description);
  if Assigned(ATool.InputSchema) then
    Result.AddPair('inputSchema', _CloneJson(ATool.InputSchema));
  if Assigned(ATool.OutputSchema) then
    Result.AddPair('outputSchema', _CloneJson(ATool.OutputSchema));
end;

procedure TMCPServer._HandleToolsList(const ARequest: TMCPRequest);
var
  LArray: TJSONArray;
  LResult: TJSONObject;
  LIndex: Integer;
  LName: string;
  LDescriptor: TMCPToolDescriptor;
begin
  LArray := TJSONArray.Create;
  FLock.Enter;
  try
    for LIndex := 0 to FToolOrder.Count - 1 do
    begin
      LName := FToolOrder[LIndex];
      if FTools.TryGetValue(LName, LDescriptor) then
        LArray.AddElement(_BuildToolDescriptorJson(LDescriptor));
    end;
  finally
    FLock.Leave;
  end;
  // Splice the installed addon-MCP tools (namespaced) so EVERY connected
  // executor sees them, not just the CLI that had per-driver wiring.
  if Assigned(FToolGateway) then
    _AppendGatewayTools(LArray);
  LResult := TJSONObject.Create;
  LResult.AddPair('tools', LArray);
  _EmitResult(ARequest.Id, LResult);
end;

procedure TMCPServer._AppendGatewayTools(const AArray: TJSONArray);
var
  LJson: string;
  LVal: TJSONValue;
  LArr: TJSONArray;
  LIndex: Integer;
  LElem: TJSONValue;
begin
  LJson := '';
  try
    LJson := FToolGateway.ListToolsJson;
  except
    LJson := '';
  end;
  if Trim(LJson) = '' then
    Exit;
  LVal := TJSONObject.ParseJSONValue(LJson);
  try
    if LVal is TJSONArray then
    begin
      LArr := TJSONArray(LVal);
      for LIndex := 0 to LArr.Count - 1 do
      begin
        LElem := LArr.Items[LIndex];
        if LElem is TJSONObject then
          AArray.AddElement(_CloneJson(LElem));
      end;
    end;
  finally
    LVal.Free;
  end;
end;

function TMCPServer._JsonTypeMatches(const AExpectedType: string;
  const AValue: TJSONValue): Boolean;
begin
  if AExpectedType = 'string' then
    Result := AValue is TJSONString
  else if AExpectedType = 'integer' then
    Result := AValue is TJSONNumber
  else if AExpectedType = 'object' then
    Result := AValue is TJSONObject
  else
    Result := True;
end;

function TMCPServer._CheckRequiredFields(const AArgs: TJSONObject;
  const ASchema: TJSONObject; out AMessage: string): Boolean;
var
  LRequiredValue: TJSONValue;
  LRequired: TJSONArray;
  LIndex: Integer;
  LFieldName: string;
begin
  Result := True;
  AMessage := '';
  LRequiredValue := ASchema.GetValue('required');
  if not (LRequiredValue is TJSONArray) then
    Exit;
  LRequired := TJSONArray(LRequiredValue);
  for LIndex := 0 to LRequired.Count - 1 do
  begin
    if not (LRequired.Items[LIndex] is TJSONString) then
      Continue;
    LFieldName := TJSONString(LRequired.Items[LIndex]).Value;
    if not Assigned(AArgs) or not Assigned(AArgs.GetValue(LFieldName)) then
    begin
      Result := False;
      AMessage := 'missing required field: ' + LFieldName;
      Exit;
    end;
  end;
end;

function TMCPServer._CheckPropertyTypes(const AArgs: TJSONObject;
  const ASchema: TJSONObject; out AMessage: string): Boolean;
var
  LPropsValue: TJSONValue;
  LProps: TJSONObject;
  LPropPair: TJSONPair;
  LExpectedType: string;
  LTypeValue: TJSONValue;
  LActualValue: TJSONValue;
begin
  Result := True;
  AMessage := '';
  LPropsValue := ASchema.GetValue('properties');
  if not (LPropsValue is TJSONObject) or not Assigned(AArgs) then
    Exit;
  LProps := TJSONObject(LPropsValue);
  for LPropPair in LProps do
  begin
    if not (LPropPair.JsonValue is TJSONObject) then
      Continue;
    LExpectedType := '';
    LTypeValue := TJSONObject(LPropPair.JsonValue).GetValue('type');
    if LTypeValue is TJSONString then
      LExpectedType := TJSONString(LTypeValue).Value;
    LActualValue := AArgs.GetValue(LPropPair.JsonString.Value);
    if not Assigned(LActualValue) then
      Continue;
    if not _JsonTypeMatches(LExpectedType, LActualValue) then
    begin
      Result := False;
      AMessage := 'field ' + LPropPair.JsonString.Value +
        ' must be ' + LExpectedType;
      Exit;
    end;
  end;
end;

function TMCPServer._ValidateAgainstSchema(const AArgs: TJSONObject;
  const ASchema: TJSONObject; out AMessage: string): Boolean;
begin
  Result := True;
  AMessage := '';
  if not Assigned(ASchema) then
    Exit;
  Result := _CheckRequiredFields(AArgs, ASchema, AMessage) and
            _CheckPropertyTypes(AArgs, ASchema, AMessage);
end;

function TMCPServer._ApplyBudget(const AResult: TMCPToolResult): TMCPToolResult;
var
  LBytes: TBytes;
  LSafe: Integer;
begin
  Result := AResult;
  LBytes := TEncoding.UTF8.GetBytes(Result.Content);
  if Length(LBytes) > MCP_TOOL_RESULT_BUDGET then
  begin
    // R1: recede to a UTF-8 boundary so a split multibyte char cannot make GetString raise.
    LSafe := TMCPUtf8Utils.SafeLen(LBytes, 0, MCP_TOOL_RESULT_BUDGET);
    Result.Content := TEncoding.UTF8.GetString(LBytes, 0, LSafe);
    if not Result.HasMore then
      Result.HasMore := True;
  end;
end;

procedure TMCPServer._HandleToolsCall(const ARequest: TMCPRequest);
var
  LParams: TJSONObject;
  LNameValue: TJSONValue;
  LName: string;
  LArgsValue: TJSONValue;
  LArgs: TJSONObject;
  LDescriptor: TMCPToolDescriptor;
  LValidation: string;
  LIntent, LCurrentView: TMCPToolIntent;
  LViewRead: TMarshalledViewRead;
  LWrongView: string;
  LResult: TMCPToolResult;
  LResultJson: TJSONObject;
  LContentArray: TJSONArray;
  LContentItem: TJSONObject;
  LImageItem: TJSONObject;
  LNextItem: TJSONObject;
  LNextHint: string;
  LStructured: TJSONObject;
begin
  LParams := ARequest.Params;
  if not Assigned(LParams) then
    raise EMCPInvalidParams.Create('tools/call: params required');
  LNameValue := LParams.GetValue('name');
  if not Assigned(LNameValue) or not (LNameValue is TJSONString) then
    raise EMCPInvalidParams.Create('tools/call: name missing or not a string');
  LName := TJSONString(LNameValue).Value;
  // Addon-MCP routing (ESP): a namespaced tool belongs to a spawned addon child.
  // Route it there and return the child's raw result verbatim. Runs BEFORE the
  // OTA tool lookup and the RULE #1 view guard — addon tools are view-neutral and
  // their own consent runs inside the child.
  if Assigned(FToolGateway) and FToolGateway.OwnsTool(LName) then
  begin
    _HandleAddonToolCall(ARequest, LName, LParams);
    Exit;
  end;
  FLock.Enter;
  try
    if not FTools.TryGetValue(LName, LDescriptor) then
      raise EMCPMethodNotFound.Create('tool: ' + LName);
  finally
    FLock.Leave;
  end;
  LArgsValue := LParams.GetValue('arguments');
  if Assigned(LArgsValue) and (LArgsValue is TJSONObject) then
    LArgs := TJSONObject(LArgsValue)
  else
    LArgs := nil;
  if not _ValidateAgainstSchema(LArgs, LDescriptor.InputSchema, LValidation) then
    raise EMCPInvalidParams.Create(LValidation);
  // RULE #1 guard (CLAUDE.md): reject a design/code command sent while the IDE
  // shows the wrong view, BEFORE the handler mutates anything — each command is
  // its own guardian. The view read touches OTA, so it runs on the main thread
  // via FMarshal. No provider (tests / no OTA host) => guard is off.
  if Assigned(FViewProvider) then
  begin
    LIntent := LDescriptor.Intent;
    if LIntent <> tiNeutral then
    begin
      // FMarshal is synchronous: the carrier's result is written before the
      // call returns, and the per-call instance keeps concurrent clients from
      // clobbering each other's read. RULE #1's own principle: never block —
      // and so never crash — on an uncertain view read.
      LViewRead := TMarshalledViewRead.Create(FViewProvider);
      try
        FMarshal(LViewRead.Run);
        LCurrentView := LViewRead.View;
      finally
        LViewRead.Free;
      end;
      LWrongView := TIntentGuard.WrongViewReason(LIntent, LCurrentView);
      if LWrongView <> '' then
        raise EMCPWrongView.Create(
          LWrongView + ': ' + TIntentGuard.WrongViewMessage(LWrongView));
    end;
  end;
  LResult := LDescriptor.Handler(LArgs, Self);
  LResult := _ApplyBudget(LResult);
  LStructured := TJSONObject.Create;
  LStructured.AddPair('content', LResult.Content);
  LStructured.AddPair('has_more', TJSONBool.Create(LResult.HasMore));
  if LResult.NextCursor = '' then
    LStructured.AddPair('next_cursor', TJSONNull.Create)
  else
    LStructured.AddPair('next_cursor', LResult.NextCursor);
  // content_hash is emitted only by tools that produce one (ADR-060).
  if LResult.ContentHash <> '' then
    LStructured.AddPair('content_hash', LResult.ContentHash);
  LContentItem := TJSONObject.Create;
  LContentItem.AddPair('type', 'text');
  LContentItem.AddPair('text', LResult.Content);
  LContentArray := TJSONArray.Create;
  LContentArray.AddElement(LContentItem);
  // Agent vision: when a tool captured a picture (e.g. CaptureForm), append an
  // MCP `image` content block so a vision-capable model literally SEES it.
  if LResult.ImageBase64 <> '' then
  begin
    LImageItem := TJSONObject.Create;
    LImageItem.AddPair('type', 'image');
    LImageItem.AddPair('data', LResult.ImageBase64);
    LImageItem.AddPair('mimeType', LResult.ImageMimeType);
    LContentArray.AddElement(LImageItem);
  end;
  // FlowGuide advisory next-prompt (the loop's GUIDE half): on success, append a terse
  // hint conducting the agent to the natural next step of the Design<->Code flow. Added
  // as an extra content text item (so the agent reads it) and mirrored in structuredContent.
  // '' for most tools => nothing added; advisory, never enforcing.
  LNextHint := TFlowGuide.NextPromptFor(LName);
  if LNextHint <> '' then
  begin
    LNextItem := TJSONObject.Create;
    LNextItem.AddPair('type', 'text');
    LNextItem.AddPair('text', LNextHint);
    LContentArray.AddElement(LNextItem);
    LStructured.AddPair('next', LNextHint);
  end;
  LResultJson := TJSONObject.Create;
  LResultJson.AddPair('content', LContentArray);
  LResultJson.AddPair('structuredContent', LStructured);
  LResultJson.AddPair('isError', TJSONBool.Create(False));
  _EmitResult(ARequest.Id, LResultJson);
end;

procedure TMCPServer._HandleAddonToolCall(const ARequest: TMCPRequest;
  const AName: string; const AParams: TJSONObject);
var
  LArgsValue: TJSONValue;
  LArgsJson, LRaw: string;
  LResult: TJSONValue;
  LFallback: TJSONObject;
  LContentArr: TJSONArray;
  LItem: TJSONObject;
begin
  // Extract the caller's `arguments` object as raw JSON for the child.
  LArgsValue := nil;
  if Assigned(AParams) then
    LArgsValue := AParams.GetValue('arguments');
  if Assigned(LArgsValue) and (LArgsValue is TJSONObject) then
    LArgsJson := LArgsValue.ToJSON
  else
    LArgsJson := '{}';
  LRaw := '';
  try
    LRaw := FToolGateway.CallTool(AName, LArgsJson);
  except
    LRaw := '';
  end;
  LResult := nil;
  if LRaw <> '' then
    LResult := TJSONObject.ParseJSONValue(LRaw);
  if not (LResult is TJSONObject) then
  begin
    LResult.Free; // nil-safe
    // Synthesize an isError result so the agent always gets feedback, never a
    // dead call (the addon child failed to answer or returned junk).
    LItem := TJSONObject.Create;
    LItem.AddPair('type', 'text');
    LItem.AddPair('text', 'Aefos addon tool "' + AName +
      '" is unavailable (the addon server did not respond).');
    LContentArr := TJSONArray.Create;
    LContentArr.AddElement(LItem);
    LFallback := TJSONObject.Create;
    LFallback.AddPair('content', LContentArr);
    LFallback.AddPair('isError', TJSONBool.Create(True));
    LResult := LFallback;
  end;
  // Report the call to whoever is watching, BEFORE the result leaves. The tool
  // has already run and its result is already decided, so this cannot change the
  // answer -- and it is wrapped because a drawing concern must never be able to
  // fail a tool call. That is the whole reason it sits here rather than inside
  // the gateway: the gateway's job is routing, and a UI that can break routing
  // is a UI that takes the tools down with it.
  if Assigned(FVisualReport) then
    try
      FVisualReport(AName, LArgsJson, LRaw, LRaw = '');
    except
      // swallowed on purpose; see above
    end;
  // _EmitResult takes ownership of LResult (frees it with the frame).
  _EmitResult(ARequest.Id, LResult);
end;

procedure TMCPServer._RequireRegistry(const AMethod: string);
begin
  // No registry injected → the resources capability is simply absent (BR-2).
  if not Assigned(FResourceRegistry) then
    raise EMCPMethodNotFound.Create(AMethod);
end;

function TMCPServer._ReadRequiredUri(const ARequest: TMCPRequest): string;
var
  LUriValue: TJSONValue;
begin
  if not Assigned(ARequest.Params) then
    raise EMCPInvalidParams.Create('params required');
  LUriValue := ARequest.Params.GetValue('uri');
  if not Assigned(LUriValue) or not (LUriValue is TJSONString) then
    raise EMCPInvalidParams.Create('uri missing or not a string');
  Result := TJSONString(LUriValue).Value;
end;

function TMCPServer._IsSubscribed(const AUri: string): Boolean;
begin
  FSubLock.Enter;
  try
    Result := FSubscriptions.ContainsKey(AUri);
  finally
    FSubLock.Leave;
  end;
end;

procedure TMCPServer._HandleResourcesList(const ARequest: TMCPRequest);
var
  LArray: TJSONArray;
  LResult: TJSONObject;
  LDescriptor: TMCPResourceDescriptor;
  LItem: TJSONObject;
begin
  _RequireRegistry(ARequest.Method);
  LArray := TJSONArray.Create;
  for LDescriptor in FResourceRegistry.List do
  begin
    LItem := TJSONObject.Create;
    LItem.AddPair('uri', LDescriptor.Uri);
    LItem.AddPair('name', LDescriptor.Name);
    LItem.AddPair('mimeType', LDescriptor.MimeType);
    LArray.AddElement(LItem);
  end;
  LResult := TJSONObject.Create;
  LResult.AddPair('resources', LArray);
  _EmitResult(ARequest.Id, LResult);
end;

procedure TMCPServer._HandleResourcesRead(const ARequest: TMCPRequest);
var
  LUri: string;
  LDescriptor: TMCPResourceDescriptor;
  LRaw: TMCPToolResult;
  LContents: TJSONArray;
  LContentItem: TJSONObject;
  LResult: TJSONObject;
begin
  _RequireRegistry(ARequest.Method);
  LUri := _ReadRequiredUri(ARequest);
  if not FResourceRegistry.TryGet(LUri, LDescriptor) then
    raise EMCPResourceNotFound.Create(LUri);
  // The provider returns the live content; over-budget text is truncated
  // through the same path as tool results (ADR-058 / OQ-1).
  LRaw := Default(TMCPToolResult);
  if Assigned(LDescriptor.Provider) then
    LRaw.Content := LDescriptor.Provider();
  LRaw := _ApplyBudget(LRaw);
  LContentItem := TJSONObject.Create;
  LContentItem.AddPair('uri', LUri);
  LContentItem.AddPair('mimeType', LDescriptor.MimeType);
  LContentItem.AddPair('text', LRaw.Content);
  LContents := TJSONArray.Create;
  LContents.AddElement(LContentItem);
  LResult := TJSONObject.Create;
  LResult.AddPair('contents', LContents);
  _EmitResult(ARequest.Id, LResult);
end;

procedure TMCPServer._HandleResourcesSubscribe(const ARequest: TMCPRequest);
var
  LUri: string;
  LDescriptor: TMCPResourceDescriptor;
begin
  _RequireRegistry(ARequest.Method);
  LUri := _ReadRequiredUri(ARequest);
  if not FResourceRegistry.TryGet(LUri, LDescriptor) then
    raise EMCPResourceNotFound.Create(LUri);
  FSubLock.Enter;
  try
    FSubscriptions.AddOrSetValue(LUri, True);
  finally
    FSubLock.Leave;
  end;
  _EmitResult(ARequest.Id, TJSONObject.Create);
end;

procedure TMCPServer._HandleResourcesUnsubscribe(const ARequest: TMCPRequest);
var
  LUri: string;
begin
  _RequireRegistry(ARequest.Method);
  LUri := _ReadRequiredUri(ARequest);
  // Idempotent: unsubscribing a non-subscribed URI is a silent success.
  FSubLock.Enter;
  try
    FSubscriptions.Remove(LUri);
  finally
    FSubLock.Leave;
  end;
  _EmitResult(ARequest.Id, TJSONObject.Create);
end;

procedure TMCPServer._EmitNotification(const AMethod: string;
  const AParams: TJSONObject);
var
  LFrame: TJSONObject;
begin
  // A JSON-RPC notification: method + params, no id, no result/error (BR-7).
  LFrame := TJSONObject.Create;
  try
    LFrame.AddPair('jsonrpc', '2.0');
    LFrame.AddPair('method', AMethod);
    LFrame.AddPair('params', AParams);
    if Assigned(FTransport) then
      FTransport.Send(LFrame.ToJSON);
  finally
    LFrame.Free;
  end;
end;

procedure TMCPServer.NotifyResourceUpdated(const AUri: string);
var
  LParams: TJSONObject;
begin
  // Subscription-filtered (BR-6, ADR-073): the server never pushes an
  // unsolicited resource update — an unsubscribed URI is a silent no-op.
  if not _IsSubscribed(AUri) then
    Exit;
  LParams := TJSONObject.Create;
  LParams.AddPair('uri', AUri);
  _EmitNotification('notifications/resources/updated', LParams);
end;

procedure TMCPServer._EmitResult(const AId: TJSONValue;
  const AResult: TJSONValue);
var
  LFrame: TJSONObject;
begin
  LFrame := TJSONObject.Create;
  try
    LFrame.AddPair('jsonrpc', '2.0');
    if Assigned(AId) then
      LFrame.AddPair('id', _CloneJson(AId))
    else
      LFrame.AddPair('id', TJSONNull.Create);
    LFrame.AddPair('result', AResult);
    if Assigned(FTransport) then
      FTransport.Send(LFrame.ToJSON);
  finally
    LFrame.Free;
  end;
end;

procedure TMCPServer._EmitError(const AId: TJSONValue; const ACode: Integer;
  const AMessage: string);
var
  LFrame: TJSONObject;
  LError: TJSONObject;
begin
  LFrame := TJSONObject.Create;
  try
    LFrame.AddPair('jsonrpc', '2.0');
    if Assigned(AId) then
      LFrame.AddPair('id', _CloneJson(AId))
    else
      LFrame.AddPair('id', TJSONNull.Create);
    LError := TJSONObject.Create;
    LError.AddPair('code', TJSONNumber.Create(ACode));
    LError.AddPair('message', AMessage);
    LFrame.AddPair('error', LError);
    if Assigned(FTransport) then
      FTransport.Send(LFrame.ToJSON);
  finally
    LFrame.Free;
  end;
end;

procedure TMCPServer._EmitErrorFromException(const AId: TJSONValue;
  const AException: Exception);
var
  LCode: Integer;
begin
  if AException is EMCPError then
    LCode := EMCPError(AException).Code
  else
    LCode := MCP_ERR_INTERNAL;
  _EmitError(AId, LCode, AException.Message);
end;

end.
