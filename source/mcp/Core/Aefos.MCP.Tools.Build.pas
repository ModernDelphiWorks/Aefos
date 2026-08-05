unit Aefos.MCP.Tools.Build;

(*
  Build-group MCP tools (ESP-002, Epic 7/7 Demand 5/8).

  Catalog rows: docs/mcp-catalog/catalog.json — group "Build",
  verdict "new". 13 tools (3 reads + 10 consent-gated writes/runtime).
  Three sibling rows (BuildProject, CompileProject, GetBuildErrors)
  carry verdict "dedup" and are NOT registered here.

  Layering (ADR-115 / ADR-136):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterBuildTools(AServer, AFacade) called from
      MCP.Server's bootstrap after the Editor-group registration.

  Gating (BR-2, ADR-136):
    - Reads (GetSearchPath, GetConditionalDefines, GetDCUOutputDir): direct
      facade call, no consent.
    - Writes / runtime (10): TMCPConsentRegistry.RequireConsent, risk Low,
      EMCPUserDenied on denial.

  Validation (ESP AC-07/AC-10):
    - AddToSearchPath rejects empty path with -32602 reason `empty-path`.
    - AddConditionalDefine rejects names containing whitespace or `=` with
      -32602 reason `invalid-define`.

  Runtime dedup (ADR-137):
    - RunProject / RunWithoutDebugger return False with structured detail
      reason `already-running` when the facade's runtime is already active.
    - StopProject is idempotent — `applied:true` whether or not a process
      was running.
*)

interface

uses
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.Server;

