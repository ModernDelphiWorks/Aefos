unit Aefos.MCP.Tools.ChatInspector;

(*
  WebView2 chat-panel inspection MCP tools (ESP-002, Epic 2/3 Demand 1/5;
  ADR-215/ADR-216/ADR-217). RTL-only — depends only on the
  IMCPChatInspectorFacade seam (Aefos.MCP.ChatInspector.Types); the
  WebView2-touching implementation lives in the plugin BPL (C-1,
  Tests.MCPPackageBoundary).

  Two tools (tools/list 115 -> 117):

    - GetChatPanelHTML   ({})              read-only (ADR-217 / BR-1)
        Returns { "html": <decoded DOM> } or { "error": <reason> }. No
        consent, no audit.

    - EvalChatPanelScript ({ script })     consent-gated (ADR-217 / BR-2)
        Routes through the consent registry at the SAME destructive-action
        risk class as EditUnit/DeleteUnit. A denied consent returns the
        standard denied result (-32003) and NEVER executes the script.
        On approval returns { "result": <WebView2 JSON, verbatim> } or
        { "error": <reason> }. Each invocation appends one audit-log line
        (applied / failed / denied) so QueryAuditLog can surface it — the
        unit "reuses the audited destructive-action path" (ADR-217).

  Threading (ADR-216): the eval/get facade calls own their async->sync bridge
  (main-thread marshal + bounded TEvent wait) internally, so the handlers call
  the facade directly on the worker thread WITHOUT IMCPToolContext marshalling
  — unlike the OTA tools. Only the consent modal (RequestConsent) is marshalled
  to the IDE main thread here, mirroring TMCPToolsRegistrar._RequestGate.

  Structured errors (BR-3): a no-panel / not-initialized / script-error /
  timeout condition is reported by the facade as Result=False + reason and is
  surfaced as { "error": reason } content — never raised, never hung.
*)

interface

uses
  Aefos.MCP.Server,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.ChatInspector.Types;

// Registers GetChatPanelHTML + EvalChatPanelScript against AServer, wiring the
// supplied WebView2 facade. A session-scoped consent registry and audit log
// are created internally (production wiring).
procedure RegisterChatInspectorTools(const AServer: IMCPServer;
  const AFacade: IMCPChatInspectorFacade); overload;
