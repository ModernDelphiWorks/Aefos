unit Aefos.MCP.Tools.FormsDFM;

(*
  Forms & DFM MCP tools (ESP-002, Epic 7/7 Demand 6/8).

  Catalog rows: docs/mcp-catalog/catalog.json — group "Forms & DFM",
  verdict "new". 9 tools (5 reads + 4 consent-gated writes).

  Layering (ADR-115 / ADR-139):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterFormsDFMTools(AServer, AFacade) called
      from MCP.Server's bootstrap after the Build-group registration.

  Gating (BR-2):
    - Reads (5): ListProjectForms, GetDFMContent, GetFormProperties,
      ListFormComponents, GetComponentProperties.
    - Writes (4): SetDFMContent, SetFormProperty, SetComponentProperty,
      OpenFormDesigner — risk Low, EMCPUserDenied on denial.

  Error contract (BR-6):
    - Reads return sentinels ([], "", null) on miss.
    - Mutations raise EMCPInvalidParams with `data.detail={"reason":"..."}`
      for stable reasons: no-active-project, form-not-found,
      component-not-found, binary-dfm-not-supported, dfm-parse-error.
*)

interface

uses
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.Tools.Common,
  Aefos.MCP.Server;

type
  IMCPFormsDFMToolsDispatch = interface
    ['{C3A9E40D-2B71-4C8E-9F02-7D1A5B4F6E29}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleListProjectForms(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetDFMContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetDFMContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetFormProperties(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetFormProperty(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleListFormComponents(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetComponentProperties(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetComponentProperty(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleOpenFormDesigner(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleOpenDFMTextEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRemoveComponent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleAddComponent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleAddEventHandler(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleCaptureForm(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

procedure RegisterFormsDFMTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterFormsDFMTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils;

type
  TMCPFormsDFMToolsRegistrar = class(TMCPToolsRegistrarBase,
    IMCPFormsDFMToolsDispatch)
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
    function _SchemaTwoString(const AName1, ADesc1, AName2,
      ADesc2: string): TJSONObject;
    function _SchemaStringFields(const ANames,
      ADescs: array of string): TJSONObject;
    function _SchemaProjectFormsArray: TJSONObject;
    function _SchemaDFMContent: TJSONObject;
    function _SchemaPropertyArray: TJSONObject;
    function _SchemaComponentArray: TJSONObject;
    function _SchemaAppliedChanged: TJSONObject;
    // Result builders.
    function _ResultProjectForms(
      const AForms: TArray<TMCPRecordProjectForm>): TMCPToolResult;
    function _ResultDFMContent(const AContent: string;
      const AIsBinary: Boolean): TMCPToolResult;
    function _ResultProperties(
      const AProps: TArray<TMCPRecordDFMProperty>): TMCPToolResult;
    function _ResultComponents(
      const AComps: TArray<TMCPRecordDFMComponent>): TMCPToolResult;
    function _ResultAppliedChanged(const AApplied,
      AChanged: Boolean): TMCPToolResult;
    // Param readers.
    // Handlers.
    function _HandleListProjectForms(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetDFMContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetDFMContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetFormProperties(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetFormProperty(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleListFormComponents(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetComponentProperties(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetComponentProperty(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleOpenFormDesigner(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleOpenDFMTextEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRemoveComponent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddComponent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddEventHandler(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleCaptureForm(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // IMCPFormsDFMToolsDispatch — name-resolved aliases.
    function IMCPFormsDFMToolsDispatch.HandleListProjectForms = _HandleListProjectForms;
    function IMCPFormsDFMToolsDispatch.HandleGetDFMContent = _HandleGetDFMContent;
    function IMCPFormsDFMToolsDispatch.HandleSetDFMContent = _HandleSetDFMContent;
    function IMCPFormsDFMToolsDispatch.HandleGetFormProperties = _HandleGetFormProperties;
    function IMCPFormsDFMToolsDispatch.HandleSetFormProperty = _HandleSetFormProperty;
    function IMCPFormsDFMToolsDispatch.HandleListFormComponents = _HandleListFormComponents;
    function IMCPFormsDFMToolsDispatch.HandleGetComponentProperties = _HandleGetComponentProperties;
    function IMCPFormsDFMToolsDispatch.HandleSetComponentProperty = _HandleSetComponentProperty;
    function IMCPFormsDFMToolsDispatch.HandleOpenFormDesigner = _HandleOpenFormDesigner;
    function IMCPFormsDFMToolsDispatch.HandleOpenDFMTextEditor = _HandleOpenDFMTextEditor;
    function IMCPFormsDFMToolsDispatch.HandleRemoveComponent = _HandleRemoveComponent;
    function IMCPFormsDFMToolsDispatch.HandleAddComponent = _HandleAddComponent;
    function IMCPFormsDFMToolsDispatch.HandleAddEventHandler = _HandleAddEventHandler;
    function IMCPFormsDFMToolsDispatch.HandleCaptureForm = _HandleCaptureForm;
    // Descriptor builders.
    function _Build(const AName, ATitle, ADesc: string;
      const AInput, AOutput: TJSONObject;
      const AHandler: TMCPToolHandler): TMCPToolDescriptor;
    function _BuildListProjectForms: TMCPToolDescriptor;
    function _BuildGetDFMContent: TMCPToolDescriptor;
    function _BuildSetDFMContent: TMCPToolDescriptor;
    function _BuildGetFormProperties: TMCPToolDescriptor;
    function _BuildSetFormProperty: TMCPToolDescriptor;
    function _BuildListFormComponents: TMCPToolDescriptor;
    function _BuildGetComponentProperties: TMCPToolDescriptor;
    function _BuildSetComponentProperty: TMCPToolDescriptor;
    function _BuildOpenFormDesigner: TMCPToolDescriptor;
    function _BuildOpenDFMTextEditor: TMCPToolDescriptor;
    function _BuildRemoveComponent: TMCPToolDescriptor;
    function _BuildAddComponent: TMCPToolDescriptor;
    function _BuildAddEventHandler: TMCPToolDescriptor;
    function _BuildCaptureForm: TMCPToolDescriptor;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry;
      const AAudit: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPFormsDFMToolsRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create(
      'TMCPFormsDFMToolsRegistrar: AFacade');
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

procedure TMCPFormsDFMToolsRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPFormsDFMToolsRegistrar.RegisterAll: AServer');
  AServer.RegisterTool(_BuildListProjectForms);
  AServer.RegisterTool(_BuildGetDFMContent);
  AServer.RegisterTool(_BuildSetDFMContent);
  AServer.RegisterTool(_BuildGetFormProperties);
  AServer.RegisterTool(_BuildSetFormProperty);
  AServer.RegisterTool(_BuildListFormComponents);
  AServer.RegisterTool(_BuildGetComponentProperties);
  AServer.RegisterTool(_BuildSetComponentProperty);
  AServer.RegisterTool(_BuildOpenFormDesigner);
  AServer.RegisterTool(_BuildOpenDFMTextEditor);
  AServer.RegisterTool(_BuildRemoveComponent);
  AServer.RegisterTool(_BuildAddComponent);
  AServer.RegisterTool(_BuildAddEventHandler);
  AServer.RegisterTool(_BuildCaptureForm);
end;

// ── Consent + audit helpers ───────────────────────────────────────────

function TMCPFormsDFMToolsRegistrar._RequestGate(
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

procedure TMCPFormsDFMToolsRegistrar._AuditDenied(const AToolName,
  AArgs: string);
begin
  FAudit.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPFormsDFMToolsRegistrar._AuditApplied(const AToolName,
  AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'applied');
end;

procedure TMCPFormsDFMToolsRegistrar._AuditFailed(const AToolName,
  AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'failed');
end;

// ── Schema helpers ───────────────────────────────────────────────────

function _NewStringProp(const ADesc: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'string');
  Result.AddPair('description', ADesc);
end;

function TMCPFormsDFMToolsRegistrar._SchemaEmpty: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

function TMCPFormsDFMToolsRegistrar._SchemaOneString(const AName,
  ADesc: string): TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LProps.AddPair(AName, _NewStringProp(ADesc));
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add(AName);
  Result.AddPair('required', LRequired);
end;

function TMCPFormsDFMToolsRegistrar._SchemaTwoString(const AName1, ADesc1,
  AName2, ADesc2: string): TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LProps.AddPair(AName1, _NewStringProp(ADesc1));
  LProps.AddPair(AName2, _NewStringProp(ADesc2));
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add(AName1);
  LRequired.Add(AName2);
  Result.AddPair('required', LRequired);
end;

function TMCPFormsDFMToolsRegistrar._SchemaStringFields(const ANames,
  ADescs: array of string): TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
  LFor: Integer;
begin
  if Length(ANames) <> Length(ADescs) then
    raise EArgumentException.Create(
      '_SchemaStringFields: ANames and ADescs length mismatch');
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LRequired := TJSONArray.Create;
  for LFor := 0 to High(ANames) do
  begin
    LProps.AddPair(ANames[LFor], _NewStringProp(ADescs[LFor]));
    LRequired.Add(ANames[LFor]);
  end;
  Result.AddPair('properties', LProps);
  Result.AddPair('required', LRequired);
end;

function TMCPFormsDFMToolsRegistrar._SchemaProjectFormsArray: TJSONObject;
var
  LProps, LValue, LItem, LItemProps: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LItemProps.AddPair('name', _NewStringProp('Form/datamodule unit name'));
  LItemProps.AddPair('modulePath',
    _NewStringProp('Absolute path to the .pas unit'));
  LItemProps.AddPair('dfmPath',
    _NewStringProp('Absolute path to the .dfm companion'));
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function TMCPFormsDFMToolsRegistrar._SchemaDFMContent: TJSONObject;
var
  LProps, LContent, LFormat: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LContent := TJSONObject.Create;
  LContent.AddPair('type', 'string');
  LProps.AddPair('content', LContent);
  LFormat := TJSONObject.Create;
  LFormat.AddPair('type', 'string');
  LFormat.AddPair('description', 'text | binary (ADR-140 discriminator)');
  LProps.AddPair('format', LFormat);
  Result.AddPair('properties', LProps);
end;

function TMCPFormsDFMToolsRegistrar._SchemaPropertyArray: TJSONObject;
var
  LProps, LValue, LItem, LItemProps: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LItemProps.AddPair('name', _NewStringProp('Property name'));
  LItemProps.AddPair('value',
    _NewStringProp('Verbatim DFM value (string, number, set, etc.)'));
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function TMCPFormsDFMToolsRegistrar._SchemaComponentArray: TJSONObject;
var
  LProps, LValue, LItem, LItemProps: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LItemProps.AddPair('name', _NewStringProp('Component instance name'));
  LItemProps.AddPair('type', _NewStringProp('Component class (e.g. TButton)'));
  LItemProps.AddPair('owner',
    _NewStringProp('Parent component (empty for form children)'));
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function TMCPFormsDFMToolsRegistrar._SchemaAppliedChanged: TJSONObject;
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

// ── Result builders ───────────────────────────────────────────────────

function TMCPFormsDFMToolsRegistrar._ResultProjectForms(
  const AForms: TArray<TMCPRecordProjectForm>): TMCPToolResult;
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
      LItem.AddPair('name', AForms[LFor].Name);
      LItem.AddPair('modulePath', AForms[LFor].ModulePath);
      LItem.AddPair('dfmPath', AForms[LFor].DfmPath);
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPFormsDFMToolsRegistrar._ResultDFMContent(const AContent: string;
  const AIsBinary: Boolean): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('content', AContent);
    if AIsBinary then
      LObj.AddPair('format', 'binary')
    else
      LObj.AddPair('format', 'text');
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPFormsDFMToolsRegistrar._ResultProperties(
  const AProps: TArray<TMCPRecordDFMProperty>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AProps) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('name', AProps[LFor].Name);
      LItem.AddPair('value', AProps[LFor].Value);
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPFormsDFMToolsRegistrar._ResultComponents(
  const AComps: TArray<TMCPRecordDFMComponent>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AComps) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('name', AComps[LFor].Name);
      LItem.AddPair('type', AComps[LFor].TypeName);
      LItem.AddPair('owner', AComps[LFor].Owner);
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPFormsDFMToolsRegistrar._ResultAppliedChanged(const AApplied,
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

// ── Param readers ─────────────────────────────────────────────────────

// Helper: surfaces a write failure as -32602 with the structured reason.
// Actionable remedy for the machine reason code — appended to the human message
// only; data.detail.reason stays the clean kebab so the agent can branch on it.
function _RemedyFor(const AReason: string): string;
begin
  if AReason = 'unit-not-resolved' then
    Result := ' (the named unit is not an open form — open the target form in ' +
      'the Designer and resend, or OMIT UnitName to build into the form ' +
      'currently open; do not invent a unit name)'
  else if AReason = 'form-not-found' then
    Result := ' (open a form in the Designer first, or pass an existing form''s ' +
      'unit name)'
  else
    Result := '';
end;

procedure _RaiseInvalidReason(const ATool, AReason: string);
begin
  raise EMCPInvalidParams.Create(
    ATool + ': ' + AReason + _RemedyFor(AReason) +
    '; data.detail={"reason":"' + AReason + '"}');
end;

// ── Handlers ──────────────────────────────────────────────────────────

function TMCPFormsDFMToolsRegistrar._HandleListProjectForms(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LForms: TArray<TMCPRecordProjectForm>;
begin
  SetLength(LForms, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LForms := FFacade.ListProjectForms;
    end);
  Result := _ResultProjectForms(LForms);
end;

function TMCPFormsDFMToolsRegistrar._HandleGetDFMContent(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LContent: string;
  LIsBinary, LOk: Boolean;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  LContent := '';
  LIsBinary := False;
  LOk := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LOk := FFacade.GetDFMContent(LUnit, LContent, LIsBinary);
    end);
  if not LOk then
    LContent := '';
  Result := _ResultDFMContent(LContent, LIsBinary);
end;

function TMCPFormsDFMToolsRegistrar._HandleSetDFMContent(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LSource, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  LSource := _ReadString(AParams, 'DFMSource');
  LDecision := _RequestGate(AContext, 'SetDFMContent',
    'Overwrite .dfm for unit:', LUnit);
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetDFMContent', LUnit);
    raise EMCPUserDenied.Create('SetDFMContent: user denied the action');
  end;
  LApplied := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetDFMContent(LUnit, LSource, LReason);
    end);
  if LApplied then
    _AuditApplied('SetDFMContent', LUnit, LDecision)
  else
    _AuditFailed('SetDFMContent', LUnit + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    _RaiseInvalidReason('SetDFMContent', LReason);
  Result := _ResultAppliedChanged(LApplied, LApplied);
end;

function TMCPFormsDFMToolsRegistrar._HandleGetFormProperties(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit: string;
  LProps: TArray<TMCPRecordDFMProperty>;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  SetLength(LProps, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.GetFormProperties(LUnit, LProps);
    end);
  Result := _ResultProperties(LProps);
end;

function TMCPFormsDFMToolsRegistrar._HandleSetFormProperty(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LProp, LValue, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  LProp := _ReadString(AParams, 'Prop');
  LValue := _ReadString(AParams, 'Value');
  LDecision := _RequestGate(AContext, 'SetFormProperty',
    Format('Set %s.%s = %s', [LUnit, LProp, LValue]), '');
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetFormProperty', LUnit + '|' + LProp);
    raise EMCPUserDenied.Create('SetFormProperty: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetFormProperty(LUnit, LProp, LValue, LChanged,
        LReason);
    end);
  if LApplied then
    _AuditApplied('SetFormProperty', LUnit + '|' + LProp + '=' + LValue,
      LDecision)
  else
    _AuditFailed('SetFormProperty', LUnit + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    _RaiseInvalidReason('SetFormProperty', LReason);
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPFormsDFMToolsRegistrar._HandleListFormComponents(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit: string;
  LComps: TArray<TMCPRecordDFMComponent>;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  SetLength(LComps, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.ListFormComponents(LUnit, LComps);
    end);
  Result := _ResultComponents(LComps);
end;

function TMCPFormsDFMToolsRegistrar._HandleGetComponentProperties(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LComp: string;
  LProps: TArray<TMCPRecordDFMProperty>;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  LComp := _ReadString(AParams, 'ComponentName');
  SetLength(LProps, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.GetComponentProperties(LUnit, LComp, LProps);
    end);
  Result := _ResultProperties(LProps);
end;

function TMCPFormsDFMToolsRegistrar._HandleSetComponentProperty(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LComp, LProp, LValue, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  LComp := _ReadString(AParams, 'CompName');
  LProp := _ReadString(AParams, 'Prop');
  LValue := _ReadString(AParams, 'Value');
  LDecision := _RequestGate(AContext, 'SetComponentProperty',
    Format('Set %s.%s.%s = %s', [LUnit, LComp, LProp, LValue]), '');
  if LDecision = cdDenied then
  begin
    _AuditDenied('SetComponentProperty', LUnit + '|' + LComp + '|' + LProp);
    raise EMCPUserDenied.Create(
      'SetComponentProperty: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.SetComponentProperty(LUnit, LComp, LProp, LValue,
        LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('SetComponentProperty',
      LUnit + '|' + LComp + '|' + LProp + '=' + LValue, LDecision)
  else
    _AuditFailed('SetComponentProperty', LUnit + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    _RaiseInvalidReason('SetComponentProperty', LReason);
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPFormsDFMToolsRegistrar._HandleOpenFormDesigner(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  LDecision := _RequestGate(AContext, 'OpenFormDesigner',
    'Open Form Designer for unit:', LUnit);
  if LDecision = cdDenied then
  begin
    _AuditDenied('OpenFormDesigner', LUnit);
    raise EMCPUserDenied.Create('OpenFormDesigner: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.OpenFormDesigner(LUnit, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('OpenFormDesigner', LUnit, LDecision)
  else
    _AuditFailed('OpenFormDesigner', LUnit + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    _RaiseInvalidReason('OpenFormDesigner', LReason);
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPFormsDFMToolsRegistrar._HandleRemoveComponent(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LComp, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  LComp := _ReadString(AParams, 'ComponentName');
  LDecision := _RequestGate(AContext, 'RemoveComponent',
    Format('Remove component %s from %s', [LComp, LUnit]), '');
  if LDecision = cdDenied then
  begin
    _AuditDenied('RemoveComponent', LUnit + '|' + LComp);
    raise EMCPUserDenied.Create('RemoveComponent: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.RemoveComponent(LUnit, LComp, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('RemoveComponent', LUnit + '|' + LComp, LDecision)
  else
    _AuditFailed('RemoveComponent', LUnit + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    _RaiseInvalidReason('RemoveComponent', LReason);
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPFormsDFMToolsRegistrar._HandleAddComponent(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LClass, LName, LParent, LReason: string;
  LLeft, LTop, LWidth, LHeight: Integer;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LUnit  := _ReadString(AParams, 'UnitName');
  LClass := _ReadString(AParams, 'ComponentClass');
  LName  := _ReadString(AParams, 'ComponentName');
  LParent := _ReadString(AParams, 'Parent');
  // Parent is REQUIRED so a control never lands invisibly behind another one.
  // The rejection itself is the loop hint: it tells the agent exactly what to send.
  if LParent = '' then
    _RaiseInvalidReason('AddComponent',
      'parent-required: pass Parent — the container the control nests into (a ' +
      'panel/group-box), or the form''s own name for a top-level control. List ' +
      'valid names with ListFormComponents.');
  LLeft   := StrToIntDef(_ReadString(AParams, 'Left'), 0);
  LTop    := StrToIntDef(_ReadString(AParams, 'Top'), 0);
  LWidth  := StrToIntDef(_ReadString(AParams, 'Width'), 0);
  LHeight := StrToIntDef(_ReadString(AParams, 'Height'), 0);
  LDecision := _RequestGate(AContext, 'AddComponent',
    Format('Add %s %s to %s in %s', [LClass, LName, LParent, LUnit]), '');
  if LDecision = cdDenied then
  begin
    _AuditDenied('AddComponent', LUnit + '|' + LName);
    raise EMCPUserDenied.Create('AddComponent: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.AddComponent(LUnit, LClass, LName, LParent,
        LLeft, LTop, LWidth, LHeight, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('AddComponent', LUnit + '|' + LClass + '|' + LName, LDecision)
  else
    _AuditFailed('AddComponent', LUnit + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    _RaiseInvalidReason('AddComponent', LReason);
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPFormsDFMToolsRegistrar._HandleCaptureForm(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LB64, LPath, LReason: string;
  LContent: string;
  LOk: Boolean;
  LCapture: IMCPFormCapture;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  if not Supports(FFacade, IMCPFormCapture, LCapture) then
    _RaiseInvalidReason('CaptureForm',
      'capture-unavailable: this host cannot render forms to an image');
  LOk := False;
  LB64 := '';
  LPath := '';
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LOk := LCapture.CaptureActiveFormPng(LUnit, LB64, LPath, LReason);
    end);
  if not LOk then
    _RaiseInvalidReason('CaptureForm', LReason);
  LContent :=
    'Screenshot of the live form (PNG) attached. Look at it and fix anything ' +
    'wrong: a leftover placeholder Caption (e.g. a panel still showing its own ' +
    'name), a control hidden behind another, a missing/broken glyph, or a ' +
    'misaligned control.';
  if LPath <> '' then
    LContent := LContent + ' (saved to ' + LPath + ')';
  Result := TMCPToolResult.Image(LB64, 'image/png', LContent);
end;

function TMCPFormsDFMToolsRegistrar._HandleAddEventHandler(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LComp, LEvent, LHandler, LBody, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LUnit    := _ReadString(AParams, 'UnitName');
  LComp    := _ReadString(AParams, 'ComponentName');
  LEvent   := _ReadString(AParams, 'EventName');
  LHandler := _ReadString(AParams, 'HandlerName');
  LBody    := _ReadString(AParams, 'Body');
  LDecision := _RequestGate(AContext, 'AddEventHandler',
    Format('Wire %s.%s on %s', [LComp, LEvent, LUnit]), '');
  if LDecision = cdDenied then
  begin
    _AuditDenied('AddEventHandler', LUnit + '|' + LComp + '.' + LEvent);
    raise EMCPUserDenied.Create('AddEventHandler: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.AddEventHandler(LUnit, LComp, LEvent, LHandler, LBody,
        LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('AddEventHandler', LUnit + '|' + LComp + '.' + LEvent, LDecision)
  else
    _AuditFailed('AddEventHandler', LUnit + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    _RaiseInvalidReason('AddEventHandler', LReason);
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

// ── Descriptor builders ───────────────────────────────────────────────

function TMCPFormsDFMToolsRegistrar._Build(const AName, ATitle, ADesc: string;
  const AInput, AOutput: TJSONObject;
  const AHandler: TMCPToolHandler): TMCPToolDescriptor;
begin
  Result := TMCPToolDescriptor.Create(AName, ATitle, ADesc, AInput, AOutput,
    AHandler);
end;

function TMCPFormsDFMToolsRegistrar._BuildListProjectForms: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('ListProjectForms', 'List project forms',
    'Lists all forms/datamodules of the project',
    _SchemaEmpty, _SchemaProjectFormsArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleListProjectForms(AParams, AContext);
    end);
end;

function TMCPFormsDFMToolsRegistrar._BuildGetDFMContent: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('GetDFMContent', 'Get DFM content',
    'Returns a form .dfm as text. When the form is open in the Designer it ' +
    'reflects the LIVE in-memory state (including unsaved edits); otherwise it ' +
    'reads the on-disk .dfm. ListFormComponents/GetFormProperties/' +
    'GetComponentProperties all read through this, so they are live too.',
    _SchemaOneString('UnitName', 'Form unit name (without .pas)'),
    _SchemaDFMContent,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetDFMContent(AParams, AContext);
    end);
end;

function TMCPFormsDFMToolsRegistrar._BuildSetDFMContent: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('SetDFMContent', 'Set DFM content',
    'ADVANCED / BULK ONLY — replaces a whole .dfm at once. YOU CANNOT BUILD A ' +
    'FORM WITH THIS. A NEW control enters a form ONLY through AddComponent, which ' +
    'creates it LIVE in the Form Designer (the user WATCHES it appear) and lets ' +
    'the IDE declare the .pas field automatically — you NEVER hand-write component ' +
    'code (fields or objects). This command is REFUSED the instant its .dfm names ' +
    'any control not already on the live form. To create a UI: AddComponent for ' +
    'EACH control, then SetComponentProperty/SetFormProperty for properties and ' +
    'AddEventHandler to create + wire an event in one step. Do NOT OverwriteFile a ' +
    '.pas/.dfm by hand — refused. Use SetDFMContent ONLY to reposition / restyle / ' +
    'swap the layout of controls that ALREADY EXIST on the form (same component ' +
    'set). When the UnitName is omitted or does not resolve, it targets the form ' +
    'currently OPEN in the Designer. RESULTING STATE: the .dfm is written and the ' +
    'Designer is brought forward (no RunBuild needed to see it). For FMX controls ' +
    'use Position.X/Position.Y for layout (not Left/Top). GUARDED (its-own-' +
    'guardian, RULE #1): REFUSED (pas-dfm-desync) when the new .dfm (a) declares a ' +
    'component the form class lacks OR (b) introduces ANY control not present on ' +
    'the LIVE form — the signature of building/adding a control via a bulk write. ' +
    'Declaring the fields in the .pas first does NOT bypass it: the check is ' +
    'against the live Designer, not the source. Use AddComponent for each new ' +
    'control.',
    _SchemaTwoString('UnitName', 'Form unit name (without .pas)',
      'DFMSource', 'New .dfm text content'),
    _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetDFMContent(AParams, AContext);
    end);
end;

function TMCPFormsDFMToolsRegistrar._BuildGetFormProperties: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('GetFormProperties', 'Get form properties',
    'Returns top-level form properties (Width, Height, Caption...)',
    _SchemaOneString('UnitName', 'Form unit name (without .pas)'),
    _SchemaPropertyArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetFormProperties(AParams, AContext);
    end);
end;

function TMCPFormsDFMToolsRegistrar._BuildSetFormProperty: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('SetFormProperty', 'Set form property',
    'Sets the value of a form property in the .dfm',
    _SchemaStringFields(
      ['UnitName', 'Prop', 'Value'],
      ['Form unit name (without .pas)',
       'Property name',
       'Raw property value, NOT DFM-quoted: Hello (not ''Hello'') for a ' +
       'Caption, 120 for Width, True for Visible, alClient for Align, ' +
       'clWhite (a named color constant) or $00FFFFFF (BGR hex) for a Color, ' +
       'crHandPoint for a Cursor']),
    _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetFormProperty(AParams, AContext);
    end);
  Result.Intent := tiDesign;
end;

function TMCPFormsDFMToolsRegistrar._BuildListFormComponents: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('ListFormComponents', 'List form components',
    'Lists all components of a form with their types and names',
    _SchemaOneString('UnitName', 'Form unit name (without .pas)'),
    _SchemaComponentArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleListFormComponents(AParams, AContext);
    end);
end;

function TMCPFormsDFMToolsRegistrar._BuildGetComponentProperties: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('GetComponentProperties', 'Get component properties',
    'Returns properties of a specific component in the .dfm',
    _SchemaTwoString('UnitName', 'Form unit name (without .pas)',
      'ComponentName', 'Target component instance name'),
    _SchemaPropertyArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetComponentProperties(AParams, AContext);
    end);
end;

function TMCPFormsDFMToolsRegistrar._BuildSetComponentProperty: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('SetComponentProperty', 'Set component property',
    'Sets a property of a component in the .dfm',
    _SchemaStringFields(
      ['UnitName', 'CompName', 'Prop', 'Value'],
      ['Form unit name (without .pas)',
       'Target component instance name',
       'Property name',
       'Raw property value, NOT DFM-quoted: Hello (not ''Hello'') for a ' +
       'Caption, 120 for Width, True for Visible, alClient for Align, ' +
       'clWhite (a named color constant) or $00FFFFFF (BGR hex) for a Color, ' +
       'crHandPoint for a Cursor']),
    _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetComponentProperty(AParams, AContext);
    end);
  Result.Intent := tiDesign;
end;

function TMCPFormsDFMToolsRegistrar._BuildOpenFormDesigner: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('OpenFormDesigner', 'Open form designer',
    'Opens the Form Designer of a form in the IDE',
    _SchemaOneString('UnitName', 'Form unit name (without .pas)'),
    _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleOpenFormDesigner(AParams, AContext);
    end);
end;

function TMCPFormsDFMToolsRegistrar._HandleOpenDFMTextEditor(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnit, LReason: string;
  LApplied, LChanged: Boolean;
begin
  LUnit := _ReadString(AParams, 'UnitName');
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.OpenDFMTextEditor(LUnit, LChanged, LReason);
    end);
  if (not LApplied) and (LReason <> '') then
    _RaiseInvalidReason('OpenDFMTextEditor', LReason);
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPFormsDFMToolsRegistrar._BuildOpenDFMTextEditor: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('OpenDFMTextEditor', 'Open DFM text editor',
    'Opens the .dfm text editor (the OTA equivalent of Alt+F12 — no keyboard ' +
    'required). RESULTING STATE: the active editor shows the .dfm as text; the ' +
    'buffer is ready to receive SetEditorFullContent with the desired DFM. ' +
    'After SetEditorFullContent, call OpenFormDesigner to return to Design mode ' +
    '(the OTA equivalent of a second Alt+F12) and SaveActiveFile to persist.',
    _SchemaOneString('UnitName', 'Form unit name (without .pas)'),
    _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleOpenDFMTextEditor(AParams, AContext);
    end);
end;

function TMCPFormsDFMToolsRegistrar._BuildRemoveComponent: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('RemoveComponent', 'Remove component',
    'Removes a component from a form through the LIVE Form Designer (it does NOT ' +
    'rewrite the .dfm as text). The Form Designer is brought to front and the ' +
    'removal shows at once; the IDE drops the published field from the .pas on ' +
    'its own. RESULTING STATE: the component is gone from the form, the IDE is in ' +
    'Design mode, and the module is marked modified (call SaveActiveFile/' +
    'SaveAllFiles to persist). RunBuild is NOT required. This is the correct way ' +
    'to remove a component — prefer it over editing the .dfm.',
    _SchemaTwoString('UnitName', 'Form unit name (without .pas)',
      'ComponentName', 'Component instance name to remove'),
    _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRemoveComponent(AParams, AContext);
    end);
  Result.Intent := tiDesign;
end;

function TMCPFormsDFMToolsRegistrar._BuildAddComponent: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('AddComponent', 'Add component',
    'Creates a component on a form through the LIVE Form Designer (it does NOT ' +
    'edit the .pas or .dfm as text). The IDE declares the published field in the ' +
    '.pas on its own, so the agent writes no source. ComponentClass is a ' +
    'registered VCL class name (e.g. TButton, TEdit, TLabel). RESULTING STATE: ' +
    'the component exists on the form, the IDE is in Design mode, the module is ' +
    'marked modified (call SaveActiveFile/SaveAllFiles to persist). RunBuild is ' +
    'NOT required. Prefer this over editing the .dfm/.pas by hand. This is the ' +
    'building block for a whole form: call it once PER control to watch the UI ' +
    'grow live. Never OverwriteFile a .pas/.dfm to create components. Parent is ' +
    'REQUIRED — always say WHERE the control nests: a container (panel/group-box) ' +
    'to place it inside, or the form''s own name for a top-level control. This is ' +
    'how you build nested layouts (e.g. a card panel with fields inside it) and ' +
    'stops controls from landing invisibly behind another one. Left/Top are ' +
    'relative to the Parent.',
    _SchemaStringFields(
      ['UnitName', 'ComponentClass', 'ComponentName', 'Parent', 'Left', 'Top',
       'Width', 'Height'],
      ['Form unit name without .pas; leave empty or pass the open form''s name ' +
       'to target the form currently OPEN in the Designer (do not invent a unit)',
       'Registered component class, e.g. TButton',
       'New component instance name',
       'REQUIRED. The container this control nests into: an existing container ' +
       'component name (a panel/group-box), or the form''s own name for a ' +
       'top-level control. Left/Top are relative to this parent. Never leave it ' +
       'empty (list valid names with ListFormComponents)',
       'Left position in pixels, relative to Parent',
       'Top position in pixels, relative to Parent',
       'Width in pixels',
       'Height in pixels']),
    _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleAddComponent(AParams, AContext);
    end);
  Result.Intent := tiDesign;
end;

function TMCPFormsDFMToolsRegistrar._BuildCaptureForm: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('CaptureForm', 'Capture form (screenshot)',
    'Renders the LIVE form in the Designer to a PNG image and returns it so you ' +
    'can SEE what you are building and self-correct. Use it after adding or ' +
    'arranging controls (and again after tweaks) to verify the layout matches the ' +
    'intended design — catch a leftover placeholder Caption, a control hidden ' +
    'behind another, a missing glyph, or a misalignment, then fix it. This is a ' +
    'READ: it does not move the view or modify anything, and RunProject is NOT ' +
    'needed (it is the fast look-and-fix loop). VCL only. UnitName may be empty to ' +
    'capture the form currently open in the Designer.',
    _SchemaOneString('UnitName',
      'Form unit name without .pas; empty = the form open in the Designer'),
    _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleCaptureForm(AParams, AContext);
    end);
  Result.Intent := tiNeutral;
end;

function TMCPFormsDFMToolsRegistrar._BuildAddEventHandler: TMCPToolDescriptor;
var
  LDispatch: IMCPFormsDFMToolsDispatch;
begin
  LDispatch := Self;
  Result := _Build('AddEventHandler', 'Add event handler',
    'Wires a component event to a handler method through the LIVE Form Designer ' +
    '(the equivalent of double-clicking the event in the Object Inspector). It ' +
    'creates the handler method in the form''s published auto-managed section ' +
    '(or links an existing method of the same name) AND assigns it to the ' +
    'component event, so the .dfm gets the OnX = Handler wire and the .pas gets ' +
    'the method - in one designer step. EventName is the event property, e.g. ' +
    'OnClick. HandlerName is optional; leave empty for the IDE default ' +
    '(Component + Event without On, e.g. Button1Click). Body is optional: when ' +
    'given, the handler is created WITH that body (in the published section, ' +
    'correct signature) AND wired - the whole "write the handler code + link it" ' +
    'in ONE call, so you never need a separate InsertMethod (which would ' +
    'duplicate). Leave Body empty to wire an empty handler stub. This is the ' +
    'correct way to wire events: do NOT set an event via SetComponentProperty ' +
    '(it is rejected) and do NOT edit the .dfm/.pas by hand. RESULTING STATE: ' +
    'the handler exists and is wired, the module is marked modified (call ' +
    'SaveActiveFile/SaveAllFiles to persist). VIEW: an EMPTY stub leaves the IDE ' +
    'in Design; passing a Body ENDS IN CODE on the new handler (mirroring the ' +
    'designer double-click) — call OpenFormDesigner before your next design ' +
    'command. RunBuild is NOT required.',
    _SchemaStringFields(
      ['UnitName', 'ComponentName', 'EventName', 'HandlerName', 'Body'],
      ['Form unit name (without .pas)',
       'Target component instance name. To wire a FORM-LEVEL event ' +
       '(OnCreate/OnShow/OnClose), pass the form''s own name or class (or leave ' +
       'empty) — the handler is then created as FormCreate/FormShow (IDE ' +
       'convention), not <FormName>Create.',
       'Event property name, e.g. OnClick (OnCreate/OnShow/OnClose for the form)',
       'Handler method name (empty for the IDE default: <Component>+<Event> for ' +
       'a control, e.g. Button1Click; Form+<Event> for the form, e.g. FormCreate)',
       'Handler body source (empty for an empty stub), e.g. ShowMessage(''hi''); ' +
       'pass the statements only (no surrounding begin/end) flush-left — the tool ' +
       'indents the body for you; any leading indentation you add is normalised ' +
       'away, so it never doubles.']),
    _SchemaAppliedChanged,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleAddEventHandler(AParams, AContext);
    end);
  Result.Intent := tiDesign;
end;

// ── Public entries ────────────────────────────────────────────────────

procedure RegisterFormsDFMTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: IMCPFormsDFMToolsDispatch;
begin
  LRegistrar := TMCPFormsDFMToolsRegistrar.Create(AFacade, nil, nil);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterFormsDFMTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPFormsDFMToolsDispatch;
begin
  LRegistrar := TMCPFormsDFMToolsRegistrar.Create(AFacade, AConsentRegistry,
    AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

end.
