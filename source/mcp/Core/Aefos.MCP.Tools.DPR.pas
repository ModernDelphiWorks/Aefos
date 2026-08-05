unit Aefos.MCP.Tools.DPR;

(*
  DPR-group MCP tools (ESP-002, Epic 7/7 Demand 6/8).

  Catalog rows: docs/mcp-catalog/catalog.json — group "DPR",
  verdict "new". 6 tools (3 reads + 3 consent-gated writes).

  Layering (ADR-115 / ADR-139):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterDPRTools(AServer, AFacade) called from
      MCP.Server's bootstrap after the Forms & DFM-group registration.

  Gating (BR-2):
    - Reads (GetDPRContent, GetDPRUsedForms, GetMainForm): direct facade
      call, no consent.
    - Writes (SetDPRContent, RenameDPR, SetMainForm) — risk Low,
      EMCPUserDenied on denial. Atomic RenameDPR per ADR-141.
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
  IMCPDPRToolsDispatch = interface
    ['{D9C7A8B2-3F61-4C5D-9E08-6B2A1F4D7C03}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleGetDPRContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetDPRContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRenameDPR(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetDPRUsedForms(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetMainForm(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetMainForm(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

procedure RegisterDPRTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterDPRTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils;

type
  TMCPDPRToolsRegistrar = class(TMCPToolsRegistrarBase, IMCPDPRToolsDispatch)
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
    function _SchemaOneString(const AName, ADesc: string): TJSONObject;
    function _SchemaStringResult: TJSONObject;
    function _SchemaAppliedResult: TJSONObject;
    function _SchemaCreateFormArray: TJSONObject;
    // Result builders.
    function _ResultString(const AValue: string): TMCPToolResult;
    function _ResultApplied(const AApplied: Boolean): TMCPToolResult;
    function _ResultAppliedChanged(const AApplied,
      AChanged: Boolean): TMCPToolResult;
    function _ResultCreateForms(
      const AForms: TArray<TMCPRecordDPRCreateForm>): TMCPToolResult;
    // Param readers.
    // Handlers.
    function _HandleGetDPRContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetDPRContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRenameDPR(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetDPRUsedForms(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetMainForm(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetMainForm(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // IMCPDPRToolsDispatch — name-resolved aliases.
    function IMCPDPRToolsDispatch.HandleGetDPRContent = _HandleGetDPRContent;
    function IMCPDPRToolsDispatch.HandleSetDPRContent = _HandleSetDPRContent;
    function IMCPDPRToolsDispatch.HandleRenameDPR = _HandleRenameDPR;
    function IMCPDPRToolsDispatch.HandleGetDPRUsedForms = _HandleGetDPRUsedForms;
    function IMCPDPRToolsDispatch.HandleGetMainForm = _HandleGetMainForm;
    function IMCPDPRToolsDispatch.HandleSetMainForm = _HandleSetMainForm;
    function _BuildGetDPRContent: TMCPToolDescriptor;
    function _BuildSetDPRContent: TMCPToolDescriptor;
    function _BuildRenameDPR: TMCPToolDescriptor;
    function _BuildGetDPRUsedForms: TMCPToolDescriptor;
    function _BuildGetMainForm: TMCPToolDescriptor;
    function _BuildSetMainForm: TMCPToolDescriptor;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry;
      const AAudit: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPDPRToolsRegistrar.Create(const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TMCPDPRToolsRegistrar: AFacade');
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

procedure TMCPDPRToolsRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPDPRToolsRegistrar.RegisterAll: AServer');
  AServer.RegisterTool(_BuildGetDPRContent);
  AServer.RegisterTool(_BuildSetDPRContent);
  AServer.RegisterTool(_BuildRenameDPR);
  AServer.RegisterTool(_BuildGetDPRUsedForms);
  AServer.RegisterTool(_BuildGetMainForm);
  AServer.RegisterTool(_BuildSetMainForm);
end;

function TMCPDPRToolsRegistrar._RequestGate(const AContext: IMCPToolContext;
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

procedure TMCPDPRToolsRegistrar._AuditDenied(const AToolName, AArgs: string);
begin
  FAudit.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPDPRToolsRegistrar._AuditApplied(const AToolName, AArgs: string;
  const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'applied');
end;

procedure TMCPDPRToolsRegistrar._AuditFailed(const AToolName, AArgs: string;
  const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'failed');
end;

// ── Schema builders ───────────────────────────────────────────────────

function TMCPDPRToolsRegistrar._SchemaEmpty: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

function TMCPDPRToolsRegistrar._SchemaOneString(const AName,
  ADesc: string): TJSONObject;
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

function TMCPDPRToolsRegistrar._SchemaStringResult: TJSONObject;
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

function TMCPDPRToolsRegistrar._SchemaAppliedResult: TJSONObject;
var
  LProps, LApplied, LChanged: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LApplied := TJSONObject.Create;
  LApplied.AddPair('type', 'boolean');
  LProps.AddPair('applied', LApplied);
  LChanged := TJSONObject.Create;
  LChanged.AddPair('type', 'boolean');
  LProps.AddPair('changed', LChanged);
  Result.AddPair('properties', LProps);
end;

function TMCPDPRToolsRegistrar._SchemaCreateFormArray: TJSONObject;
var
  LProps, LValue, LItem, LItemProps, LCls, LVar, LUnit: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LCls := TJSONObject.Create;
  LCls.AddPair('type', 'string');
  LItemProps.AddPair('class', LCls);
  LVar := TJSONObject.Create;
  LVar.AddPair('type', 'string');
  LItemProps.AddPair('var', LVar);
  LUnit := TJSONObject.Create;
  LUnit.AddPair('type', 'string');
  LItemProps.AddPair('unit', LUnit);
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

// ── Result builders ───────────────────────────────────────────────────

function TMCPDPRToolsRegistrar._ResultString(
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

function TMCPDPRToolsRegistrar._ResultApplied(
  const AApplied: Boolean): TMCPToolResult;
begin
  if AApplied then
    Result := TMCPToolResult.Text('{"applied":true}')
  else
    Result := TMCPToolResult.Text('{"applied":false}');
end;

function TMCPDPRToolsRegistrar._ResultAppliedChanged(const AApplied,
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

function TMCPDPRToolsRegistrar._ResultCreateForms(
  const AForms: TArray<TMCPRecordDPRCreateForm>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AForms) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('class', AForms[LFor].FormClass);
      LItem.AddPair('var', AForms[LFor].FormVar);
      LItem.AddPair('unit', AForms[LFor].UnitName);
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

function TMCPDPRToolsRegistrar._HandleGetDPRContent(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetDPRContent;
    end);
  Result := _ResultString(LValue);
end;

function TMCPDPRToolsRegistrar._HandleSetDPRContent(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LSource, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LSource := _ReadString(AParams, 'Source');
  LDecision := _RequestGate(AContext, 'SetDPRContent',
    'Overwrite the active project''s .dpr source.', '');
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetDPRContent', '');
    raise EMCPUserDenied.Create('SetDPRContent: user denied the action');
  end;
  LApplied := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetDPRContent(LSource, LReason);
    end);
  if LApplied then
    _AuditApplied('SetDPRContent', '', LDecision)
  else
    _AuditFailed('SetDPRContent', LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'SetDPRContent: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultApplied(LApplied);
end;

function TMCPDPRToolsRegistrar._HandleRenameDPR(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LNewName, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LNewName := _ReadString(AParams, 'NewName');
  if Trim(LNewName) = '' then
    raise EMCPInvalidParams.Create(
      'RenameDPR: NewName rejected; data.detail={"reason":"empty-name"}');
  LDecision := _RequestGate(AContext, 'RenameDPR',
    'Rename the active project''s .dpr file:', LNewName);
  if LDecision = cdDenied then
  begin
    _AuditDenied('RenameDPR', LNewName);
    raise EMCPUserDenied.Create('RenameDPR: user denied the action');
  end;
  LApplied := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.RenameDPR(LNewName, LReason);
    end);
  if LApplied then
    _AuditApplied('RenameDPR', LNewName, LDecision)
  else
    _AuditFailed('RenameDPR', LNewName + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'RenameDPR: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultApplied(LApplied);
end;

function TMCPDPRToolsRegistrar._HandleGetDPRUsedForms(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LForms: TArray<TMCPRecordDPRCreateForm>;
begin
  SetLength(LForms, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LForms := FFacade.GetDPRUsedForms;
    end);
  Result := _ResultCreateForms(LForms);
end;

function TMCPDPRToolsRegistrar._HandleGetMainForm(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LValue: string;
begin
  LValue := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LValue := FFacade.GetMainForm;
    end);
  Result := _ResultString(LValue);
end;

function TMCPDPRToolsRegistrar._HandleSetMainForm(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFormClass, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LFormClass := _ReadString(AParams, 'FormClass');
  if Trim(LFormClass) = '' then
    raise EMCPInvalidParams.Create(
      'SetMainForm: FormClass rejected; data.detail={"reason":"empty-name"}');
  LDecision := _RequestGate(AContext, 'SetMainForm',
    'Promote form to main:', LFormClass);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetMainForm', LFormClass);
    raise EMCPUserDenied.Create('SetMainForm: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetMainForm(LFormClass, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('SetMainForm', LFormClass, LDecision)
  else
    _AuditFailed('SetMainForm', LFormClass + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'SetMainForm: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

// ── Descriptor builders ───────────────────────────────────────────────

function TMCPDPRToolsRegistrar._BuildGetDPRContent: TMCPToolDescriptor;
var
  LDispatch: IMCPDPRToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('GetDPRContent', 'Get DPR content',
    'Returns the full contents of the .dpr file',
    _SchemaEmpty, _SchemaStringResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetDPRContent(AParams, AContext);
    end);
end;

function TMCPDPRToolsRegistrar._BuildSetDPRContent: TMCPToolDescriptor;
var
  LDispatch: IMCPDPRToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('SetDPRContent', 'Set DPR content',
    'Replaces the contents of the .dpr file',
    _SchemaOneString('Source', 'New .dpr source text.'),
    _SchemaAppliedResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetDPRContent(AParams, AContext);
    end);
end;

function TMCPDPRToolsRegistrar._BuildRenameDPR: TMCPToolDescriptor;
var
  LDispatch: IMCPDPRToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('RenameDPR', 'Rename DPR',
    'Renames the .dpr file and updates references',
    _SchemaOneString('NewName', 'New base name (with or without .dpr ext).'),
    _SchemaAppliedResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRenameDPR(AParams, AContext);
    end);
end;

function TMCPDPRToolsRegistrar._BuildGetDPRUsedForms: TMCPToolDescriptor;
var
  LDispatch: IMCPDPRToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('GetDPRUsedForms', 'Get DPR used forms',
    'Returns the list of forms registered via Application.CreateForm in the .dpr',
    _SchemaEmpty, _SchemaCreateFormArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetDPRUsedForms(AParams, AContext);
    end);
end;

function TMCPDPRToolsRegistrar._BuildGetMainForm: TMCPToolDescriptor;
var
  LDispatch: IMCPDPRToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('GetMainForm', 'Get main form',
    'Returns the main form defined in the .dpr',
    _SchemaEmpty, _SchemaStringResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetMainForm(AParams, AContext);
    end);
end;

function TMCPDPRToolsRegistrar._BuildSetMainForm: TMCPToolDescriptor;
var
  LDispatch: IMCPDPRToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('SetMainForm', 'Set main form',
    'Sets the main form in the .dpr',
    _SchemaOneString('FormClass', 'Target form class (e.g. TMainForm).'),
    _SchemaAppliedResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetMainForm(AParams, AContext);
    end);
end;

// ── Public entries ────────────────────────────────────────────────────

procedure RegisterDPRTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: IMCPDPRToolsDispatch;
begin
  LRegistrar := TMCPDPRToolsRegistrar.Create(AFacade, nil, nil);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterDPRTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPDPRToolsDispatch;
begin
  LRegistrar := TMCPDPRToolsRegistrar.Create(AFacade, AConsentRegistry,
    AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

end.
