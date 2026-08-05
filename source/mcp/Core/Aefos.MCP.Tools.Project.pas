unit Aefos.MCP.Tools.Project;

(*
  Project-group MCP tools (ESP-002, Epic 7/7 Demand 2/8).

  Catalog rows: docs/mcp-catalog/catalog.json — group "Project",
  verdict "new". 17 tools (12 reads + 5 writes); RenameProject is
  triaged out (verdict "deferred-paid", Phase 3 paid backlog).

  Layering (ADR-115 / ADR-121):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterProjectTools(AServer, AFacade) called
      from MCP.Server's bootstrap after the shipped 11-tool registration.

  Gating (ADR-122):
    - Reads: direct facade call, no consent.
    - Writes (5): TMCPConsentRegistry.RequireConsent gated, risk class Low,
      JSON-RPC -32000 on denial.

  Validation (ADR-124):
    - SetActiveProjectPlatform / SetActiveConfiguration validate input
      against the read-side enumeration BEFORE the write; unknown values
      return JSON-RPC -32602 with data.detail = {rejected, accepted[]}.

  Composite tool (ADR-123):
    - GetProjectVersion returns "Major.Minor.Release.Build" composite.
    - SetProjectVersion takes 4 integer params; writes 4 keys atomically.
*)

interface

uses
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.Server;

