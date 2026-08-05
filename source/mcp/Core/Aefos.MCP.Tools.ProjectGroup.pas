unit Aefos.MCP.Tools.ProjectGroup;

(*
  Project Group MCP tools (ESP-002, Epic 7/7 Demand 7/8).

  Catalog rows: docs/mcp-catalog/catalog.json — group "Project Group",
  verdict "new". 6 tools (2 reads + 4 consent-gated writes):
    GetProjectGroupName, ListProjectsInGroup,
    SetActiveProject, AddProjectToGroup, RemoveProjectFromGroup,
    BuildAllInGroup.

  BR-7: GetActiveProject is NOT registered here — the shipped 11-tool baseline
  already exposes it under the same name. Catalog row `verdict=existing`.

  Layering (ADR-115 / ADR-142):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterProjectGroupTools(AServer, AFacade), called
      from the bootstrap after the Code Insight registration.

  Gating (BR-2 / ADR-144):
    - Reads (GetProjectGroupName, ListProjectsInGroup): direct facade call,
      no consent.
    - Writes (SetActiveProject, AddProjectToGroup, RemoveProjectFromGroup,
      BuildAllInGroup) — risk Low, EMCPUserDenied on denial.
    - BuildAllInGroup NEVER short-circuits per ADR-144. A single failing
      project produces a {success:false} row; the rest of the group still
      builds. Result shape: [{project, success, errors[]}].
*)

interface

uses
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.Tools.Common,
  Aefos.MCP.Server;

