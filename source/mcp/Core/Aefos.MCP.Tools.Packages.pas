unit Aefos.MCP.Tools.Packages;

(*
  Packages MCP tools (ESP-002, Epic 7/7 Demand 8/8).

  Catalog rows: docs/mcp-catalog/catalog.json — group "Packages",
  verdict "new". 5 tools (2 reads + 3 consent-gated writes):
    ListProjectPackages, AddPackageToProject, RemovePackageFromProject,
    GetLibraryPath, AddToLibraryPath.

  Layering (ADR-115 / ADR-145):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterPackagesTools(AServer, AFacade), called
      from the bootstrap after Project Group registration.

  Gating (ADR-146):
    - AddPackageToProject       Low    (session-wide).
    - RemovePackageFromProject  Low    (session-wide).
    - AddToLibraryPath          Medium (per-call prompt — mutates global
                                IDE state). Achieved by NOT consulting the
                                session-allow registry, so every call
                                prompts (the registry's GrantSession is a
                                no-op for Medium tools).
*)

interface

uses
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.Tools.Common,
  Aefos.MCP.Server;

procedure RegisterPackagesTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterPackagesTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils,
  System.JSON;

type
  TMCPPackagesToolsRegistrar = class(TMCPToolsRegistrarBase)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsent: IMCPConsentRegistry;
    FAudit: IMCPAuditLog;
    // Consent gate. ARisk: 'low' = session-wide; 'medium' = per-call.
    function _Gate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail, ARisk: string): TMCPConsentDecision;
    procedure _AuditDenied(const AToolName, AArgs: string);
    procedure _AuditApplied(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    function _ReadBoolDefault(const AParams: TJSONObject;
      const AName: string; const ADefault: Boolean): Boolean;
    // Schemas.
    function _SchemaEmpty: TJSONObject;
    function _SchemaPackagePath: TJSONObject;
    function _SchemaPackageName: TJSONObject;
    function _SchemaPath: TJSONObject;
    function _SchemaPackageArray: TJSONObject;
    function _SchemaStringArray: TJSONObject;
    function _SchemaAppliedChanged: TJSONObject;
    // Result builders.
    function _ResultPackages(
      const APackages: TArray<TMCPRecordProjectPackage>): TMCPToolResult;
    function _ResultStringArray(
      const AValues: TArray<string>): TMCPToolResult;
    function _ResultAppliedChanged(const AApplied,
      AChanged: Boolean): TMCPToolResult;
    // Handlers.
    function _HandleListProjectPackages(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetLibraryPath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddPackageToProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRemovePackageFromProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddToLibraryPath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry;
      const AAudit: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPPackagesToolsRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create(
      'TMCPPackagesToolsRegistrar: AFacade');
  FFacade := AFacade;
  if Assigned(AConsent) then
    FConsent := AConsent
  else
    FConsent := TMCPConsentRegistry.Create;
  if Assigned(AAudit) then
    FAudit := AAudit
  else
    FAudit := TMCPAuditLog.Create;
end;

function TMCPPackagesToolsRegistrar._Gate(const AContext: IMCPToolContext;
  const AToolName, ASummary, ADetail, ARisk: string): TMCPConsentDecision;
var
  LDecision: TMCPConsentDecision;
begin
  // Medium-risk tools (ADR-146) NEVER consult the session registry —
  // every call prompts the maintainer. Low-risk tools follow the
  // session-wide grant.
  if SameText(ARisk, 'low') and FConsent.IsSessionAllowed(AToolName) then
    Exit(cdAllowSession);
  LDecision := cdDenied;
  AContext.MarshalToMainThread(
    procedure
    begin
      LDecision := FFacade.RequestConsent(AToolName, ASummary, ADetail);
    end);
  if SameText(ARisk, 'low') and (LDecision = cdAllowSession) then
    FConsent.GrantSession(AToolName);
  Result := LDecision;
end;

procedure TMCPPackagesToolsRegistrar._AuditDenied(
  const AToolName, AArgs: string);
begin
  FAudit.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPPackagesToolsRegistrar._AuditApplied(
  const AToolName, AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'applied');
end;

function TMCPPackagesToolsRegistrar._ReadBoolDefault(
  const AParams: TJSONObject; const AName: string;
  const ADefault: Boolean): Boolean;
var
  LValue: TJSONValue;
begin
  Result := ADefault;
  if not Assigned(AParams) then
    Exit;
  LValue := AParams.GetValue(AName);
  if not Assigned(LValue) then
    Exit;
  if LValue is TJSONTrue then
    Result := True
  else if LValue is TJSONFalse then
    Result := False
  else if LValue is TJSONBool then
    Result := TJSONBool(LValue).AsBoolean;
end;

function TMCPPackagesToolsRegistrar._SchemaEmpty: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

function TMCPPackagesToolsRegistrar._SchemaPackagePath: TJSONObject;
var
  LProps, LField: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create;
  LField.AddPair('type', 'string');
  LProps.AddPair('PackagePath', LField);
  LField := TJSONObject.Create;
  LField.AddPair('type', 'boolean');
  LProps.AddPair('Runtime', LField);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('PackagePath');
  Result.AddPair('required', LRequired);
end;

function TMCPPackagesToolsRegistrar._SchemaPackageName: TJSONObject;
var
  LProps, LField: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create;
  LField.AddPair('type', 'string');
  LProps.AddPair('PackageName', LField);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('PackageName');
  Result.AddPair('required', LRequired);
end;

function TMCPPackagesToolsRegistrar._SchemaPath: TJSONObject;
var
  LProps, LField: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create;
  LField.AddPair('type', 'string');
  LProps.AddPair('Path', LField);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('Path');
  Result.AddPair('required', LRequired);
end;

function TMCPPackagesToolsRegistrar._SchemaPackageArray: TJSONObject;
var
  LProps, LValue, LItem, LItemProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('name', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('path', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'boolean');
  LItemProps.AddPair('runtime', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'boolean');
  LItemProps.AddPair('designtime', LField);
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function TMCPPackagesToolsRegistrar._SchemaStringArray: TJSONObject;
var
  LProps, LValue, LItem: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'string');
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function TMCPPackagesToolsRegistrar._SchemaAppliedChanged: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'boolean');
  LProps.AddPair('applied', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'boolean');
  LProps.AddPair('changed', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPPackagesToolsRegistrar._ResultPackages(
  const APackages: TArray<TMCPRecordProjectPackage>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(APackages) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('name', APackages[LFor].Name);
      LItem.AddPair('path', APackages[LFor].Path);
      LItem.AddPair('runtime', TJSONBool.Create(APackages[LFor].Runtime));
      LItem.AddPair('designtime',
        TJSONBool.Create(APackages[LFor].Designtime));
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPPackagesToolsRegistrar._ResultStringArray(
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

function TMCPPackagesToolsRegistrar._ResultAppliedChanged(const AApplied,
  AChanged: Boolean): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('applied', TJSONBool.Create(AApplied));
    LObj.AddPair('changed', TJSONBool.Create(AChanged));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPPackagesToolsRegistrar._HandleListProjectPackages(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LPackages: TArray<TMCPRecordProjectPackage>;
begin
  SetLength(LPackages, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LPackages := FFacade.ListProjectPackages;
    end);
  Result := _ResultPackages(LPackages);
end;

function TMCPPackagesToolsRegistrar._HandleGetLibraryPath(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValues: TArray<string>;
begin
  SetLength(LValues, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LValues := FFacade.GetLibraryPath;
    end);
  Result := _ResultStringArray(LValues);
end;

function TMCPPackagesToolsRegistrar._HandleAddPackageToProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LPath, LReason: string;
  LRuntime: Boolean;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LPath := _ReadString(AParams, 'PackagePath');
  LRuntime := _ReadBoolDefault(AParams, 'Runtime', False);
  LDecision := _Gate(AContext, 'AddPackageToProject',
    'Add package reference to project:', LPath, 'low');
  if LDecision = cdDenied then
  begin
    _AuditDenied('AddPackageToProject', LPath);
    raise EMCPUserDenied.Create(
      'AddPackageToProject: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.AddPackageToProject(LPath, LRuntime, LChanged,
        LReason);
    end);
  if LApplied then
    _AuditApplied('AddPackageToProject', LPath, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'AddPackageToProject: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPPackagesToolsRegistrar._HandleRemovePackageFromProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LName, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LName := _ReadString(AParams, 'PackageName');
  LDecision := _Gate(AContext, 'RemovePackageFromProject',
    'Remove package reference from project:', LName, 'low');
  if LDecision = cdDenied then
  begin
    _AuditDenied('RemovePackageFromProject', LName);
    raise EMCPUserDenied.Create(
      'RemovePackageFromProject: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.RemovePackageFromProject(LName, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('RemovePackageFromProject', LName, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'RemovePackageFromProject: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPPackagesToolsRegistrar._HandleAddToLibraryPath(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LPath, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LPath := _ReadString(AParams, 'Path');
  // Medium consent (ADR-146): per-call prompt — global IDE mutation.
  LDecision := _Gate(AContext, 'AddToLibraryPath',
    'Add path to IDE Library Path (global mutation):', LPath, 'medium');
  if LDecision = cdDenied then
  begin
    _AuditDenied('AddToLibraryPath', LPath);
    raise EMCPUserDenied.Create(
      'AddToLibraryPath: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.AddToLibraryPath(LPath, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('AddToLibraryPath', LPath, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'AddToLibraryPath: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

procedure TMCPPackagesToolsRegistrar.RegisterAll(const AServer: IMCPServer);
var
  LSelf: TMCPPackagesToolsRegistrar;
  LLifetime: IInterface;
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPPackagesToolsRegistrar.RegisterAll: AServer');
  LSelf := Self;
  // Closures below capture LLifetime so the registrar object stays alive
  // for the lifetime of the server (the server holds the handler closures).
  LLifetime := Self;
  AServer.RegisterTool(_BuildDescriptor(
    'ListProjectPackages', 'List project packages',
    'Lists the packages (.bpl) referenced by the project',
    _SchemaEmpty, _SchemaPackageArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;  // keep registrar alive
      Result := LSelf._HandleListProjectPackages(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor(
    'AddPackageToProject', 'Add package to project',
    'Adds a package reference to the project',
    _SchemaPackagePath, _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleAddPackageToProject(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor(
    'RemovePackageFromProject', 'Remove package from project',
    'Removes a package reference from the project',
    _SchemaPackageName, _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleRemovePackageFromProject(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor(
    'GetLibraryPath', 'Get IDE Library Path',
    'Returns the global IDE Library Path (semicolon-split)',
    _SchemaEmpty, _SchemaStringArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleGetLibraryPath(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor(
    'AddToLibraryPath', 'Add to IDE Library Path',
    'Adds a path to the global IDE Library Path (Medium consent)',
    _SchemaPath, _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleAddToLibraryPath(AParams, AContext);
    end));
end;

procedure RegisterPackagesTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: TMCPPackagesToolsRegistrar;
  LIntf: IInterface;
begin
  LRegistrar := TMCPPackagesToolsRegistrar.Create(AFacade, nil, nil);
  LIntf := LRegistrar;
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterPackagesTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: TMCPPackagesToolsRegistrar;
  LIntf: IInterface;
begin
  LRegistrar := TMCPPackagesToolsRegistrar.Create(AFacade, AConsentRegistry,
    AAuditLog);
  LIntf := LRegistrar;
  LRegistrar.RegisterAll(AServer);
end;

end.