type
  // Dispatch surface for the Project-group tool handlers. Each tool-handler
  // closure captures an IMCPProjectToolsRegistrar reference so the
  // registrar (and its consent/audit collaborators) is reference-counted
  // alive for the server's lifetime — same lifetime contract as the shipped
  // MCP.Tools registrar (ADR-121).
  IMCPProjectToolsRegistrar = interface
    ['{4E8B9D32-7A65-4F1E-9A03-2C58E7D6B4F1}']
    procedure RegisterAll(const AServer: IMCPServer);
    // Handler dispatch surface — the descriptor closures call through the
    // interface so the registrar (and its consent/audit collaborators) is
    // refcount-pinned for the server's lifetime (shipped MCP.Tools pattern).
    function HandleGetProjectName(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetProjectPath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetProjectFilePath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetProjectType(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetProjectVersion(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetProjectVersion(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetProjectGUID(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetProjectPlatforms(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetActiveProjectPlatform(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetActiveProjectPlatform(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetProjectConfigurations(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetActiveConfiguration(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetActiveConfiguration(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetProjectDescription(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetProjectDescription(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetProjectOutputDir(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetProjectOutputDir(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

procedure RegisterProjectTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterProjectTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils,
  Aefos.MCP.Tools.Common;

type
  TMCPProjectToolsRegistrar = class(TMCPToolsRegistrarBase,
    IMCPProjectToolsRegistrar)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsentRegistry: IMCPConsentRegistry;
    FAuditLog: IMCPAuditLog;
    // Descriptor builders — one per Project tool (17 total).
    function _BuildGetProjectName: TMCPToolDescriptor;
    function _BuildGetProjectPath: TMCPToolDescriptor;
    function _BuildGetProjectFilePath: TMCPToolDescriptor;
    function _BuildGetProjectType: TMCPToolDescriptor;
    function _BuildGetProjectVersion: TMCPToolDescriptor;
    function _BuildSetProjectVersion: TMCPToolDescriptor;
    function _BuildGetProjectGUID: TMCPToolDescriptor;
    function _BuildGetProjectPlatforms: TMCPToolDescriptor;
    function _BuildGetActiveProjectPlatform: TMCPToolDescriptor;
    function _BuildSetActiveProjectPlatform: TMCPToolDescriptor;
    function _BuildGetProjectConfigurations: TMCPToolDescriptor;
    function _BuildGetActiveConfiguration: TMCPToolDescriptor;
    function _BuildSetActiveConfiguration: TMCPToolDescriptor;
    function _BuildGetProjectDescription: TMCPToolDescriptor;
    function _BuildSetProjectDescription: TMCPToolDescriptor;
    function _BuildGetProjectOutputDir: TMCPToolDescriptor;
    function _BuildSetProjectOutputDir: TMCPToolDescriptor;
    // Handlers — synchronous facade reads, consent-gated writes (ADR-122).
    function _HandleGetProjectName(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetProjectPath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetProjectFilePath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetProjectType(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetProjectVersion(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetProjectVersion(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetProjectGUID(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetProjectPlatforms(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetActiveProjectPlatform(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetActiveProjectPlatform(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetProjectConfigurations(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetActiveConfiguration(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetActiveConfiguration(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetProjectDescription(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetProjectDescription(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetProjectOutputDir(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetProjectOutputDir(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Consent-gate / audit-log helpers (shipped pattern from MCP.Tools).
    function _RequestGate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    procedure _AuditDenied(const AToolName, AArgs: string);
    procedure _AuditApplied(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    procedure _AuditFailed(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    function _ReadInt(const AParams: TJSONObject;
      const AName: string): Integer;
    function _StringResult(const AValue: string): TMCPToolResult;
    function _StringArrayResult(const AValues: TArray<string>): TMCPToolResult;
    function _AppliedResult(const AApplied: Boolean): TMCPToolResult;
    // Pre-write enumeration validation (ADR-124).
    procedure _ValidateAgainstEnum(const AToolName, AParamName, AValue: string;
      const AAccepted: TArray<string>);
    // Method resolution — IMCPProjectToolsRegistrar dispatch surface maps
    // to the private _Handle* implementations so the underscore-prefixed
    // convention is preserved (shipped MCP.Tools pattern).
    function IMCPProjectToolsRegistrar.HandleGetProjectName = _HandleGetProjectName;
    function IMCPProjectToolsRegistrar.HandleGetProjectPath = _HandleGetProjectPath;
    function IMCPProjectToolsRegistrar.HandleGetProjectFilePath = _HandleGetProjectFilePath;
    function IMCPProjectToolsRegistrar.HandleGetProjectType = _HandleGetProjectType;
    function IMCPProjectToolsRegistrar.HandleGetProjectVersion = _HandleGetProjectVersion;
    function IMCPProjectToolsRegistrar.HandleSetProjectVersion = _HandleSetProjectVersion;
    function IMCPProjectToolsRegistrar.HandleGetProjectGUID = _HandleGetProjectGUID;
    function IMCPProjectToolsRegistrar.HandleGetProjectPlatforms = _HandleGetProjectPlatforms;
    function IMCPProjectToolsRegistrar.HandleGetActiveProjectPlatform = _HandleGetActiveProjectPlatform;
    function IMCPProjectToolsRegistrar.HandleSetActiveProjectPlatform = _HandleSetActiveProjectPlatform;
    function IMCPProjectToolsRegistrar.HandleGetProjectConfigurations = _HandleGetProjectConfigurations;
    function IMCPProjectToolsRegistrar.HandleGetActiveConfiguration = _HandleGetActiveConfiguration;
    function IMCPProjectToolsRegistrar.HandleSetActiveConfiguration = _HandleSetActiveConfiguration;
    function IMCPProjectToolsRegistrar.HandleGetProjectDescription = _HandleGetProjectDescription;
    function IMCPProjectToolsRegistrar.HandleSetProjectDescription = _HandleSetProjectDescription;
    function IMCPProjectToolsRegistrar.HandleGetProjectOutputDir = _HandleGetProjectOutputDir;
    function IMCPProjectToolsRegistrar.HandleSetProjectOutputDir = _HandleSetProjectOutputDir;
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
  LProps: TJSONObject;
  LValue: TJSONObject;
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
  LProps: TJSONObject;
  LValue: TJSONObject;
  LItems: TJSONObject;
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
  LProps: TJSONObject;
  LApplied: TJSONObject;
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
  LProps: TJSONObject;
  LProp: TJSONObject;
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

function _MakeFourIntParamSchema: TJSONObject;
const
  CFields: array[0..3] of string = ('Major', 'Minor', 'Release', 'Build');
var
  LProps: TJSONObject;
  LProp: TJSONObject;
  LRequired: TJSONArray;
  LFor: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LRequired := TJSONArray.Create;
  for LFor := 0 to High(CFields) do
  begin
    LProp := TJSONObject.Create;
    LProp.AddPair('type', 'integer');
    LProps.AddPair(CFields[LFor], LProp);
    LRequired.Add(CFields[LFor]);
  end;
  Result.AddPair('properties', LProps);
  Result.AddPair('required', LRequired);
end;

// Maps a consent decision to the audit-log `consent` token (ADR-067 carry).
{ TMCPProjectToolsRegistrar }

constructor TMCPProjectToolsRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TMCPProjectToolsRegistrar: AFacade');
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

procedure TMCPProjectToolsRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPProjectToolsRegistrar.RegisterAll: AServer');
  // Order matches the catalog row order (BR-1).
  AServer.RegisterTool(_BuildGetProjectName);
  AServer.RegisterTool(_BuildGetProjectPath);
  AServer.RegisterTool(_BuildGetProjectFilePath);
  AServer.RegisterTool(_BuildGetProjectType);
  AServer.RegisterTool(_BuildGetProjectVersion);
  AServer.RegisterTool(_BuildSetProjectVersion);
  AServer.RegisterTool(_BuildGetProjectGUID);
  AServer.RegisterTool(_BuildGetProjectPlatforms);
  AServer.RegisterTool(_BuildGetActiveProjectPlatform);
  AServer.RegisterTool(_BuildSetActiveProjectPlatform);
  AServer.RegisterTool(_BuildGetProjectConfigurations);
  AServer.RegisterTool(_BuildGetActiveConfiguration);
  AServer.RegisterTool(_BuildSetActiveConfiguration);
  AServer.RegisterTool(_BuildGetProjectDescription);
  AServer.RegisterTool(_BuildSetProjectDescription);
  AServer.RegisterTool(_BuildGetProjectOutputDir);
  AServer.RegisterTool(_BuildSetProjectOutputDir);
end;

// ── Helpers ───────────────────────────────────────────────────────────

function TMCPProjectToolsRegistrar._ReadInt(const AParams: TJSONObject;
  const AName: string): Integer;
var
  LValue: TJSONValue;
  LNumber: TJSONNumber;
begin
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create(AName + ' required');
  LValue := AParams.GetValue(AName);
  if not (Assigned(LValue) and (LValue is TJSONNumber)) then
    raise EMCPInvalidParams.Create(AName + ' required (integer)');
  LNumber := TJSONNumber(LValue);
  Result := LNumber.AsInt;
end;

function TMCPProjectToolsRegistrar._StringResult(
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

function TMCPProjectToolsRegistrar._StringArrayResult(
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

function TMCPProjectToolsRegistrar._AppliedResult(
  const AApplied: Boolean): TMCPToolResult;
begin
  if AApplied then
    Result := TMCPToolResult.Text('{"applied":true}')
  else
    Result := TMCPToolResult.Text('{"applied":false}');
end;

function TMCPProjectToolsRegistrar._RequestGate(
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

procedure TMCPProjectToolsRegistrar._AuditDenied(const AToolName,
  AArgs: string);
begin
  FAuditLog.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPProjectToolsRegistrar._AuditApplied(const AToolName,
  AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAuditLog.Append(AToolName, AArgs, TMCPConsentToken.Token(ADecision), 'applied');
end;

procedure TMCPProjectToolsRegistrar._AuditFailed(const AToolName,
  AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAuditLog.Append(AToolName, AArgs, TMCPConsentToken.Token(ADecision), 'failed');
end;

// ADR-124: validates input against the read-side enumeration before issuing
// the write. Unknown values raise EMCPInvalidParams with data.detail
// embedded in the message (rejected + accepted[]).
procedure TMCPProjectToolsRegistrar._ValidateAgainstEnum(const AToolName,
  AParamName, AValue: string; const AAccepted: TArray<string>);
var
  LFor: Integer;
  LAcceptedJoined: string;
begin
  for LFor := 0 to High(AAccepted) do
    if SameText(AAccepted[LFor], AValue) then
      Exit;
  if Length(AAccepted) = 0 then
    LAcceptedJoined := ''
  else
  begin
    LAcceptedJoined := AAccepted[0];
    for LFor := 1 to High(AAccepted) do
      LAcceptedJoined := LAcceptedJoined + ',' + AAccepted[LFor];
  end;
  raise EMCPInvalidParams.Create(Format(
    '%s: %s "%s" not in accepted set [%s]',
    [AToolName, AParamName, AValue, LAcceptedJoined]));
end;

// ── Read tool descriptors ─────────────────────────────────────────────

function TMCPProjectToolsRegistrar._BuildGetProjectName: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetProjectName',
    'Get project name',
    'Returns the name of the active project in the IDE',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectName(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetProjectPath: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetProjectPath',
    'Get project path',
    'Returns the full path of the project directory',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectPath(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetProjectFilePath: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetProjectFilePath',
    'Get project file path',
    'Returns the full path of the .dproj file',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectFilePath(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetProjectType: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetProjectType',
    'Get project type',
    'Returns the project type (VCL App, FMX App, DLL, Package...)',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectType(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetProjectVersion: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetProjectVersion',
    'Get project version',
    'Returns Major.Minor.Release.Build of the project',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectVersion(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildSetProjectVersion: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SetProjectVersion',
    'Set project version',
    'Sets Major.Minor.Release.Build of the project',
    _MakeFourIntParamSchema,
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetProjectVersion(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetProjectGUID: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetProjectGUID',
    'Get project GUID',
    'Returns the GUID of the project',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectGUID(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetProjectPlatforms: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetProjectPlatforms',
    'Get project platforms',
    'Lists platforms configured in the project (Win32, Win64, Android...)',
    _MakeEmptyInputSchema,
    _MakeStringArrayResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectPlatforms(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetActiveProjectPlatform: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetActiveProjectPlatform',
    'Get active project platform',
    'Returns the currently active platform',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetActiveProjectPlatform(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildSetActiveProjectPlatform: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SetActiveProjectPlatform',
    'Set active project platform',
    'Changes the active platform of the project',
    _MakeOneStringParamSchema('Platform',
      'Platform name (must be one of GetProjectPlatforms).'),
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetActiveProjectPlatform(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetProjectConfigurations: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetProjectConfigurations',
    'Get project configurations',
    'Lists the build configurations (Debug, Release...)',
    _MakeEmptyInputSchema,
    _MakeStringArrayResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectConfigurations(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetActiveConfiguration: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetActiveConfiguration',
    'Get active configuration',
    'Returns the active build configuration',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetActiveConfiguration(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildSetActiveConfiguration: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SetActiveConfiguration',
    'Set active configuration',
    'Changes the active build configuration',
    _MakeOneStringParamSchema('ConfigName',
      'Configuration name (must be one of GetProjectConfigurations).'),
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetActiveConfiguration(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetProjectDescription: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetProjectDescription',
    'Get project description',
    'Returns the description of the project',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectDescription(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildSetProjectDescription: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SetProjectDescription',
    'Set project description',
    'Sets the description of the project',
    _MakeOneStringParamSchema('Description',
      'New project description.'),
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetProjectDescription(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildGetProjectOutputDir: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetProjectOutputDir',
    'Get project output directory',
    'Returns the output directory of the executable',
    _MakeEmptyInputSchema,
    _MakeStringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectOutputDir(AParams, AContext);
    end);
end;

function TMCPProjectToolsRegistrar._BuildSetProjectOutputDir: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SetProjectOutputDir',
    'Set project output directory',
    'Sets the output directory of the executable',
    _MakeOneStringParamSchema('Dir',
      'New output directory path.'),
    _MakeAppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetProjectOutputDir(AParams, AContext);
    end);
end;

// ── Read handlers ─────────────────────────────────────────────────────

function TMCPProjectToolsRegistrar._HandleGetProjectName(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetProjectName;
    end);
  Result := _StringResult(LValue);
end;

function TMCPProjectToolsRegistrar._HandleGetProjectPath(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetProjectPath;
    end);
  Result := _StringResult(LValue);
end;

function TMCPProjectToolsRegistrar._HandleGetProjectFilePath(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetProjectFilePath;
    end);
  Result := _StringResult(LValue);
end;

function TMCPProjectToolsRegistrar._HandleGetProjectType(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetProjectType;
    end);
  Result := _StringResult(LValue);
end;

function TMCPProjectToolsRegistrar._HandleGetProjectVersion(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetProjectVersion;
    end);
  Result := _StringResult(LValue);
end;

function TMCPProjectToolsRegistrar._HandleGetProjectGUID(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetProjectGUID;
    end);
  Result := _StringResult(LValue);
end;

function TMCPProjectToolsRegistrar._HandleGetProjectPlatforms(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValues: TArray<string>;
begin
  SetLength(LValues, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LValues := FFacade.GetProjectPlatforms;
    end);
  Result := _StringArrayResult(LValues);
end;

function TMCPProjectToolsRegistrar._HandleGetActiveProjectPlatform(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetActiveProjectPlatform;
    end);
  Result := _StringResult(LValue);
end;

function TMCPProjectToolsRegistrar._HandleGetProjectConfigurations(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValues: TArray<string>;
begin
  SetLength(LValues, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LValues := FFacade.GetProjectConfigurations;
    end);
  Result := _StringArrayResult(LValues);
end;

function TMCPProjectToolsRegistrar._HandleGetActiveConfiguration(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetActiveConfiguration;
    end);
  Result := _StringResult(LValue);
end;

function TMCPProjectToolsRegistrar._HandleGetProjectDescription(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetProjectDescription;
    end);
  Result := _StringResult(LValue);
end;

function TMCPProjectToolsRegistrar._HandleGetProjectOutputDir(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetProjectOutputDir;
    end);
  Result := _StringResult(LValue);
end;

// ── Write handlers (consent-gated; ADR-122) ────────────────────────────

function TMCPProjectToolsRegistrar._HandleSetProjectVersion(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LMajor, LMinor, LRelease, LBuild: Integer;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
  LArgs: string;
begin
  LMajor := _ReadInt(AParams, 'Major');
  LMinor := _ReadInt(AParams, 'Minor');
  LRelease := _ReadInt(AParams, 'Release');
  LBuild := _ReadInt(AParams, 'Build');
  LArgs := Format('%d.%d.%d.%d', [LMajor, LMinor, LRelease, LBuild]);
  LDecision := _RequestGate(AContext, 'SetProjectVersion',
    'Set VerInfo (Major.Minor.Release.Build) on the active project:', LArgs);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetProjectVersion', LArgs);
    raise EMCPUserDenied.Create('SetProjectVersion: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetProjectVersion(LMajor, LMinor, LRelease, LBuild);
    end);
  if LApplied then
    _AuditApplied('SetProjectVersion', LArgs, LDecision)
  else
    _AuditFailed('SetProjectVersion', LArgs, LDecision);
  Result := _AppliedResult(LApplied);
end;

function TMCPProjectToolsRegistrar._HandleSetActiveProjectPlatform(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LPlatform: string;
  LAccepted: TArray<string>;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LPlatform := _ReadString(AParams, 'Platform');
  // Pre-write validation (ADR-124).
  SetLength(LAccepted, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LAccepted := FFacade.GetProjectPlatforms;
    end);
  _ValidateAgainstEnum('SetActiveProjectPlatform', 'Platform', LPlatform,
    LAccepted);
  LDecision := _RequestGate(AContext, 'SetActiveProjectPlatform',
    'Set active platform on the active project:', LPlatform);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetActiveProjectPlatform', LPlatform);
    raise EMCPUserDenied.Create(
      'SetActiveProjectPlatform: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetActiveProjectPlatform(LPlatform);
    end);
  if LApplied then
    _AuditApplied('SetActiveProjectPlatform', LPlatform, LDecision)
  else
    _AuditFailed('SetActiveProjectPlatform', LPlatform, LDecision);
  Result := _AppliedResult(LApplied);
end;

function TMCPProjectToolsRegistrar._HandleSetActiveConfiguration(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LConfig: string;
  LAccepted: TArray<string>;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LConfig := _ReadString(AParams, 'ConfigName');
  // Pre-write validation (ADR-124).
  SetLength(LAccepted, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LAccepted := FFacade.GetProjectConfigurations;
    end);
  _ValidateAgainstEnum('SetActiveConfiguration', 'ConfigName', LConfig,
    LAccepted);
  LDecision := _RequestGate(AContext, 'SetActiveConfiguration',
    'Set active configuration on the active project:', LConfig);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetActiveConfiguration', LConfig);
    raise EMCPUserDenied.Create(
      'SetActiveConfiguration: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetActiveConfiguration(LConfig);
    end);
  if LApplied then
    _AuditApplied('SetActiveConfiguration', LConfig, LDecision)
  else
    _AuditFailed('SetActiveConfiguration', LConfig, LDecision);
  Result := _AppliedResult(LApplied);
end;

function TMCPProjectToolsRegistrar._HandleSetProjectDescription(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDescription: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LDescription := _ReadString(AParams, 'Description');
  LDecision := _RequestGate(AContext, 'SetProjectDescription',
    'Set Description on the active project:', LDescription);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetProjectDescription', LDescription);
    raise EMCPUserDenied.Create(
      'SetProjectDescription: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetProjectDescription(LDescription);
    end);
  if LApplied then
    _AuditApplied('SetProjectDescription', LDescription, LDecision)
  else
    _AuditFailed('SetProjectDescription', LDescription, LDecision);
  Result := _AppliedResult(LApplied);
end;

function TMCPProjectToolsRegistrar._HandleSetProjectOutputDir(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDir: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LDir := _ReadString(AParams, 'Dir');
  LDecision := _RequestGate(AContext, 'SetProjectOutputDir',
    'Set OutputDir on the active project:', LDir);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetProjectOutputDir', LDir);
    raise EMCPUserDenied.Create(
      'SetProjectOutputDir: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetProjectOutputDir(LDir);
    end);
  if LApplied then
    _AuditApplied('SetProjectOutputDir', LDir, LDecision)
  else
    _AuditFailed('SetProjectOutputDir', LDir, LDecision);
  Result := _AppliedResult(LApplied);
end;

// ── Public registration entries ───────────────────────────────────────

procedure RegisterProjectTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: IMCPProjectToolsRegistrar;
begin
  // Reference-counted lifetime: each tool-handler closure captures a
  // registrar reference and dispatches through it, so the registrar (and
  // its consent/audit collaborators) stays alive for the server's lifetime
  // and is released only when the server frees its tool descriptors.
  LRegistrar := TMCPProjectToolsRegistrar.Create(AFacade, nil, nil);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterProjectTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPProjectToolsRegistrar;
begin
  // Overload that injects a caller-owned consent registry and audit log —
  // used to share a session-scoped registry with tests and to point the
  // audit log at a non-default path. Same lifetime contract as above.
  LRegistrar := TMCPProjectToolsRegistrar.Create(AFacade, AConsentRegistry,
    AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

end.
