unit Aefos.MCP.Tools.CodeInsight;

(*
  Code Insight MCP tools (ESP-002, Epic 7/7 Demand 7/8).

  Catalog rows: docs/mcp-catalog/catalog.json — group "Code Insight",
  verdict "new". 6 tools (5 reads + 1 consent-gated write):
    GetSymbolsInUnit, GetClassMembers, FindSymbolUsages, GetMethodBody,
    InsertMethod, GetInheritanceChain.

  Layering (ADR-115 / ADR-142):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterCodeInsightTools(AServer, AFacade), called
      from the bootstrap after the Project Group registration.

  Gating (BR-2):
    - Reads (GetSymbolsInUnit, GetClassMembers, FindSymbolUsages,
      GetMethodBody, GetInheritanceChain): direct facade call, no consent.
    - InsertMethod — risk Low, EMCPUserDenied on denial. Two-anchor atomic
      (BR-4): both interface and implementation are written or neither.

  ADR-143 (FindSymbolUsages token-boundary): the parser tokenizes each unit
  before matching — strings/comments/substrings are never reported as hits.
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
  IMCPCodeInsightToolsDispatch = interface
    ['{6F1D8B4A-2C90-4E73-A506-1D8B4A2C90E7}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleGetSymbolsInUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetClassMembers(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleFindSymbolUsages(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetMethodBody(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleInsertMethod(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetInheritanceChain(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

procedure RegisterCodeInsightTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterCodeInsightTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils;

type
  TMCPCodeInsightToolsRegistrar = class(TMCPToolsRegistrarBase,
    IMCPCodeInsightToolsDispatch)
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
    function _SchemaUnitNameOnly: TJSONObject;
    function _SchemaUnitClass: TJSONObject;
    function _SchemaSymbolOnly: TJSONObject;
    function _SchemaUnitMethod: TJSONObject;
    function _SchemaInsertMethod: TJSONObject;
    function _SchemaClassOnly: TJSONObject;
    function _SchemaSymbolArray: TJSONObject;
    function _SchemaMemberArray: TJSONObject;
    function _SchemaUsageArray: TJSONObject;
    function _SchemaStringResult: TJSONObject;
    function _SchemaAppliedChangedResult: TJSONObject;
    function _SchemaStringArray: TJSONObject;
    // Result builders.
    function _ResultSymbols(
      const ASymbols: TArray<TMCPRecordUnitSymbol>): TMCPToolResult;
    function _ResultMembers(
      const AMembers: TArray<TMCPRecordClassMember>): TMCPToolResult;
    function _ResultUsages(
      const AUsages: TArray<TMCPRecordSymbolUsage>): TMCPToolResult;
    function _ResultString(const AValue: string): TMCPToolResult;
    function _ResultAppliedChanged(const AApplied,
      AChanged: Boolean): TMCPToolResult;
    function _ResultStringArray(const AItems: TArray<string>): TMCPToolResult;
    // Param readers.
    function _ReadOptionalString(const AParams: TJSONObject;
      const AName: string): string;
    // Handlers.
    function _HandleGetSymbolsInUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetClassMembers(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleFindSymbolUsages(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetMethodBody(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleInsertMethod(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetInheritanceChain(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function IMCPCodeInsightToolsDispatch.HandleGetSymbolsInUnit =
      _HandleGetSymbolsInUnit;
    function IMCPCodeInsightToolsDispatch.HandleGetClassMembers =
      _HandleGetClassMembers;
    function IMCPCodeInsightToolsDispatch.HandleFindSymbolUsages =
      _HandleFindSymbolUsages;
    function IMCPCodeInsightToolsDispatch.HandleGetMethodBody =
      _HandleGetMethodBody;
    function IMCPCodeInsightToolsDispatch.HandleInsertMethod =
      _HandleInsertMethod;
    function IMCPCodeInsightToolsDispatch.HandleGetInheritanceChain =
      _HandleGetInheritanceChain;
    function _BuildGetSymbolsInUnit: TMCPToolDescriptor;
    function _BuildGetClassMembers: TMCPToolDescriptor;
    function _BuildFindSymbolUsages: TMCPToolDescriptor;
    function _BuildGetMethodBody: TMCPToolDescriptor;
    function _BuildInsertMethod: TMCPToolDescriptor;
    function _BuildGetInheritanceChain: TMCPToolDescriptor;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry;
      const AAudit: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPCodeInsightToolsRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create(
      'TMCPCodeInsightToolsRegistrar: AFacade');
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

procedure TMCPCodeInsightToolsRegistrar.RegisterAll(
  const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPCodeInsightToolsRegistrar.RegisterAll: AServer');
  AServer.RegisterTool(_BuildGetSymbolsInUnit);
  AServer.RegisterTool(_BuildGetClassMembers);
  AServer.RegisterTool(_BuildFindSymbolUsages);
  AServer.RegisterTool(_BuildGetMethodBody);
  AServer.RegisterTool(_BuildInsertMethod);
  AServer.RegisterTool(_BuildGetInheritanceChain);
end;

// ── Consent / audit shared helpers ───────────────────────────────────

function TMCPCodeInsightToolsRegistrar._RequestGate(
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

procedure TMCPCodeInsightToolsRegistrar._AuditDenied(
  const AToolName, AArgs: string);
begin
  FAudit.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPCodeInsightToolsRegistrar._AuditApplied(
  const AToolName, AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'applied');
end;

procedure TMCPCodeInsightToolsRegistrar._AuditFailed(
  const AToolName, AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'failed');
end;

// ── Schema builders ───────────────────────────────────────────────────

function _NewObjectSchema(const AProps: TJSONObject;
  const ARequired: TJSONArray): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', AProps);
  if Assigned(ARequired) then
    Result.AddPair('required', ARequired);
end;

function _StringProperty(const ADesc: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'string');
  Result.AddPair('description', ADesc);
end;

function TMCPCodeInsightToolsRegistrar._SchemaUnitNameOnly: TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  LProps := TJSONObject.Create;
  LProps.AddPair('UnitName', _StringProperty('Target unit name.'));
  LRequired := TJSONArray.Create;
  LRequired.Add('UnitName');
  Result := _NewObjectSchema(LProps, LRequired);
end;

function TMCPCodeInsightToolsRegistrar._SchemaUnitClass: TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  LProps := TJSONObject.Create;
  LProps.AddPair('UnitName', _StringProperty('Target unit name.'));
  LProps.AddPair('ClassName', _StringProperty('Target class name.'));
  LRequired := TJSONArray.Create;
  LRequired.Add('UnitName');
  LRequired.Add('ClassName');
  Result := _NewObjectSchema(LProps, LRequired);
end;

function TMCPCodeInsightToolsRegistrar._SchemaSymbolOnly: TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  LProps := TJSONObject.Create;
  LProps.AddPair('Symbol',
    _StringProperty('Identifier to locate across the active project.'));
  LRequired := TJSONArray.Create;
  LRequired.Add('Symbol');
  Result := _NewObjectSchema(LProps, LRequired);
end;

function TMCPCodeInsightToolsRegistrar._SchemaUnitMethod: TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  LProps := TJSONObject.Create;
  LProps.AddPair('UnitName', _StringProperty('Target unit name.'));
  LProps.AddPair('MethodName',
    _StringProperty('Target method name (bare or Class.Name).'));
  LRequired := TJSONArray.Create;
  LRequired.Add('UnitName');
  LRequired.Add('MethodName');
  Result := _NewObjectSchema(LProps, LRequired);
end;

function TMCPCodeInsightToolsRegistrar._SchemaInsertMethod: TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  LProps := TJSONObject.Create;
  LProps.AddPair('UnitName', _StringProperty('Target unit name.'));
  LProps.AddPair('ClassName',
    _StringProperty('Target class name (empty for free function).'));
  LProps.AddPair('Signature',
    _StringProperty('Method signature line, e.g. procedure Foo(const X: Integer);'));
  LProps.AddPair('Body',
    _StringProperty('Method body source (empty → begin..end skeleton).'));
  LRequired := TJSONArray.Create;
  LRequired.Add('UnitName');
  LRequired.Add('ClassName');
  LRequired.Add('Signature');
  Result := _NewObjectSchema(LProps, LRequired);
end;

function TMCPCodeInsightToolsRegistrar._SchemaClassOnly: TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
begin
  LProps := TJSONObject.Create;
  LProps.AddPair('ClassName', _StringProperty('Target class name.'));
  LRequired := TJSONArray.Create;
  LRequired.Add('ClassName');
  Result := _NewObjectSchema(LProps, LRequired);
end;

function TMCPCodeInsightToolsRegistrar._SchemaSymbolArray: TJSONObject;
var
  LProps, LValue, LItem, LItemProps, LField: TJSONObject;
begin
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('name', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('kind', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'integer');
  LItemProps.AddPair('line', LField);
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result := _NewObjectSchema(LProps, nil);
end;

function TMCPCodeInsightToolsRegistrar._SchemaMemberArray: TJSONObject;
var
  LProps, LValue, LItem, LItemProps, LField: TJSONObject;
begin
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('name', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('kind', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('visibility', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'integer');
  LItemProps.AddPair('line', LField);
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result := _NewObjectSchema(LProps, nil);
end;

function TMCPCodeInsightToolsRegistrar._SchemaUsageArray: TJSONObject;
var
  LProps, LValue, LItem, LItemProps, LField: TJSONObject;
begin
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('file', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'integer');
  LItemProps.AddPair('line', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'integer');
  LItemProps.AddPair('col', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('context', LField);
  LItem.AddPair('properties', LItemProps);
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result := _NewObjectSchema(LProps, nil);
end;

function TMCPCodeInsightToolsRegistrar._SchemaStringResult: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('value', LField);
  Result := _NewObjectSchema(LProps, nil);
end;

function TMCPCodeInsightToolsRegistrar._SchemaAppliedChangedResult: TJSONObject;
var
  LProps, LApplied, LChanged: TJSONObject;
begin
  LProps := TJSONObject.Create;
  LApplied := TJSONObject.Create; LApplied.AddPair('type', 'boolean');
  LProps.AddPair('applied', LApplied);
  LChanged := TJSONObject.Create; LChanged.AddPair('type', 'boolean');
  LProps.AddPair('changed', LChanged);
  Result := _NewObjectSchema(LProps, nil);
end;

function TMCPCodeInsightToolsRegistrar._SchemaStringArray: TJSONObject;
var
  LProps, LValue, LItem: TJSONObject;
begin
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'string');
  LValue.AddPair('items', LItem);
  LProps.AddPair('value', LValue);
  Result := _NewObjectSchema(LProps, nil);
end;

// ── Result builders ───────────────────────────────────────────────────

function TMCPCodeInsightToolsRegistrar._ResultSymbols(
  const ASymbols: TArray<TMCPRecordUnitSymbol>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(ASymbols) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('name', ASymbols[LFor].Name);
      LItem.AddPair('kind', ASymbols[LFor].Kind);
      LItem.AddPair('line', TJSONNumber.Create(ASymbols[LFor].Line));
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPCodeInsightToolsRegistrar._ResultMembers(
  const AMembers: TArray<TMCPRecordClassMember>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AMembers) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('name', AMembers[LFor].Name);
      LItem.AddPair('kind', AMembers[LFor].Kind);
      LItem.AddPair('visibility', AMembers[LFor].Visibility);
      LItem.AddPair('line', TJSONNumber.Create(AMembers[LFor].Line));
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPCodeInsightToolsRegistrar._ResultUsages(
  const AUsages: TArray<TMCPRecordSymbolUsage>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AUsages) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('file', AUsages[LFor].FilePath);
      LItem.AddPair('line', TJSONNumber.Create(AUsages[LFor].Line));
      LItem.AddPair('col', TJSONNumber.Create(AUsages[LFor].Column));
      LItem.AddPair('context', AUsages[LFor].Context);
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPCodeInsightToolsRegistrar._ResultString(
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

function TMCPCodeInsightToolsRegistrar._ResultAppliedChanged(const AApplied,
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

function TMCPCodeInsightToolsRegistrar._ResultStringArray(
  const AItems: TArray<string>): TMCPToolResult;
var
  LObj: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AItems) do
      LArr.Add(AItems[LFor]);
    LObj.AddPair('value', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

// ── Param readers ─────────────────────────────────────────────────────

function TMCPCodeInsightToolsRegistrar._ReadOptionalString(
  const AParams: TJSONObject; const AName: string): string;
var
  LValue: TJSONValue;
begin
  Result := '';
  if not Assigned(AParams) then
    Exit;
  LValue := AParams.GetValue(AName);
  if Assigned(LValue) and (LValue is TJSONString) then
    Result := TJSONString(LValue).Value;
end;

// ── Handlers ──────────────────────────────────────────────────────────

function TMCPCodeInsightToolsRegistrar._HandleGetSymbolsInUnit(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName: string;
  LSymbols: TArray<TMCPRecordUnitSymbol>;
begin
  LUnitName := _ReadString(AParams, 'UnitName');
  SetLength(LSymbols, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.GetSymbolsInUnit(LUnitName, LSymbols);
    end);
  Result := _ResultSymbols(LSymbols);
end;

function TMCPCodeInsightToolsRegistrar._HandleGetClassMembers(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName, LClassName: string;
  LMembers: TArray<TMCPRecordClassMember>;
begin
  LUnitName := _ReadString(AParams, 'UnitName');
  LClassName := _ReadString(AParams, 'ClassName');
  SetLength(LMembers, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.GetClassMembers(LUnitName, LClassName, LMembers);
    end);
  Result := _ResultMembers(LMembers);
end;

function TMCPCodeInsightToolsRegistrar._HandleFindSymbolUsages(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LSymbol: string;
  LUsages: TArray<TMCPRecordSymbolUsage>;
begin
  LSymbol := _ReadString(AParams, 'Symbol');
  SetLength(LUsages, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.FindSymbolUsages(LSymbol, LUsages);
    end);
  Result := _ResultUsages(LUsages);
end;

function TMCPCodeInsightToolsRegistrar._HandleGetMethodBody(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName, LMethodName, LBody: string;
begin
  LUnitName := _ReadString(AParams, 'UnitName');
  LMethodName := _ReadString(AParams, 'MethodName');
  LBody := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.GetMethodBody(LUnitName, LMethodName, LBody);
    end);
  Result := _ResultString(LBody);
end;

function TMCPCodeInsightToolsRegistrar._HandleInsertMethod(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName, LClassName, LSignature, LBody, LReason: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
  LArgs: string;
begin
  LUnitName := _ReadString(AParams, 'UnitName');
  LClassName := _ReadString(AParams, 'ClassName');
  LSignature := _ReadString(AParams, 'Signature');
  LBody := _ReadOptionalString(AParams, 'Body');
  LArgs := LUnitName + '|' + LClassName + '|' + LSignature;
  LDecision := _RequestGate(AContext, 'InsertMethod',
    'Insert method into unit:', LUnitName);
  if LDecision = cdDenied then
  begin
    _AuditDenied('InsertMethod', LArgs);
    raise EMCPUserDenied.Create('InsertMethod: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  LReason := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.InsertMethod(LUnitName, LClassName, LSignature,
        LBody, LChanged, LReason);
    end);
  if LApplied then
    _AuditApplied('InsertMethod', LArgs, LDecision)
  else
    _AuditFailed('InsertMethod', LArgs + '|' + LReason, LDecision);
  if (not LApplied) and (LReason <> '') then
    raise EMCPInvalidParams.Create(
      'InsertMethod: ' + LReason
      + '; data.detail={"reason":"' + LReason + '"}');
  Result := _ResultAppliedChanged(LApplied, LChanged);
end;

function TMCPCodeInsightToolsRegistrar._HandleGetInheritanceChain(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LClassName: string;
  LChain: TArray<string>;
begin
  LClassName := _ReadString(AParams, 'ClassName');
  SetLength(LChain, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.GetInheritanceChain(LClassName, LChain);
    end);
  Result := _ResultStringArray(LChain);
end;

// ── Descriptor builders ───────────────────────────────────────────────

function TMCPCodeInsightToolsRegistrar._BuildGetSymbolsInUnit: TMCPToolDescriptor;
var
  LDispatch: IMCPCodeInsightToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('GetSymbolsInUnit', 'Get symbols in unit',
    'Lists types, classes, functions and variables declared in a unit',
    _SchemaUnitNameOnly, _SchemaSymbolArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetSymbolsInUnit(AParams, AContext);
    end);
end;

function TMCPCodeInsightToolsRegistrar._BuildGetClassMembers: TMCPToolDescriptor;
var
  LDispatch: IMCPCodeInsightToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('GetClassMembers', 'Get class members',
    'Lists members (fields, methods, props) of a class',
    _SchemaUnitClass, _SchemaMemberArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetClassMembers(AParams, AContext);
    end);
end;

function TMCPCodeInsightToolsRegistrar._BuildFindSymbolUsages: TMCPToolDescriptor;
var
  LDispatch: IMCPCodeInsightToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('FindSymbolUsages', 'Find symbol usages',
    'Finds all usages of a symbol across the project',
    _SchemaSymbolOnly, _SchemaUsageArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleFindSymbolUsages(AParams, AContext);
    end);
end;

function TMCPCodeInsightToolsRegistrar._BuildGetMethodBody: TMCPToolDescriptor;
var
  LDispatch: IMCPCodeInsightToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('GetMethodBody', 'Get method body',
    'Returns the full body of a specific method',
    _SchemaUnitMethod, _SchemaStringResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetMethodBody(AParams, AContext);
    end);
end;

function TMCPCodeInsightToolsRegistrar._BuildInsertMethod: TMCPToolDescriptor;
var
  LDispatch: IMCPCodeInsightToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('InsertMethod', 'Insert method',
    'Inserts the declaration and implementation of a method into a unit',
    _SchemaInsertMethod, _SchemaAppliedChangedResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleInsertMethod(AParams, AContext);
    end);
  Result.Intent := tiCode;
end;

function TMCPCodeInsightToolsRegistrar._BuildGetInheritanceChain: TMCPToolDescriptor;
var
  LDispatch: IMCPCodeInsightToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('GetInheritanceChain', 'Get inheritance chain',
    'Returns the inheritance chain of a class',
    _SchemaClassOnly, _SchemaStringArray,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetInheritanceChain(AParams, AContext);
    end);
end;

// ── Public entries ────────────────────────────────────────────────────

procedure RegisterCodeInsightTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: IMCPCodeInsightToolsDispatch;
begin
  LRegistrar := TMCPCodeInsightToolsRegistrar.Create(AFacade, nil, nil);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterCodeInsightTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPCodeInsightToolsDispatch;
begin
  LRegistrar := TMCPCodeInsightToolsRegistrar.Create(AFacade,
    AConsentRegistry, AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

end.