type
  // Dispatch surface for the Build-group tool handlers. Each tool-handler
  // closure captures an IMCPBuildToolsRegistrar reference so the registrar
  // (and its consent/audit collaborators) is reference-counted alive for
  // the server's lifetime - mirrors the Project / Units / Editor pattern.
  IMCPBuildToolsRegistrar = interface
    ['{A1B2C3D4-5E6F-4708-9C1D-3E5F7A9B2D40}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleGetSearchPath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetSearchPath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleAddToSearchPath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetConditionalDefines(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetConditionalDefines(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleAddConditionalDefine(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRemoveConditionalDefine(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetDCUOutputDir(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetDCUOutputDir(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleCleanProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRunProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRunWithoutDebugger(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleStopProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

procedure RegisterBuildTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterBuildTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils,
  Aefos.MCP.Tools.Common;

type
  TMCPBuildToolsRegistrar = class(TMCPToolsRegistrarBase, IMCPBuildToolsRegistrar)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsentRegistry: IMCPConsentRegistry;
    FAuditLog: IMCPAuditLog;
    // Descriptor builders — one per Build tool (13 total).
    function _BuildGetSearchPath: TMCPToolDescriptor;
    function _BuildSetSearchPath: TMCPToolDescriptor;
    function _BuildAddToSearchPath: TMCPToolDescriptor;
    function _BuildGetConditionalDefines: TMCPToolDescriptor;
    function _BuildSetConditionalDefines: TMCPToolDescriptor;
    function _BuildAddConditionalDefine: TMCPToolDescriptor;
    function _BuildRemoveConditionalDefine: TMCPToolDescriptor;
    function _BuildGetDCUOutputDir: TMCPToolDescriptor;
    function _BuildSetDCUOutputDir: TMCPToolDescriptor;
    function _BuildCleanProject: TMCPToolDescriptor;
    function _BuildRunProject: TMCPToolDescriptor;
    function _BuildRunWithoutDebugger: TMCPToolDescriptor;
    function _BuildStopProject: TMCPToolDescriptor;
    function _BuildStopRunningApp: TMCPToolDescriptor;
    // Handlers.
    function _HandleGetSearchPath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetSearchPath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddToSearchPath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetConditionalDefines(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetConditionalDefines(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddConditionalDefine(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRemoveConditionalDefine(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetDCUOutputDir(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetDCUOutputDir(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleCleanProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRunProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRunWithoutDebugger(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleStopProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Helpers.
    function _ReadStringArray(const AParams: TJSONObject;
      const AName: string): TArray<string>;
    function _StringResult(const AValue: string): TMCPToolResult;
    function _StringArrayResult(
      const AValues: TArray<string>): TMCPToolResult;
    function _AppliedResult(const AApplied: Boolean): TMCPToolResult;
    function _RequestGate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    procedure _AuditDenied(const AToolName, AArgs: string);
    procedure _AuditApplied(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    procedure _AuditFailed(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    function _RunLifecycle(const AContext: IMCPToolContext;
      const AToolName, ASummary: string;
      const AInvoke: TFunc<Boolean>): TMCPToolResult;
    // IMCPBuildToolsRegistrar dispatch maps.
    function IMCPBuildToolsRegistrar.HandleGetSearchPath = _HandleGetSearchPath;
    function IMCPBuildToolsRegistrar.HandleSetSearchPath = _HandleSetSearchPath;
    function IMCPBuildToolsRegistrar.HandleAddToSearchPath = _HandleAddToSearchPath;
    function IMCPBuildToolsRegistrar.HandleGetConditionalDefines = _HandleGetConditionalDefines;
    function IMCPBuildToolsRegistrar.HandleSetConditionalDefines = _HandleSetConditionalDefines;
    function IMCPBuildToolsRegistrar.HandleAddConditionalDefine = _HandleAddConditionalDefine;
    function IMCPBuildToolsRegistrar.HandleRemoveConditionalDefine = _HandleRemoveConditionalDefine;
    function IMCPBuildToolsRegistrar.HandleGetDCUOutputDir = _HandleGetDCUOutputDir;
    function IMCPBuildToolsRegistrar.HandleSetDCUOutputDir = _HandleSetDCUOutputDir;
    function IMCPBuildToolsRegistrar.HandleCleanProject = _HandleCleanProject;
    function IMCPBuildToolsRegistrar.HandleRunProject = _HandleRunProject;
    function IMCPBuildToolsRegistrar.HandleRunWithoutDebugger = _HandleRunWithoutDebugger;
    function IMCPBuildToolsRegistrar.HandleStopProject = _HandleStopProject;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsentRegistry: IMCPConsentRegistry;
      const AAuditLog: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

// ── Schema builders ───────────────────────────────────────────────────

function _MakeEmptyInputSchema: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

function _MakeStringResultSchema: TJSONObject;
var
  LProps, LValue: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'string');
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function _MakeStringArrayResultSchema: TJSONObject;
var
  LProps, LValue, LItems: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItems := TJSONObject.Create;
  LItems.AddPair('type', 'string');
  LValue.AddPair('items', LItems);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function _MakeAppliedSchema: TJSONObject;
var
  LProps, LApplied: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LApplied := TJSONObject.Create;
  LApplied.AddPair('type', 'boolean');
  LProps.AddPair('applied', LApplied);
  Result.AddPair('properties', LProps);
end;

function _MakeOneStringParamSchema(const AName, ADesc: string): TJSONObject;
var
  LProps, LProp: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LProp := TJSONObject.Create;
  LProp.AddPair('type', 'string');
  LProp.AddPair('description', ADesc);
  LProps.AddPair(AName, LProp);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add(AName);
  Result.AddPair('required', LRequired);
end;

function _MakeStringArrayParamSchema(const AName, ADesc: string): TJSONObject;
var
  LProps, LProp, LItems: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LProp := TJSONObject.Create;
  LProp.AddPair('type', 'array');
  LItems := TJSONObject.Create;
  LItems.AddPair('type', 'string');
  LProp.AddPair('items', LItems);
  LProp.AddPair('description', ADesc);
  LProps.AddPair(AName, LProp);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add(AName);
  Result.AddPair('required', LRequired);
end;

{ TMCPBuildToolsRegistrar }

constructor TMCPBuildToolsRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TMCPBuildToolsRegistrar: AFacade');
  FFacade := AFacade;
  if Assigned(AConsentRegistry) then
    FConsentRegistry := AConsentRegistry
  else
    FConsentRegistry := TMCPConsentRegistry.Create;
  if Assigned(AAuditLog) then
    FAuditLog := AAuditLog
  else
    FAuditLog := TMCPAuditLog.Create;
end;

procedure TMCPBuildToolsRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPBuildToolsRegistrar.RegisterAll: AServer');
  // Order matches the catalog row order for verdict=new (BR-1).
  AServer.RegisterTool(_BuildCleanProject);
  AServer.RegisterTool(_BuildGetSearchPath);
  AServer.RegisterTool(_BuildSetSearchPath);
  AServer.RegisterTool(_BuildAddToSearchPath);
  AServer.RegisterTool(_BuildGetConditionalDefines);
  AServer.RegisterTool(_BuildSetConditionalDefines);
  AServer.RegisterTool(_BuildAddConditionalDefine);
  AServer.RegisterTool(_BuildRemoveConditionalDefine);
  AServer.RegisterTool(_BuildGetDCUOutputDir);
  AServer.RegisterTool(_BuildSetDCUOutputDir);
  AServer.RegisterTool(_BuildRunProject);
  AServer.RegisterTool(_BuildRunWithoutDebugger);
  AServer.RegisterTool(_BuildStopProject);
  AServer.RegisterTool(_BuildStopRunningApp);
end;

// ── Helpers ───────────────────────────────────────────────────────────

function TMCPBuildToolsRegistrar._ReadStringArray(const AParams: TJSONObject;
  const AName: string): TArray<string>;
var
  LValue: TJSONValue;
  LArr: TJSONArray;
  LFor: Integer;
begin
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create(AName + ' required');
  LValue := AParams.GetValue(AName);
  if not (Assigned(LValue) and (LValue is TJSONArray)) then
    raise EMCPInvalidParams.Create(AName + ' required (string[])');
  LArr := TJSONArray(LValue);
  SetLength(Result, LArr.Count);
  for LFor := 0 to LArr.Count - 1 do
  begin
    if not (LArr.Items[LFor] is TJSONString) then
      raise EMCPInvalidParams.Create(AName + ' must contain only strings');
    Result[LFor] := TJSONString(LArr.Items[LFor]).Value;
  end;
end;

function TMCPBuildToolsRegistrar._StringResult(
  const AValue: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', AValue);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPBuildToolsRegistrar._StringArrayResult(
  const AValues: TArray<string>): TMCPToolResult;
var
  LObj: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AValues) do
      LArr.Add(AValues[LFor]);
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPBuildToolsRegistrar._AppliedResult(
  const AApplied: Boolean): TMCPToolResult;
begin
  if AApplied then
    Result := TMCPToolResult.Text('{"applied":true}')
  else
    Result := TMCPToolResult.Text('{"applied":false}');
end;

function TMCPBuildToolsRegistrar._RequestGate(
  const AContext: IMCPToolContext;
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

procedure TMCPBuildToolsRegistrar._AuditDenied(const AToolName, AArgs: string);
begin
  FAuditLog.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPBuildToolsRegistrar._AuditApplied(const AToolName, AArgs: string;
  const ADecision: TMCPConsentDecision);
begin
  FAuditLog.Append(AToolName, AArgs, TMCPConsentToken.Token(ADecision), 'applied');
end;

procedure TMCPBuildToolsRegistrar._AuditFailed(const AToolName, AArgs: string;
  const ADecision: TMCPConsentDecision);
begin
  FAuditLog.Append(AToolName, AArgs, TMCPConsentToken.Token(ADecision), 'failed');
end;

// Lifecycle helper for CleanProject / RunProject / RunWithoutDebugger /
// StopProject — no-arg consent-gated tools that just wrap a facade call.
function TMCPBuildToolsRegistrar._RunLifecycle(
  const AContext: IMCPToolContext;
  const AToolName, ASummary: string;
  const AInvoke: TFunc<Boolean>): TMCPToolResult;
var
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LDecision := _RequestGate(AContext, AToolName, ASummary, '');
  if LDecision = cdDenied then
  begin
    _AuditDenied(AToolName, '');
    raise EMCPUserDenied.Create(AToolName + ': user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := AInvoke();
    end);
  if LApplied then
    _AuditApplied(AToolName, '', LDecision)
  else
    _AuditFailed(AToolName, '', LDecision);
  Result := _AppliedResult(LApplied);
end;

// ── Descriptor builders ────────────────────────────────────────────────

function TMCPBuildToolsRegistrar._BuildGetSearchPath: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetSearchPath',
    'Get search path',
    'Returns the project search path for the active platform',
    _MakeEmptyInputSchema,
    _MakeStringArrayResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetSearchPath(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildSetSearchPath: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SetSearchPath',
    'Set search path',
    'Sets the project search path',
    _MakeStringArrayParamSchema('Paths',
      'Replacement search path entries.'),
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetSearchPath(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildAddToSearchPath: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'AddToSearchPath',
    'Add to search path',
    'Appends a path to the search path',
    _MakeOneStringParamSchema('Path',
      'Search path entry to append (no-op when already present).'),
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleAddToSearchPath(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildGetConditionalDefines: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetConditionalDefines',
    'Get conditional defines',
    'Returns the project conditional defines',
    _MakeEmptyInputSchema,
    _MakeStringArrayResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetConditionalDefines(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildSetConditionalDefines: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SetConditionalDefines',
    'Set conditional defines',
    'Sets the project conditional defines',
    _MakeStringArrayParamSchema('Defines',
      'Replacement defines list (deduplicated, order preserved).'),
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetConditionalDefines(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildAddConditionalDefine: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'AddConditionalDefine',
    'Add conditional define',
    'Appends a conditional define',
    _MakeOneStringParamSchema('Define',
      'Define name to append (no-op when already present).'),
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleAddConditionalDefine(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildRemoveConditionalDefine: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'RemoveConditionalDefine',
    'Remove conditional define',
    'Removes a conditional define',
    _MakeOneStringParamSchema('Define',
      'Define name to remove (idempotent when absent).'),
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRemoveConditionalDefine(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildGetDCUOutputDir: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetDCUOutputDir',
    'Get DCU output directory',
    'Returns the .dcu output directory',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetDCUOutputDir(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildSetDCUOutputDir: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SetDCUOutputDir',
    'Set DCU output directory',
    'Sets the .dcu output directory',
    _MakeOneStringParamSchema('Dir',
      'New DCU output directory.'),
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetDCUOutputDir(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildCleanProject: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'CleanProject',
    'Clean project',
    'Cleans the project build artifacts',
    _MakeEmptyInputSchema,
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleCleanProject(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildRunProject: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'RunProject',
    'Run project',
    'Runs the active project under the IDE debugger (the IDE''s Run / F9). ' +
    'applied:true now means the launch was CONFIRMED: after firing Run, the ' +
    'tool bounded-polls the debugger (IOTADebuggerServices.ProcessCount, ~1.5s) ' +
    'and returns applied:true only when a debugged process is actually running ' +
    '(so a .dpr with no main form, a compile error or a modal that aborts the ' +
    'start now yields applied:false instead of a false positive). Still RunBuild ' +
    'FIRST and check GetCompilerErrors is empty before RunProject. Because this ' +
    'runs WITH the debugger, the launched app CAN be closed afterwards with ' +
    'StopRunningApp (unlike RunWithoutDebugger, which detaches). NOTE: an app ' +
    'that launches then exits almost instantly may still report applied:false ' +
    '(it was gone before/at the confirmation poll) — that is the intended ' +
    'signal that it did not stay up.',
    _MakeEmptyInputSchema,
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRunProject(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildRunWithoutDebugger: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'RunWithoutDebugger',
    'Run without debugger',
    'Runs the project without the debugger',
    _MakeEmptyInputSchema,
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRunWithoutDebugger(AParams, AContext);
    end);
end;

function TMCPBuildToolsRegistrar._BuildStopProject: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'StopProject',
    'Stop project',
    'Stops the project execution',
    _MakeEmptyInputSchema,
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleStopProject(AParams, AContext);
    end);
end;

// Discoverable alias for StopProject: a self-describing name so an agent that
// just wants to "close the running app" finds it without knowing the IDE's
// Ctrl+F2 / Program Reset shortcut (the contract lives in the tool, not in agent
// memory). Same handler/facade as StopProject.
function TMCPBuildToolsRegistrar._BuildStopRunningApp: TMCPToolDescriptor;
var
  LDispatch: IMCPBuildToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'StopRunningApp',
    'Stop running app',
    'Stops/terminates the application currently RUNNING from the IDE — the ' +
    'programmatic equivalent of the IDE''s Program Reset (Ctrl+F2). Call this ' +
    'to close/kill the running .exe after RunProject so the next build/run is ' +
    'not blocked by a locked executable. WORKS for anything launched via Run ' +
    '(F9 / RunProject), REGARDLESS of Debug or Release build configuration — ' +
    'it terminates the IDE''s active debug-attached processes ' +
    '(IOTADebuggerServices). The ONLY thing it cannot stop is a process started ' +
    'by RunWithoutDebugger (Ctrl+Shift+F9), which runs detached from the IDE; ' +
    'launch with RunProject (F9) if you need to stop it programmatically. ' +
    'Idempotent: returns applied:true even when nothing is running (no-op).',
    _MakeEmptyInputSchema,
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleStopProject(AParams, AContext);
    end);
end;

// ── Read handlers ─────────────────────────────────────────────────────

function TMCPBuildToolsRegistrar._HandleGetSearchPath(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValues: TArray<string>;
begin
  SetLength(LValues, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LValues := FFacade.GetSearchPath;
    end);
  Result := _StringArrayResult(LValues);
end;

function TMCPBuildToolsRegistrar._HandleGetConditionalDefines(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValues: TArray<string>;
begin
  SetLength(LValues, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LValues := FFacade.GetConditionalDefines;
    end);
  Result := _StringArrayResult(LValues);
end;

function TMCPBuildToolsRegistrar._HandleGetDCUOutputDir(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetDCUOutputDir;
    end);
  Result := _StringResult(LValue);
end;

// ── Write handlers (consent-gated; BR-2) ───────────────────────────────

function TMCPBuildToolsRegistrar._HandleSetSearchPath(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LPaths: TArray<string>;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
  LArgs: string;
begin
  LPaths := _ReadStringArray(AParams, 'Paths');
  LArgs := string.Join(';', LPaths);
  LDecision := _RequestGate(AContext, 'SetSearchPath',
    'Replace project search path:', LArgs);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetSearchPath', LArgs);
    raise EMCPUserDenied.Create('SetSearchPath: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetSearchPath(LPaths);
    end);
  if LApplied then
    _AuditApplied('SetSearchPath', LArgs, LDecision)
  else
    _AuditFailed('SetSearchPath', LArgs, LDecision);
  Result := _AppliedResult(LApplied);
end;

function TMCPBuildToolsRegistrar._HandleAddToSearchPath(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LPath: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LPath := _ReadString(AParams, 'Path');
  // AC-07: reject empty input before requesting consent.
  if Trim(LPath) = '' then
    raise EMCPInvalidParams.Create(
      'AddToSearchPath: Path rejected; data.detail={"reason":"empty-path"}');
  LDecision := _RequestGate(AContext, 'AddToSearchPath',
    'Append entry to project search path:', LPath);
  if LDecision = cdDenied then
  begin
    _AuditDenied('AddToSearchPath', LPath);
    raise EMCPUserDenied.Create('AddToSearchPath: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.AddToSearchPath(LPath);
    end);
  if LApplied then
    _AuditApplied('AddToSearchPath', LPath, LDecision)
  else
    _AuditFailed('AddToSearchPath', LPath, LDecision);
  Result := _AppliedResult(LApplied);
end;

function TMCPBuildToolsRegistrar._HandleSetConditionalDefines(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDefines: TArray<string>;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
  LArgs: string;
begin
  LDefines := _ReadStringArray(AParams, 'Defines');
  LArgs := string.Join(';', LDefines);
  LDecision := _RequestGate(AContext, 'SetConditionalDefines',
    'Replace project conditional defines:', LArgs);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetConditionalDefines', LArgs);
    raise EMCPUserDenied.Create(
      'SetConditionalDefines: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetConditionalDefines(LDefines);
    end);
  if LApplied then
    _AuditApplied('SetConditionalDefines', LArgs, LDecision)
  else
    _AuditFailed('SetConditionalDefines', LArgs, LDecision);
  Result := _AppliedResult(LApplied);
end;

// Returns True when ADefine is a syntactically valid conditional-define
// identifier — non-empty and contains no whitespace, `=`, or `;` (AC-10).
function _IsValidDefineName(const ADefine: string): Boolean;
var
  LFor: Integer;
  LCh: Char;
begin
  if ADefine = '' then
    Exit(False);
  for LFor := 1 to Length(ADefine) do
  begin
    LCh := ADefine[LFor];
    if (LCh = ' ') or (LCh = #9) or (LCh = '=') or (LCh = ';') then
      Exit(False);
  end;
  Result := True;
end;

function TMCPBuildToolsRegistrar._HandleAddConditionalDefine(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDefine: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LDefine := _ReadString(AParams, 'Define');
  // AC-10: reject whitespace, `=`, `;` before requesting consent.
  if not _IsValidDefineName(LDefine) then
    raise EMCPInvalidParams.Create(
      'AddConditionalDefine: Define rejected; data.detail={"reason":"invalid-define"}');
  LDecision := _RequestGate(AContext, 'AddConditionalDefine',
    'Append conditional define:', LDefine);
  if LDecision = cdDenied then
  begin
    _AuditDenied('AddConditionalDefine', LDefine);
    raise EMCPUserDenied.Create(
      'AddConditionalDefine: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.AddConditionalDefine(LDefine);
    end);
  if LApplied then
    _AuditApplied('AddConditionalDefine', LDefine, LDecision)
  else
    _AuditFailed('AddConditionalDefine', LDefine, LDecision);
  Result := _AppliedResult(LApplied);
end;

function TMCPBuildToolsRegistrar._HandleRemoveConditionalDefine(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDefine: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LDefine := _ReadString(AParams, 'Define');
  LDecision := _RequestGate(AContext, 'RemoveConditionalDefine',
    'Remove conditional define:', LDefine);
  if LDecision = cdDenied then
  begin
    _AuditDenied('RemoveConditionalDefine', LDefine);
    raise EMCPUserDenied.Create(
      'RemoveConditionalDefine: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.RemoveConditionalDefine(LDefine);
    end);
  if LApplied then
    _AuditApplied('RemoveConditionalDefine', LDefine, LDecision)
  else
    _AuditFailed('RemoveConditionalDefine', LDefine, LDecision);
  Result := _AppliedResult(LApplied);
end;

function TMCPBuildToolsRegistrar._HandleSetDCUOutputDir(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDir: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LDir := _ReadString(AParams, 'Dir');
  LDecision := _RequestGate(AContext, 'SetDCUOutputDir',
    'Set DCU output directory:', LDir);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetDCUOutputDir', LDir);
    raise EMCPUserDenied.Create('SetDCUOutputDir: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetDCUOutputDir(LDir);
    end);
  if LApplied then
    _AuditApplied('SetDCUOutputDir', LDir, LDecision)
  else
    _AuditFailed('SetDCUOutputDir', LDir, LDecision);
  Result := _AppliedResult(LApplied);
end;

function TMCPBuildToolsRegistrar._HandleCleanProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFacade: IMCPWorkspaceFacade;
begin
  LFacade := FFacade;
  Result := _RunLifecycle(AContext, 'CleanProject',
    'Clean build artifacts of the active project.',
    function: Boolean
    begin
      Result := LFacade.CleanProject;
    end);
end;

function TMCPBuildToolsRegistrar._HandleRunProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFacade: IMCPWorkspaceFacade;
begin
  LFacade := FFacade;
  Result := _RunLifecycle(AContext, 'RunProject',
    'Run the active project with the debugger (F9).',
    function: Boolean
    begin
      Result := LFacade.RunProject;
    end);
end;

function TMCPBuildToolsRegistrar._HandleRunWithoutDebugger(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFacade: IMCPWorkspaceFacade;
begin
  LFacade := FFacade;
  Result := _RunLifecycle(AContext, 'RunWithoutDebugger',
    'Run the active project without the debugger (Ctrl+Shift+F9).',
    function: Boolean
    begin
      Result := LFacade.RunWithoutDebugger;
    end);
end;

function TMCPBuildToolsRegistrar._HandleStopProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFacade: IMCPWorkspaceFacade;
begin
  LFacade := FFacade;
  Result := _RunLifecycle(AContext, 'StopProject',
    'Stop the running process via Program Reset (Ctrl+F2).',
    function: Boolean
    begin
      Result := LFacade.StopProject;
    end);
end;

// ── Public registration entries ───────────────────────────────────────

procedure RegisterBuildTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: IMCPBuildToolsRegistrar;
begin
  LRegistrar := TMCPBuildToolsRegistrar.Create(AFacade, nil, nil);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterBuildTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPBuildToolsRegistrar;
begin
  LRegistrar := TMCPBuildToolsRegistrar.Create(AFacade, AConsentRegistry,
    AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

end.