type
  IMCPProjectGroupToolsDispatch = interface
    ['{4E5B9D10-2A7E-4F0B-A8C5-8E1A3F7C45B0}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleGetProjectGroupName(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleListProjectsInGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetActiveProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleAddProjectToGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRemoveProjectFromGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleBuildAllInGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

procedure RegisterProjectGroupTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterProjectGroupTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils;

type
  TMCPProjectGroupToolsRegistrar = class(TMCPToolsRegistrarBase,
    IMCPProjectGroupToolsDispatch)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsent: IMCPConsentRegistry;
    FAudit: IMCPAuditLog;
    function _RequestGate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    procedure _AuditDenied(const AToolName, AArgs: string);
    procedure _AuditApplied(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    procedure _AuditFailed(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    // Schema builders.
    function _SchemaEmpty: TJSONObject;
    function _SchemaProjectPath: TJSONObject;
    function _SchemaStringResult: TJSONObject;
    function _SchemaProjectArray: TJSONObject;
    function _SchemaAppliedChangedResult: TJSONObject;
    function _SchemaBuildArray: TJSONObject;
    // Result builders.
    function _ResultString(const AValue: string): TMCPToolResult;
    function _ResultProjects(
      const AProjects: TArray<TMCPRecordGroupProject>): TMCPToolResult;
    function _ResultAppliedChanged(const AApplied,
      AChanged: Boolean): TMCPToolResult;
    function _ResultBuildArray(
      const AResults: TArray<TMCPRecordGroupBuildResult>): TMCPToolResult;
    // Param readers.
    // Handlers.
    function _HandleGetProjectGroupName(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleListProjectsInGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetActiveProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddProjectToGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRemoveProjectFromGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleBuildAllInGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function IMCPProjectGroupToolsDispatch.HandleGetProjectGroupName =
      _HandleGetProjectGroupName;
    function IMCPProjectGroupToolsDispatch.HandleListProjectsInGroup =
      _HandleListProjectsInGroup;
    function IMCPProjectGroupToolsDispatch.HandleSetActiveProject =
      _HandleSetActiveProject;
    function IMCPProjectGroupToolsDispatch.HandleAddProjectToGroup =
      _HandleAddProjectToGroup;
    function IMCPProjectGroupToolsDispatch.HandleRemoveProjectFromGroup =
      _HandleRemoveProjectFromGroup;
    function IMCPProjectGroupToolsDispatch.HandleBuildAllInGroup =
      _HandleBuildAllInGroup;
    // Descriptor builders.
    function _BuildGetProjectGroupName: TMCPToolDescriptor;
    function _BuildListProjectsInGroup: TMCPToolDescriptor;
    function _BuildSetActiveProject: TMCPToolDescriptor;
    function _BuildAddProjectToGroup: TMCPToolDescriptor;
    function _BuildRemoveProjectFromGroup: TMCPToolDescriptor;
    function _BuildBuildAllInGroup: TMCPToolDescriptor;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry;
      const AAudit: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPProjectGroupToolsRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create(
      'TMCPProjectGroupToolsRegistrar: AFacade');
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

procedure TMCPProjectGroupToolsRegistrar.RegisterAll(
  const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPProjectGroupToolsRegistrar.RegisterAll: AServer');
  AServer.RegisterTool(_BuildGetProjectGroupName);
  AServer.RegisterTool(_BuildListProjectsInGroup);
  AServer.RegisterTool(_BuildSetActiveProject);
  AServer.RegisterTool(_BuildAddProjectToGroup);
  AServer.RegisterTool(_BuildRemoveProjectFromGroup);
  AServer.RegisterTool(_BuildBuildAllInGroup);
end;

// ── Consent / audit shared helpers ───────────────────────────────────

function TMCPProjectGroupToolsRegistrar._RequestGate(
  const AContext: IMCPToolContext;
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

procedure TMCPProjectGroupToolsRegistrar._AuditDenied(
  const AToolName, AArgs: string);
begin
  FAudit.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPProjectGroupToolsRegistrar._AuditApplied(
  const AToolName, AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'applied');
end;

procedure TMCPProjectGroupToolsRegistrar._AuditFailed(
  const AToolName, AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'failed');
end;

// ── Schema builders ───────────────────────────────────────────────────

function TMCPProjectGroupToolsRegistrar._SchemaEmpty: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

function TMCPProjectGroupToolsRegistrar._SchemaProjectPath: TJSONObject;
var
  LProps, LField: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create;
  LField.AddPair('type', 'string');
  LField.AddPair('description', 'Absolute .dproj path.');
  LProps.AddPair('ProjectPath', LField);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('ProjectPath');
  Result.AddPair('required', LRequired);
end;

function TMCPProjectGroupToolsRegistrar._SchemaStringResult: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create;
  LField.AddPair('type', 'string');
  LProps.AddPair('value', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPProjectGroupToolsRegistrar._SchemaProjectArray: TJSONObject;
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
  LItemProps.AddPair('active', LField);
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function TMCPProjectGroupToolsRegistrar._SchemaAppliedChangedResult: TJSONObject;
var
  LProps, LApplied, LChanged: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LApplied := TJSONObject.Create; LApplied.AddPair('type', 'boolean');
  LProps.AddPair('applied', LApplied);
  LChanged := TJSONObject.Create; LChanged.AddPair('type', 'boolean');
  LProps.AddPair('changed', LChanged);
  Result.AddPair('properties', LProps);
end;

function TMCPProjectGroupToolsRegistrar._SchemaBuildArray: TJSONObject;
var
  LProps, LValue, LItem, LItemProps, LField, LErrors, LErrItem: TJSONObject;
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
  LItemProps.AddPair('project', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'boolean');
  LItemProps.AddPair('success', LField);
  LErrors := TJSONObject.Create; LErrors.AddPair('type', 'array');
  LErrItem := TJSONObject.Create; LErrItem.AddPair('type', 'string');
  LErrors.AddPair('items', LErrItem);
  LItemProps.AddPair('errors', LErrors);
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

// ── Result builders ───────────────────────────────────────────────────

function TMCPProjectGroupToolsRegistrar._ResultString(
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

function TMCPProjectGroupToolsRegistrar._ResultProjects(
  const AProjects: TArray<TMCPRecordGroupProject>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AProjects) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('name', AProjects[LFor].Name);
      LItem.AddPair('path', AProjects[LFor].Path);
      LItem.AddPair('active', TJSONBool.Create(AProjects[LFor].Active));
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPProjectGroupToolsRegistrar._ResultAppliedChanged(const AApplied,
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

function TMCPProjectGroupToolsRegistrar._ResultBuildArray(
  const AResults: TArray<TMCPRecordGroupBuildResult>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr, LErrors: TJSONArray;
  LFor, LErrIdx: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AResults) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('project', AResults[LFor].Project);
      LItem.AddPair('success', TJSONBool.Create(AResults[LFor].Success));
      LErrors := TJSONArray.Create;
      for LErrIdx := 0 to High(AResults[LFor].Errors) do
        LErrors.Add(AResults[LFor].Errors[LErrIdx]);
      LItem.AddPair('errors', LErrors);
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

// ── Param readers ─────────────────────────────────────────────────────

// ── Handlers ──────────────────────────────────────────────────────────

function TMCPProjectGroupToolsRegistrar._HandleGetProjectGroupName(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetProjectGroupName;
    end);
  Result := _ResultString(LValue);
end;

function TMCPProjectGroupToolsRegistrar._HandleListProjectsInGroup(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LProjects: TArray<TMCPRecordGroupProject>;
begin
  SetLength(LProjects, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LProjects := FFacade.ListProjectsInGroup;
    end);
  Result := _ResultProjects(LProjects);
end;

function TMCPProjectGroupToolsRegistrar._HandleSetActiveProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LPath, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LPath := _ReadString(AParams, 'ProjectPath');
  LDecision := _RequestGate(AContext, 'SetActiveProject',
    'Switch active project in group to:', LPath);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetActiveProject', LPath);
    raise EMCPUserDenied.Create(
      'SetActiveProject: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetActiveProject(LPath, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('SetActiveProject', LPath, LDecision)
  else
    _AuditFailed('SetActiveProject', LPath + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'SetActiveProject: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPProjectGroupToolsRegistrar._HandleAddProjectToGroup(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LPath, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LPath := _ReadString(AParams, 'ProjectPath');
  LDecision := _RequestGate(AContext, 'AddProjectToGroup',
    'Add project to group:', LPath);
  if LDecision = cdDenied then
  begin
    _AuditDenied('AddProjectToGroup', LPath);
    raise EMCPUserDenied.Create(
      'AddProjectToGroup: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.AddProjectToGroup(LPath, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('AddProjectToGroup', LPath, LDecision)
  else
    _AuditFailed('AddProjectToGroup', LPath + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'AddProjectToGroup: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPProjectGroupToolsRegistrar._HandleRemoveProjectFromGroup(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LPath, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LPath := _ReadString(AParams, 'ProjectPath');
  LDecision := _RequestGate(AContext, 'RemoveProjectFromGroup',
    'Remove project from group:', LPath);
  if LDecision = cdDenied then
  begin
    _AuditDenied('RemoveProjectFromGroup', LPath);
    raise EMCPUserDenied.Create(
      'RemoveProjectFromGroup: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.RemoveProjectFromGroup(LPath, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('RemoveProjectFromGroup', LPath, LDecision)
  else
    _AuditFailed('RemoveProjectFromGroup', LPath + '|' + LReason,
      LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'RemoveProjectFromGroup: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPProjectGroupToolsRegistrar._HandleBuildAllInGroup(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
  LResults: TArray<TMCPRecordGroupBuildResult>;
begin
  LDecision := _RequestGate(AContext, 'BuildAllInGroup',
    'Build every project in the active group.', '');
  if LDecision = cdDenied then
  begin
    _AuditDenied('BuildAllInGroup', '');
    raise EMCPUserDenied.Create('BuildAllInGroup: user denied the action');
  end;
  LApplied := False;
  LReason := '';
  SetLength(LResults, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.BuildAllInGroup(LResults, LReason);
    end);
  if LApplied then
    _AuditApplied('BuildAllInGroup', '', LDecision)
  else
    _AuditFailed('BuildAllInGroup', LReason, LDecision);
  // ADR-144: BuildAllInGroup NEVER short-circuits at the protocol level.
  // The result array is the contract. `LApplied=False` only happens on
  // orchestration failures (no group open, IOTAProjectGroup nil) — surface
  // those via data.reason; per-project failures live inside `errors[]`.
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'BuildAllInGroup: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultBuildArray(LResults);
end;

// ── Descriptor builders ───────────────────────────────────────────────

function TMCPProjectGroupToolsRegistrar._BuildGetProjectGroupName: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectGroupToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('GetProjectGroupName', 'Get project group name',
    'Returns the name of the project group (.groupproj)',
    _SchemaEmpty, _SchemaStringResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetProjectGroupName(AParams, AContext);
    end);
end;

function TMCPProjectGroupToolsRegistrar._BuildListProjectsInGroup: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectGroupToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('ListProjectsInGroup', 'List projects in group',
    'Lists every project in the current group',
    _SchemaEmpty, _SchemaProjectArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleListProjectsInGroup(AParams, AContext);
    end);
end;

function TMCPProjectGroupToolsRegistrar._BuildSetActiveProject: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectGroupToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('SetActiveProject', 'Set active project',
    'Sets the active project in the group',
    _SchemaProjectPath, _SchemaAppliedChangedResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetActiveProject(AParams, AContext);
    end);
end;

function TMCPProjectGroupToolsRegistrar._BuildAddProjectToGroup: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectGroupToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('AddProjectToGroup', 'Add project to group',
    'Adds an existing project to the group',
    _SchemaProjectPath, _SchemaAppliedChangedResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleAddProjectToGroup(AParams, AContext);
    end);
end;

function TMCPProjectGroupToolsRegistrar._BuildRemoveProjectFromGroup: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectGroupToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('RemoveProjectFromGroup',
    'Remove project from group',
    'Removes a project from the group',
    _SchemaProjectPath, _SchemaAppliedChangedResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRemoveProjectFromGroup(AParams, AContext);
    end);
end;

function TMCPProjectGroupToolsRegistrar._BuildBuildAllInGroup: TMCPToolDescriptor;
var
  LDispatch: IMCPProjectGroupToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('BuildAllInGroup', 'Build all in group',
    'Builds every project in the group',
    _SchemaEmpty, _SchemaBuildArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleBuildAllInGroup(AParams, AContext);
    end);
end;

// ── Public entries ────────────────────────────────────────────────────

procedure RegisterProjectGroupTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: IMCPProjectGroupToolsDispatch;
begin
  LRegistrar := TMCPProjectGroupToolsRegistrar.Create(AFacade, nil, nil);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterProjectGroupTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPProjectGroupToolsDispatch;
begin
  LRegistrar := TMCPProjectGroupToolsRegistrar.Create(AFacade,
    AConsentRegistry, AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

end.
