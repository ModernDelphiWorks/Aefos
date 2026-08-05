unit Aefos.MCP.Tools.Resources;

(*
  Resources MCP tools (ESP-002, Epic 7/7 Demand 8/8).

  Catalog rows: docs/mcp-catalog/catalog.json — group "Resources",
  verdict "new". 3 tools (2 reads + 1 consent-gated write):
    ListProjectResources, AddResourceFile, ListProjectImages.

  Layering (ADR-115 / ADR-145):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterResourcesTools(AServer, AFacade).

  Gating (ADR-146):
    - AddResourceFile  Low (session-wide). Guarded by `.res`/`.rc`
                       extension validator -> `resource-extension-invalid`.
*)

interface

uses
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.Tools.Common,
  Aefos.MCP.Server;

procedure RegisterResourcesTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterResourcesTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils,
  System.JSON;

type
  TMCPResourcesToolsRegistrar = class(TMCPToolsRegistrarBase)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsent: IMCPConsentRegistry;
    FAudit: IMCPAuditLog;
    function _Gate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    procedure _AuditDenied(const AToolName, AArgs: string);
    procedure _AuditApplied(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    function _SchemaEmpty: TJSONObject;
    function _SchemaFilePath: TJSONObject;
    function _SchemaResourceArray: TJSONObject;
    function _SchemaStringArray: TJSONObject;
    function _SchemaAppliedChanged: TJSONObject;
    function _ResultResources(
      const AResources: TArray<TMCPRecordProjectResource>): TMCPToolResult;
    function _ResultStringArray(
      const AValues: TArray<string>): TMCPToolResult;
    function _ResultAppliedChanged(const AApplied,
      AChanged: Boolean): TMCPToolResult;
    function _HandleListProjectResources(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddResourceFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleListProjectImages(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry;
      const AAudit: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPResourcesToolsRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create(
      'TMCPResourcesToolsRegistrar: AFacade');
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

function TMCPResourcesToolsRegistrar._Gate(const AContext: IMCPToolContext;
  const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
var
  LDecision: TMCPConsentDecision;
begin
  if FConsent.IsSessionAllowed(AToolName) then
    Exit(cdAllowSession);
  LDecision := cdDenied;
  AContext.MarshalToMainThread(
    procedure
    begin
      LDecision := FFacade.RequestConsent(AToolName, ASummary, ADetail);
    end);
  if LDecision = cdAllowSession then
    FConsent.GrantSession(AToolName);
  Result := LDecision;
end;

procedure TMCPResourcesToolsRegistrar._AuditDenied(
  const AToolName, AArgs: string);
begin
  FAudit.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPResourcesToolsRegistrar._AuditApplied(
  const AToolName, AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'applied');
end;

function TMCPResourcesToolsRegistrar._SchemaEmpty: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

function TMCPResourcesToolsRegistrar._SchemaFilePath: TJSONObject;
var
  LProps, LField: TJSONObject;
  LReq: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('FilePath', LField);
  Result.AddPair('properties', LProps);
  LReq := TJSONArray.Create;
  LReq.Add('FilePath');
  Result.AddPair('required', LReq);
end;

function TMCPResourcesToolsRegistrar._SchemaResourceArray: TJSONObject;
var
  LProps, LValue, LItem, LItemProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create; LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create; LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('path', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('kind', LField);
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function TMCPResourcesToolsRegistrar._SchemaStringArray: TJSONObject;
var
  LProps, LValue, LItem: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create; LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create; LItem.AddPair('type', 'string');
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function TMCPResourcesToolsRegistrar._SchemaAppliedChanged: TJSONObject;
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

function TMCPResourcesToolsRegistrar._ResultResources(
  const AResources: TArray<TMCPRecordProjectResource>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AResources) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('path', AResources[LFor].Path);
      LItem.AddPair('kind', AResources[LFor].Kind);
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPResourcesToolsRegistrar._ResultStringArray(
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

function TMCPResourcesToolsRegistrar._ResultAppliedChanged(const AApplied,
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

function TMCPResourcesToolsRegistrar._HandleListProjectResources(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LResources: TArray<TMCPRecordProjectResource>;
begin
  SetLength(LResources, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LResources := FFacade.ListProjectResources;
    end);
  Result := _ResultResources(LResources);
end;

function TMCPResourcesToolsRegistrar._HandleAddResourceFile(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFilePath, LReason: string;
  LExt: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LFilePath := _ReadString(AParams, 'FilePath');
  // Early guard: invalid extension surfaces before the consent prompt
  // so the maintainer is not asked to approve an unmappable mutation.
  LExt := LowerCase(ExtractFileExt(LFilePath));
  if (LExt <> '.res') and (LExt <> '.rc') then
    raise EMCPInvalidParams.Create(
      'AddResourceFile: resource-extension-invalid'
      + '; data.detail={"reason":"resource-extension-invalid"}');
  LDecision := _Gate(AContext, 'AddResourceFile',
    'Add resource file to project:', LFilePath);
  if LDecision = cdDenied then
  begin
    _AuditDenied('AddResourceFile', LFilePath);
    raise EMCPUserDenied.Create(
      'AddResourceFile: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.AddResourceFile(LFilePath, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('AddResourceFile', LFilePath, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'AddResourceFile: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPResourcesToolsRegistrar._HandleListProjectImages(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValues: TArray<string>;
begin
  SetLength(LValues, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LValues := FFacade.ListProjectImages;
    end);
  Result := _ResultStringArray(LValues);
end;

procedure TMCPResourcesToolsRegistrar.RegisterAll(const AServer: IMCPServer);
var
  LSelf: TMCPResourcesToolsRegistrar;
  LLifetime: IInterface;
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPResourcesToolsRegistrar.RegisterAll: AServer');
  LSelf := Self;
  LLifetime := Self;
  AServer.RegisterTool(_BuildDescriptor('ListProjectResources',
    'List project resources',
    'Lists the project .res / .rc files',
    _SchemaEmpty, _SchemaResourceArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleListProjectResources(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('AddResourceFile',
    'Add resource file',
    'Adds a .res / .rc file to the project (consent Low)',
    _SchemaFilePath, _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleAddResourceFile(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('ListProjectImages',
    'List project images',
    'Lists the project image files (png/jpg/jpeg/bmp/gif/ico)',
    _SchemaEmpty, _SchemaStringArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleListProjectImages(AParams, AContext);
    end));
end;

procedure RegisterResourcesTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: TMCPResourcesToolsRegistrar;
  LIntf: IInterface;
begin
  LRegistrar := TMCPResourcesToolsRegistrar.Create(AFacade, nil, nil);
  LIntf := LRegistrar;
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterResourcesTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: TMCPResourcesToolsRegistrar;
  LIntf: IInterface;
begin
  LRegistrar := TMCPResourcesToolsRegistrar.Create(AFacade, AConsentRegistry,
    AAuditLog);
  LIntf := LRegistrar;
  LRegistrar.RegisterAll(AServer);
end;

end.
