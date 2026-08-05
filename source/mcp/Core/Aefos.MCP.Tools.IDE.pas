unit Aefos.MCP.Tools.IDE;

(*
  IDE MCP tools (ESP-002, Epic 7/7 Demand 8/8).

  Catalog rows: docs/mcp-catalog/catalog.json — group "IDE", verdict "new".
  8 tools (4 reads + 4 consent-gated writes):
    GetIDEVersion, ShowMessage, GetIDETheme, ExecuteIDEAction,
    GetProjectManagerTree, RefreshProjectManager, GetRecentFiles,
    RunExternalTool.

  Layering (ADR-115 / ADR-145):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterIDETools(AServer, AFacade).

  Gating (ADR-146):
    - ShowMessage           Low.
    - ExecuteIDEAction      Low.
    - RefreshProjectManager Low.
    - RunExternalTool       Medium (per-call prompt — external process).
*)

interface

uses
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.Tools.Common,
  Aefos.MCP.Server;

procedure RegisterIDETools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterIDETools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils,
  System.JSON;

type
  TMCPIDEToolsRegistrar = class(TMCPToolsRegistrarBase)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsent: IMCPConsentRegistry;
    FAudit: IMCPAuditLog;
    function _Gate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail, ARisk: string): TMCPConsentDecision;
    procedure _AuditDenied(const AToolName, AArgs: string);
    procedure _AuditApplied(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    function _ReadBoolDefault(const AParams: TJSONObject;
      const AName: string; const ADefault: Boolean): Boolean;
    function _ReadStringArray(const AParams: TJSONObject;
      const AName: string): TArray<string>;
    // Schemas.
    function _SchemaEmpty: TJSONObject;
    function _SchemaText: TJSONObject;
    function _SchemaActionName: TJSONObject;
    function _SchemaArgv: TJSONObject;
    function _SchemaIDEVersion: TJSONObject;
    function _SchemaStringResult: TJSONObject;
    function _SchemaStringArray: TJSONObject;
    function _SchemaShown: TJSONObject;
    function _SchemaAppliedFlag: TJSONObject;
    function _SchemaTree: TJSONObject;
    function _SchemaExternalRun: TJSONObject;
    function _SchemaActionFilter: TJSONObject;
    function _SchemaActionCatalog: TJSONObject;
    // Result builders.
    function _ResultIDEVersion(
      const AInfo: TMCPRecordIDEVersion): TMCPToolResult;
    function _ResultShown: TMCPToolResult;
    function _ResultStringResult(const AValue: string): TMCPToolResult;
    function _ResultApplied(const AApplied: Boolean): TMCPToolResult;
    function _ResultStringArray(
      const AValues: TArray<string>): TMCPToolResult;
    function _ResultTree(
      const ATree: TArray<TMCPRecordProjectManagerNode>): TMCPToolResult;
    function _ResultExternalRun(
      const ARun: TMCPRecordExternalToolRun): TMCPToolResult;
    procedure _AppendTreeNode(const ANode: TMCPRecordProjectManagerNode;
      const AArr: TJSONArray);
    // Handlers.
    function _HandleGetIDEVersion(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleShowMessage(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetIDETheme(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleExecuteIDEAction(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleListIDEActions(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetProjectManagerTree(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRefreshProjectManager(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetRecentFiles(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRunExternalTool(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry;
      const AAudit: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPIDEToolsRegistrar.Create(const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TMCPIDEToolsRegistrar: AFacade');
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

function TMCPIDEToolsRegistrar._Gate(const AContext: IMCPToolContext;
  const AToolName, ASummary, ADetail, ARisk: string): TMCPConsentDecision;
var
  LDecision: TMCPConsentDecision;
begin
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

procedure TMCPIDEToolsRegistrar._AuditDenied(const AToolName,
  AArgs: string);
begin
  FAudit.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPIDEToolsRegistrar._AuditApplied(const AToolName,
  AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'applied');
end;

function TMCPIDEToolsRegistrar._ReadBoolDefault(const AParams: TJSONObject;
  const AName: string; const ADefault: Boolean): Boolean;
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

function TMCPIDEToolsRegistrar._ReadStringArray(const AParams: TJSONObject;
  const AName: string): TArray<string>;
var
  LValue: TJSONValue;
  LArr: TJSONArray;
  LFor: Integer;
begin
  SetLength(Result, 0);
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create(AName + ' required');
  LValue := AParams.GetValue(AName);
  if not (Assigned(LValue) and (LValue is TJSONArray)) then
    raise EMCPInvalidParams.Create(AName + ' required (array)');
  LArr := TJSONArray(LValue);
  SetLength(Result, LArr.Count);
  for LFor := 0 to LArr.Count - 1 do
    Result[LFor] := (LArr.Items[LFor] as TJSONString).Value;
end;

function TMCPIDEToolsRegistrar._SchemaEmpty: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

function TMCPIDEToolsRegistrar._SchemaText: TJSONObject;
var
  LProps, LField: TJSONObject;
  LReq: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('Text', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'boolean');
  LProps.AddPair('UseOutput', LField);
  Result.AddPair('properties', LProps);
  LReq := TJSONArray.Create;
  LReq.Add('Text');
  Result.AddPair('required', LReq);
end;

function TMCPIDEToolsRegistrar._SchemaActionName: TJSONObject;
var
  LProps, LField: TJSONObject;
  LReq: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('ActionName', LField);
  Result.AddPair('properties', LProps);
  LReq := TJSONArray.Create;
  LReq.Add('ActionName');
  Result.AddPair('required', LReq);
end;

function TMCPIDEToolsRegistrar._SchemaActionFilter: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create;
  LField.AddPair('type', 'string');
  LField.AddPair('description',
    'Optional case-insensitive substring matched against the action name, '
    + 'caption or category. Omit or leave empty to return the full catalog.');
  LProps.AddPair('filter', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPIDEToolsRegistrar._SchemaActionCatalog: TJSONObject;
var
  LProps, LArr, LItems, LItemProps, LField, LCount: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LArr := TJSONObject.Create;
  LArr.AddPair('type', 'array');
  LItems := TJSONObject.Create;
  LItems.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('name', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('caption', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('category', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('shortcut', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('hint', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'boolean');
  LItemProps.AddPair('enabled', LField);
  LItems.AddPair('properties', LItemProps);
  LArr.AddPair('items', LItems);
  LProps.AddPair('actions', LArr);
  LCount := TJSONObject.Create; LCount.AddPair('type', 'integer');
  LProps.AddPair('count', LCount);
  Result.AddPair('properties', LProps);
end;

function TMCPIDEToolsRegistrar._SchemaArgv: TJSONObject;
var
  LProps, LField, LItem: TJSONObject;
  LArr: TJSONObject;
  LReq: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LArr := TJSONObject.Create;
  LArr.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'string');
  LArr.AddPair('items', LItem);
  LProps.AddPair('Argv', LArr);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('ToolName', LField);
  Result.AddPair('properties', LProps);
  LReq := TJSONArray.Create;
  LReq.Add('Argv');
  Result.AddPair('required', LReq);
end;

function TMCPIDEToolsRegistrar._SchemaIDEVersion: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('product', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('version', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('build', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPIDEToolsRegistrar._SchemaStringResult: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('value', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPIDEToolsRegistrar._SchemaStringArray: TJSONObject;
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

function TMCPIDEToolsRegistrar._SchemaShown: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'boolean');
  LProps.AddPair('shown', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPIDEToolsRegistrar._SchemaAppliedFlag: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'boolean');
  LProps.AddPair('applied', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPIDEToolsRegistrar._SchemaTree: TJSONObject;
var
  LProps, LValue, LItem: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create; LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create; LItem.AddPair('type', 'object');
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function TMCPIDEToolsRegistrar._SchemaExternalRun: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'integer');
  LProps.AddPair('pid', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'integer');
  LProps.AddPair('exit_code', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('started_at', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPIDEToolsRegistrar._ResultIDEVersion(
  const AInfo: TMCPRecordIDEVersion): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('product', AInfo.Product);
    LObj.AddPair('version', AInfo.Version);
    LObj.AddPair('build', AInfo.Build);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPIDEToolsRegistrar._ResultShown: TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('shown', TJSONBool.Create(True));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPIDEToolsRegistrar._ResultStringResult(
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

function TMCPIDEToolsRegistrar._ResultApplied(
  const AApplied: Boolean): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('applied', TJSONBool.Create(AApplied));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPIDEToolsRegistrar._ResultStringArray(
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

procedure TMCPIDEToolsRegistrar._AppendTreeNode(
  const ANode: TMCPRecordProjectManagerNode; const AArr: TJSONArray);
var
  LObj: TJSONObject;
  LChildren: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  LObj.AddPair('name', ANode.Name);
  LObj.AddPair('kind', ANode.Kind);
  LChildren := TJSONArray.Create;
  for LFor := 0 to High(ANode.Children) do
    _AppendTreeNode(ANode.Children[LFor], LChildren);
  LObj.AddPair('children', LChildren);
  AArr.AddElement(LObj);
end;

function TMCPIDEToolsRegistrar._ResultTree(
  const ATree: TArray<TMCPRecordProjectManagerNode>): TMCPToolResult;
var
  LObj: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(ATree) do
      _AppendTreeNode(ATree[LFor], LArr);
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPIDEToolsRegistrar._ResultExternalRun(
  const ARun: TMCPRecordExternalToolRun): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('pid', TJSONNumber.Create(ARun.Pid));
    if ARun.ExitCodeKnown then
      LObj.AddPair('exit_code', TJSONNumber.Create(ARun.ExitCode))
    else
      LObj.AddPair('exit_code', TJSONNull.Create);
    LObj.AddPair('started_at', ARun.StartedAt);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPIDEToolsRegistrar._HandleGetIDEVersion(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LInfo: TMCPRecordIDEVersion;
begin
  LInfo := Default(TMCPRecordIDEVersion);
  AContext.MarshalToMainThread(
    procedure
    begin
      LInfo := FFacade.GetIDEVersion;
    end);
  Result := _ResultIDEVersion(LInfo);
end;

function TMCPIDEToolsRegistrar._HandleShowMessage(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LText: string;
  LUseOutput: Boolean;
  LDecision: TMCPConsentDecision;
begin
  LText := _ReadString(AParams, 'Text');
  LUseOutput := _ReadBoolDefault(AParams, 'UseOutput', False);
  LDecision := _Gate(AContext, 'ShowMessage',
    'Show IDE message:', LText, 'low');
  if LDecision = cdDenied then
  begin
    _AuditDenied('ShowMessage', LText);
    raise EMCPUserDenied.Create('ShowMessage: user denied the action');
  end;
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.ShowIDEMessage(LText, LUseOutput);
    end);
  _AuditApplied('ShowMessage', LText, LDecision);
  // BR-6: return immediately after queuing — non-blocking.
  Result := _ResultShown;
end;

function TMCPIDEToolsRegistrar._HandleGetIDETheme(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := 'system';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetIDETheme;
    end);
  Result := _ResultStringResult(LValue);
end;

function TMCPIDEToolsRegistrar._HandleListIDEActions(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFilter, LJson: string;
  LVal: TJSONValue;
begin
  // Read-only: optional 'filter' substring; no consent gate.
  LFilter := '';
  if Assigned(AParams) then
  begin
    LVal := AParams.GetValue('filter');
    if LVal is TJSONString then
      LFilter := TJSONString(LVal).Value;
  end;
  LJson := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LJson := FFacade.ListIDEActions(LFilter);
    end);
  Result := TMCPToolResult.Text(LJson);
end;

function TMCPIDEToolsRegistrar._HandleExecuteIDEAction(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LActionName, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LActionName := _ReadString(AParams, 'ActionName');
  LDecision := _Gate(AContext, 'ExecuteIDEAction',
    'Execute IDE action:', LActionName, 'low');
  if LDecision = cdDenied then
  begin
    _AuditDenied('ExecuteIDEAction', LActionName);
    raise EMCPUserDenied.Create(
      'ExecuteIDEAction: user denied the action');
  end;
  LApplied := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.ExecuteIDEAction(LActionName, LReason);
    end);
  if LApplied then
    _AuditApplied('ExecuteIDEAction', LActionName, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'ExecuteIDEAction: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultApplied(LApplied);
end;

function TMCPIDEToolsRegistrar._HandleGetProjectManagerTree(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LTree: TArray<TMCPRecordProjectManagerNode>;
begin
  SetLength(LTree, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LTree := FFacade.GetProjectManagerTree;
    end);
  Result := _ResultTree(LTree);
end;

function TMCPIDEToolsRegistrar._HandleRefreshProjectManager(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LDecision := _Gate(AContext, 'RefreshProjectManager',
    'Refresh Project Manager view', '', 'low');
  if LDecision = cdDenied then
  begin
    _AuditDenied('RefreshProjectManager', '');
    raise EMCPUserDenied.Create(
      'RefreshProjectManager: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.RefreshProjectManager;
    end);
  _AuditApplied('RefreshProjectManager', '', LDecision);
  Result := _ResultApplied(LApplied);
end;

function TMCPIDEToolsRegistrar._HandleGetRecentFiles(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFiles: TArray<string>;
begin
  SetLength(LFiles, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LFiles := FFacade.GetRecentFiles;
    end);
  Result := _ResultStringArray(LFiles);
end;

function TMCPIDEToolsRegistrar._HandleRunExternalTool(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LArgv: TArray<string>;
  LReason: string;
  LDecision: TMCPConsentDecision;
  LRun: TMCPRecordExternalToolRun;
  LApplied: Boolean;
  LArgsAudit: string;
  LConsentDetail: string;
  LFor: Integer;
begin
  LArgv := _ReadStringArray(AParams, 'Argv');
  // BR-5: audit row carries the full argv joined with U+001F separator
  // so shell-joining is not implied.
  LArgsAudit := '';
  for LFor := 0 to High(LArgv) do
  begin
    if LArgsAudit <> '' then
      LArgsAudit := LArgsAudit + #31;
    LArgsAudit := LArgsAudit + LArgv[LFor];
  end;
  // Human-readable preview: one argv element per line (NOT the U+001F-joined
  // audit string - that renders as scary boxes in the consent dialog and reads
  // as if the command were garbled). One-per-line is unambiguous AND avoids
  // implying shell-joining.
  LConsentDetail := 'argv:';
  for LFor := 0 to High(LArgv) do
    LConsentDetail := LConsentDetail + sLineBreak + '  [' + IntToStr(LFor) +
      '] ' + LArgv[LFor];
  // R11: the token block-list screens bare destructive verbs, but a command wrapped in an
  // interpreter (powershell -Command Remove-Item ...) slips past it. The per-call human consent
  // is the real gate, so raise attention in it when argv[0] is an interpreter. Audit row stays clean.
  if (Length(LArgv) > 0) and TMCPProcessGuard.IsInterpreterExe(LArgv[0]) then
    LConsentDetail := 'WARNING: spawns the interpreter "' + LArgv[0] + '", which can run ANY ' +
      'command (the block-list cannot screen a wrapped one). Read the full argv before approving.' +
      sLineBreak + sLineBreak + LConsentDetail;
  // Medium: per-call prompt — ADR-146.
  LDecision := _Gate(AContext, 'RunExternalTool',
    'Spawn external process (consent Medium):', LConsentDetail, 'medium');
  if LDecision = cdDenied then
  begin
    _AuditDenied('RunExternalTool', LArgsAudit);
    raise EMCPUserDenied.Create(
      'RunExternalTool: user denied the action');
  end;
  LRun := Default(TMCPRecordExternalToolRun);
  LReason := '';
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.RunExternalTool(LArgv, LRun, LReason);
    end);
  if LApplied then
    _AuditApplied('RunExternalTool', LArgsAudit, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'RunExternalTool: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultExternalRun(LRun);
end;

procedure TMCPIDEToolsRegistrar.RegisterAll(const AServer: IMCPServer);
var
  LSelf: TMCPIDEToolsRegistrar;
  LLifetime: IInterface;
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPIDEToolsRegistrar.RegisterAll: AServer');
  LSelf := Self;
  LLifetime := Self;
  AServer.RegisterTool(_BuildDescriptor('GetIDEVersion', 'Get IDE version',
    'Returns {product, version, build} of the IDE',
    _SchemaEmpty, _SchemaIDEVersion,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleGetIDEVersion(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('ShowMessage', 'Show IDE message',
    'Displays a message in the IDE (themed dialog or Output panel)',
    _SchemaText, _SchemaShown,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleShowMessage(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('GetIDETheme', 'Get IDE theme',
    'Returns "dark" | "light" | "system"',
    _SchemaEmpty, _SchemaStringResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleGetIDETheme(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('ExecuteIDEAction',
    'Execute IDE action',
    'Fires a named IDE TAction',
    _SchemaActionName, _SchemaAppliedFlag,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleExecuteIDEAction(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('ListIDEActions',
    'List IDE actions',
    'Lists the FULL catalog of IDE actions (INTAServices.ActionList): '
    + 'name, caption, category, shortcut, hint, enabled. Use BEFORE '
    + 'ExecuteIDEAction to DISCOVER the right name instead of guessing - e.g.: '
    + 'ViewToggleFormCommand (F12) and ViewSwapSourceFormCommand (Alt+F12) to '
    + 'switch between Form<->code and have the designer re-render the components. '
    + 'Optional "filter" param = case-insensitive substring matched on '
    + 'name/caption/category (empty = the entire catalog). Read-only. Full live '
    + 'IDE action catalog; discover the action name to pass to ExecuteIDEAction.',
    _SchemaActionFilter, _SchemaActionCatalog,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleListIDEActions(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('GetProjectManagerTree',
    'Get Project Manager tree',
    'Returns the Project Manager tree (depth-capped at 8)',
    _SchemaEmpty, _SchemaTree,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleGetProjectManagerTree(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('RefreshProjectManager',
    'Refresh Project Manager',
    'Visually refreshes the Project Manager',
    _SchemaEmpty, _SchemaAppliedFlag,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleRefreshProjectManager(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('GetRecentFiles',
    'Get recent files',
    'Returns the IDE MRU list (most-recent first)',
    _SchemaEmpty, _SchemaStringArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleGetRecentFiles(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('RunExternalTool',
    'Run external tool',
    'Runs an external process with explicit argv (consent Medium)',
    _SchemaArgv, _SchemaExternalRun,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleRunExternalTool(AParams, AContext);
    end));
end;

procedure RegisterIDETools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: TMCPIDEToolsRegistrar;
  LIntf: IInterface;
begin
  LRegistrar := TMCPIDEToolsRegistrar.Create(AFacade, nil, nil);
  LIntf := LRegistrar;
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterIDETools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: TMCPIDEToolsRegistrar;
  LIntf: IInterface;
begin
  LRegistrar := TMCPIDEToolsRegistrar.Create(AFacade, AConsentRegistry,
    AAuditLog);
  LIntf := LRegistrar;
  LRegistrar.RegisterAll(AServer);
end;

end.