// Test seam: inject a caller-owned consent registry + audit log so DUnit can
// drive the gate deterministically and assert the audit trail.
procedure RegisterChatInspectorTools(const AServer: IMCPServer;
  const AFacade: IMCPChatInspectorFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils,
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.Tools.Common;

const
  CToolGetHtml = 'GetChatPanelHTML';
  CToolEval    = 'EvalChatPanelScript';
  // The audit `args` summary is capped so an arbitrarily long script does not
  // bloat the JSONL line; the full script is never persisted (R-2).
  CAuditArgsMax = 200;

type
  IMCPChatInspectorDispatch = interface
    ['{2B9F4D17-6C81-4A3E-9D52-7F0A3E5C1B84}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleGetHtml(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleEval(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

// ── Param + token helpers ──────────────────────────────────────────────────

// Extracts a required string parameter; raises -32602 when absent/non-string.
function _RequiredStr(const AParams: TJSONObject; const AName: string): string;
var
  LValue: TJSONValue;
begin
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create(CToolEval + ': arguments required');
  LValue := AParams.GetValue(AName);
  if not (Assigned(LValue) and (LValue is TJSONString)) then
    raise EMCPInvalidParams.Create(AName + ' required (string)');
  Result := TJSONString(LValue).Value;
end;

// Audit `consent` token (ADR-067 vocabulary, shared with the OTA tools).
// Audit `outcome` token — aligned with QueryAuditLog's status enum
// (applied | denied | failed) so the smoke harness can filter on it.
function _OutcomeToken(const ASucceeded: Boolean): string;
begin
  if ASucceeded then
    Result := 'applied'
  else
    Result := 'failed';
end;

// One-line, length-capped script summary for the audit `args` field.
function _ArgsSummary(const AScript: string): string;
begin
  Result := StringReplace(AScript, sLineBreak, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  if Length(Result) > CAuditArgsMax then
    Result := Copy(Result, 1, CAuditArgsMax) + '...';
end;

// ── Result builders ────────────────────────────────────────────────────────

// { "<AKey>": <AValue> } as the tool result content.
function _StringResult(const AKey, AValue: string): TMCPToolResult;
var
  LRoot: TJSONObject;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair(AKey, AValue);
    Result := TMCPToolResult.Text(LRoot.ToJSON);
  finally
    LRoot.Free;
  end;
end;

// { "error": <AReason> } — the structured-error envelope (BR-3).
function _ErrorResult(const AReason: string): TMCPToolResult;
begin
  Result := _StringResult('error', AReason);
end;

// { "result": <AResultJson parsed verbatim, or string fallback> } (A-2/BR-5).
function _EvalResult(const AResultJson: string): TMCPToolResult;
var
  LRoot: TJSONObject;
  LValue: TJSONValue;
begin
  LRoot := TJSONObject.Create;
  try
    if Trim(AResultJson) = '' then
      LRoot.AddPair('result', TJSONNull.Create)
    else
    begin
      LValue := TJSONObject.ParseJSONValue(AResultJson);
      if Assigned(LValue) then
        LRoot.AddPair('result', LValue)            // ownership transferred
      else
        LRoot.AddPair('result', AResultJson);      // not JSON → raw string
    end;
    Result := TMCPToolResult.Text(LRoot.ToJSON);
  finally
    LRoot.Free;
  end;
end;

// ── Schema builders ─────────────────────────────────────────────────────────

function _StrProp(const ADesc: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'string');
  Result.AddPair('description', ADesc);
end;

function _EmptyInputSchema: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

function _EvalInputSchema: TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LProps.AddPair('script',
    _StrProp('JavaScript expression to evaluate in the chat panel WebView2. '
      + 'Its result is returned as WebView2 JSON. Consent-gated.'));
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('script');
  Result.AddPair('required', LRequired);
end;

function _GetHtmlOutputSchema: TJSONObject;
var
  LProps: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LProps.AddPair('html', _StrProp('Rendered DOM (document.documentElement.outerHTML).'));
  LProps.AddPair('error', _StrProp('Structured failure reason when html is absent.'));
  Result.AddPair('properties', LProps);
end;

function _EvalOutputSchema: TJSONObject;
var
  LProps: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LProps.AddPair('result', _StrProp('WebView2 JSON result of the script (verbatim).'));
  LProps.AddPair('error', _StrProp('Structured failure reason when result is absent.'));
  Result.AddPair('properties', LProps);
end;

// ── Registrar ────────────────────────────────────────────────────────────────

type
  TMCPChatInspectorRegistrar = class(TInterfacedObject, IMCPChatInspectorDispatch)
  private
    FFacade: IMCPChatInspectorFacade;
    FConsentRegistry: IMCPConsentRegistry;
    FAuditLog: IMCPAuditLog;
    function _RequestGate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    function _HandleGetHtml(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleEval(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function IMCPChatInspectorDispatch.HandleGetHtml = _HandleGetHtml;
    function IMCPChatInspectorDispatch.HandleEval = _HandleEval;
    function _BuildGetHtmlDescriptor: TMCPToolDescriptor;
    function _BuildEvalDescriptor: TMCPToolDescriptor;
  public
    constructor Create(const AFacade: IMCPChatInspectorFacade;
      const AConsentRegistry: IMCPConsentRegistry = nil;
      const AAuditLog: IMCPAuditLog = nil);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPChatInspectorRegistrar.Create(
  const AFacade: IMCPChatInspectorFacade;
  const AConsentRegistry: IMCPConsentRegistry; const AAuditLog: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TMCPChatInspectorRegistrar: AFacade');
  FFacade := AFacade;
  // Session-scoped collaborators: one per registrar, alive for the server's
  // lifetime via the handler-closure Self reference (ADR-056), or injected
  // by tests.
  if Assigned(AConsentRegistry) then
    FConsentRegistry := AConsentRegistry
  else
    FConsentRegistry := TMCPConsentRegistry.Create;
  if Assigned(AAuditLog) then
    FAuditLog := AAuditLog
  else
    FAuditLog := TMCPAuditLog.Create;
end;

// Destructive-action gate (ADR-064/217). A live session grant skips the modal;
// otherwise RequestConsent is marshalled to the IDE main thread and an "allow
// for this session" answer is recorded. Mirrors TMCPToolsRegistrar._RequestGate.
function TMCPChatInspectorRegistrar._RequestGate(const AContext: IMCPToolContext;
  const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
var
  LDecision: TMCPConsentDecision;
begin
  if FConsentRegistry.IsSessionAllowed(AToolName) then
    Exit(cdAllowSession);
  LDecision := cdDenied;
  AContext.MarshalToMainThread(
    procedure
    begin
      LDecision := FFacade.RequestConsent(AToolName, ASummary, ADetail);
    end);
  if LDecision = cdAllowSession then
    FConsentRegistry.GrantSession(AToolName);
  Result := LDecision;
end;

function TMCPChatInspectorRegistrar._HandleGetHtml(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LHtml, LError: string;
begin
  // Read-only (BR-1): no consent, no audit. The facade owns the async->sync
  // WebView2 bridge (ADR-216), so no IMCPToolContext marshalling here.
  if FFacade.GetRenderedHtml(LHtml, LError) then
    Result := _StringResult('html', LHtml)
  else
    Result := _ErrorResult(LError);
end;

function TMCPChatInspectorRegistrar._HandleEval(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LScript, LResultJson, LError: string;
  LDecision: TMCPConsentDecision;
  LOk: Boolean;
begin
  LScript := _RequiredStr(AParams, 'script');
  LDecision := _RequestGate(AContext, CToolEval,
    'Run this JavaScript in the chat panel WebView2:', LScript);
  if LDecision = cdDenied then
  begin
    FAuditLog.Append(CToolEval, _ArgsSummary(LScript), 'denied', 'denied');
    raise EMCPUserDenied.Create(CToolEval + ': user denied the action');
  end;
  LOk := FFacade.EvalScript(LScript, LResultJson, LError);
  FAuditLog.Append(CToolEval, _ArgsSummary(LScript), TMCPConsentToken.Token(LDecision),
    _OutcomeToken(LOk));
  if LOk then
    Result := _EvalResult(LResultJson)
  else
    Result := _ErrorResult(LError);
end;

function TMCPChatInspectorRegistrar._BuildGetHtmlDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPChatInspectorDispatch;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    CToolGetHtml,
    'Get chat panel HTML',
    'Returns the rendered DOM (document.documentElement.outerHTML) of the '
    + 'Aefos chat panel WebView2 as { html }. Read-only — never prompts '
    + 'for consent. Returns { error } (no-panel / not-initialized / timeout) '
    + 'when the panel is not open or the WebView2 runtime is not ready.',
    _EmptyInputSchema,
    _GetHtmlOutputSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetHtml(AParams, AContext);
    end);
end;

function TMCPChatInspectorRegistrar._BuildEvalDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPChatInspectorDispatch;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    CToolEval,
    'Eval chat panel script',
    'Evaluates a JavaScript expression in the Aefos chat panel WebView2 '
    + 'and returns its result as { result } (WebView2 JSON, verbatim). '
    + 'State-changing: the first call this session shows a confirmation modal '
    + '(same destructive-action gate as EditUnit/DeleteUnit) and returns '
    + '-32003 if denied — a denied call never executes the script. Returns '
    + '{ error } (no-panel / not-initialized / script-error / timeout) on '
    + 'failure. Audited in mcp-audit-YYYY-MM-DD.jsonl.',
    _EvalInputSchema,
    _EvalOutputSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleEval(AParams, AContext);
    end);
end;

procedure TMCPChatInspectorRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPChatInspectorRegistrar.RegisterAll: AServer');
  AServer.RegisterTool(_BuildGetHtmlDescriptor);
  AServer.RegisterTool(_BuildEvalDescriptor);
end;

procedure RegisterChatInspectorTools(const AServer: IMCPServer;
  const AFacade: IMCPChatInspectorFacade);
var
  LRegistrar: IMCPChatInspectorDispatch;
begin
  LRegistrar := TMCPChatInspectorRegistrar.Create(AFacade);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterChatInspectorTools(const AServer: IMCPServer;
  const AFacade: IMCPChatInspectorFacade;
  const AConsentRegistry: IMCPConsentRegistry; const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPChatInspectorDispatch;
begin
  LRegistrar := TMCPChatInspectorRegistrar.Create(AFacade, AConsentRegistry,
    AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

end.
