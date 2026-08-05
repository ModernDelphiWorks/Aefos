unit Aefos.MCP.Tools.Units;

(*
  Units-group MCP tools (ESP-002, Epic 7/7 Demand 3/8).

  Catalog rows: docs/mcp-catalog/catalog.json — group "Units",
  verdict "new". 9 tools (3 reads + 1 navigation + 5 writes).
  ListProjectUnits/GetUnitSource/SetUnitSource are dedup'd against the
  shipped ReadUnitList/ReadUnit/EditUnit+OverwriteFile pair; RenameUnit and
  MoveUnitToFolder are deferred-paid (Phase 3 backlog).

  Layering (ADR-115 / ADR-126):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterUnitsTools(AServer, AFacade) called from
      MCP.Server's bootstrap after the shipped 11-tool + Project 17-tool
      registrations. tools/list returns 11 + 17 + 9 = 37 entries.

  Gating (ADR-127):
    - Reads (3): IsUnitOpen / GetUnitUses / GetUnitFilePath — direct facade
      call, no consent.
    - Navigation (1): OpenUnitInEditor — direct facade call, no consent
      (opens an editor tab; trivially reversible).
    - Writes (5): AddUnitToProject / RemoveUnitFromProject / CreateNewUnit /
      AddToUses / RemoveFromUses — TMCPConsentRegistry.RequireConsent gated
      with risk class Low; JSON-RPC -32003 MCP_ERR_USER_DENIED on denial.

  Idempotency (ADR-128):
    - AddToUses and RemoveFromUses are idempotent — no-op returns True with
      result.changed: false in the JSON-RPC envelope and audit-log line.

  Uniform write-error contract (ADR-130):
    - Unknown unit / missing file / name collision → -32602 InvalidParams
      with data.detail = {target, reason}; reasons are "unit-not-in-project"
      | "file-not-found" | "name-collision" | "no-output-dir".
    - Reads never error on missing target (sentinel: False / [] / '').
*)

interface

uses
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.Server;

type
  // Dispatch surface for the Units-group tool handlers. Each tool-handler
  // closure captures an IMCPUnitsToolsRegistrar reference so the registrar
  // (and its consent/audit collaborators) is reference-counted alive for
  // the server's lifetime — same lifetime contract as shipped MCP.Tools.
  IMCPUnitsToolsRegistrar = interface
    ['{8B5A12E7-3C9F-4B58-A6D1-7E0F4C8B9A23}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleIsUnitOpen(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetUnitUses(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetUnitFilePath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleOpenUnitInEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleAddUnitToProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRemoveUnitFromProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleCreateNewUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleAddToUses(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRemoveFromUses(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleCreateNewProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Shared worker behind the generic CreateNewProject AND every explicit
    // CreateProject<Type> tool — the kind is supplied by the caller, not read
    // from a param, so each explicit tool's name fixes the project type.
    function HandleCreateProjectKind(const AToolName, AKind: string;
      const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleCloseAllProjects(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

procedure RegisterUnitsTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterUnitsTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Aefos.MCP.Tools.Common;

type
  TMCPUnitsToolsRegistrar = class(TMCPToolsRegistrarBase,
    IMCPUnitsToolsRegistrar)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsentRegistry: IMCPConsentRegistry;
    FAuditLog: IMCPAuditLog;
    // Descriptor builders — one per Units tool (9 total).
    function _BuildIsUnitOpen: TMCPToolDescriptor;
    function _BuildGetUnitUses: TMCPToolDescriptor;
    function _BuildGetUnitFilePath: TMCPToolDescriptor;
    function _BuildOpenUnitInEditor: TMCPToolDescriptor;
    function _BuildAddUnitToProject: TMCPToolDescriptor;
    function _BuildRemoveUnitFromProject: TMCPToolDescriptor;
    function _BuildCreateNewUnit: TMCPToolDescriptor;
    function _BuildAddToUses: TMCPToolDescriptor;
    function _BuildRemoveFromUses: TMCPToolDescriptor;
    // Factory for one explicit, self-describing CreateProject<Type> tool. Reuses
    // the shared worker; only the name/title/description/kind differ.
    function _BuildCreateProjectTyped(const AName, ATitle, ADescription,
      AKind: string): TMCPToolDescriptor;
    function _BuildCloseAllProjects: TMCPToolDescriptor;
    // Handlers — reads/navigation direct; writes consent-gated (ADR-127).
    function _HandleIsUnitOpen(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetUnitUses(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetUnitFilePath(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleOpenUnitInEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddUnitToProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRemoveUnitFromProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleCreateNewUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddToUses(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRemoveFromUses(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleCreateNewProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleCreateProjectKind(const AToolName, AKind: string;
      const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleCloseAllProjects(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Helpers.
    function _ReadBoolean(const AParams: TJSONObject;
      const AName: string): Boolean;
    function _RequestGate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    procedure _AuditDenied(const AToolName, AArgs: string);
    procedure _AuditApplied(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision; const AChanged: Boolean);
    procedure _AuditFailed(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    function _BoolResult(const AValue: Boolean;
      const AChanged: Boolean = False;
      const AEmitChanged: Boolean = False): TMCPToolResult;
    function _StringResult(const AValue: string): TMCPToolResult;
    function _UsesResult(const AIface, AImpl: TArray<string>;
      const AFound: Boolean): TMCPToolResult;
    function _PathResult(const APath: string): TMCPToolResult;
    procedure _DenyWithStructuredDetail(const AToolName, ATarget,
      AReason: string);
    // IMCPUnitsToolsRegistrar dispatch surface — maps to private impls.
    function IMCPUnitsToolsRegistrar.HandleIsUnitOpen = _HandleIsUnitOpen;
    function IMCPUnitsToolsRegistrar.HandleGetUnitUses = _HandleGetUnitUses;
    function IMCPUnitsToolsRegistrar.HandleGetUnitFilePath =
      _HandleGetUnitFilePath;
    function IMCPUnitsToolsRegistrar.HandleOpenUnitInEditor =
      _HandleOpenUnitInEditor;
    function IMCPUnitsToolsRegistrar.HandleAddUnitToProject =
      _HandleAddUnitToProject;
    function IMCPUnitsToolsRegistrar.HandleRemoveUnitFromProject =
      _HandleRemoveUnitFromProject;
    function IMCPUnitsToolsRegistrar.HandleCreateNewUnit = _HandleCreateNewUnit;
    function IMCPUnitsToolsRegistrar.HandleAddToUses = _HandleAddToUses;
    function IMCPUnitsToolsRegistrar.HandleRemoveFromUses = _HandleRemoveFromUses;
    function IMCPUnitsToolsRegistrar.HandleCreateNewProject =
      _HandleCreateNewProject;
    function IMCPUnitsToolsRegistrar.HandleCreateProjectKind =
      _HandleCreateProjectKind;
    function IMCPUnitsToolsRegistrar.HandleCloseAllProjects =
      _HandleCloseAllProjects;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsentRegistry: IMCPConsentRegistry;
      const AAuditLog: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

// ── Schema builders ───────────────────────────────────────────────────


function _OneStringParamSchema(const AName, ADesc: string): TJSONObject;
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

function _CreateNewUnitInputSchema: TJSONObject;
var
  LProps, LName, LWith: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LName := TJSONObject.Create;
  LName.AddPair('type', 'string');
  LName.AddPair('description', 'Unit name without extension.');
  LProps.AddPair('UnitName', LName);
  LWith := TJSONObject.Create;
  LWith.AddPair('type', 'boolean');
  LWith.AddPair('description', 'When true, also creates a paired .dfm form.');
  LProps.AddPair('WithForm', LWith);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('UnitName');
  LRequired.Add('WithForm');
  Result.AddPair('required', LRequired);
end;

function _AddToUsesInputSchema: TJSONObject;
var
  LProps, LTarget, LUnit, LSection: TJSONObject;
  LEnum: TJSONArray;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LTarget := TJSONObject.Create;
  LTarget.AddPair('type', 'string');
  LTarget.AddPair('description', 'Name of the unit whose uses clause is edited.');
  LProps.AddPair('TargetUnit', LTarget);
  LUnit := TJSONObject.Create;
  LUnit.AddPair('type', 'string');
  LUnit.AddPair('description', 'Identifier to add to the uses clause.');
  LProps.AddPair('UnitToAdd', LUnit);
  LSection := TJSONObject.Create;
  LSection.AddPair('type', 'string');
  LSection.AddPair('description', 'Which uses section to edit.');
  LEnum := TJSONArray.Create;
  LEnum.Add('interface');
  LEnum.Add('implementation');
  LSection.AddPair('enum', LEnum);
  LProps.AddPair('Section', LSection);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('TargetUnit');
  LRequired.Add('UnitToAdd');
  LRequired.Add('Section');
  Result.AddPair('required', LRequired);
end;

function _RemoveFromUsesInputSchema: TJSONObject;
var
  LProps, LTarget, LUnit: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LTarget := TJSONObject.Create;
  LTarget.AddPair('type', 'string');
  LTarget.AddPair('description', 'Name of the unit whose uses clause is edited.');
  LProps.AddPair('TargetUnit', LTarget);
  LUnit := TJSONObject.Create;
  LUnit.AddPair('type', 'string');
  LUnit.AddPair('description', 'Identifier to remove from any uses section.');
  LProps.AddPair('UnitToRemove', LUnit);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('TargetUnit');
  LRequired.Add('UnitToRemove');
  Result.AddPair('required', LRequired);
end;

function _BoolResultSchema: TJSONObject;
var
  LProps, LValue: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'boolean');
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function _StringResultSchema: TJSONObject;
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

function _UsesResultSchema: TJSONObject;
var
  LProps, LIface, LImpl, LItem, LFound: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LIface := TJSONObject.Create;
  LIface.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'string');
  LIface.AddPair('items', LItem);
  LProps.AddPair('iface', LIface);
  LImpl := TJSONObject.Create;
  LImpl.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'string');
  LImpl.AddPair('items', LItem);
  LProps.AddPair('impl', LImpl);
  LFound := TJSONObject.Create;
  LFound.AddPair('type', 'boolean');
  LProps.AddPair('found', LFound);
  Result.AddPair('properties', LProps);
end;

function _AppliedSchema: TJSONObject;
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

function _PathResultSchema: TJSONObject;
var
  LProps, LPath, LApplied: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LPath := TJSONObject.Create;
  LPath.AddPair('type', 'string');
  LProps.AddPair('path', LPath);
  LApplied := TJSONObject.Create;
  LApplied.AddPair('type', 'boolean');
  LProps.AddPair('applied', LApplied);
  Result.AddPair('properties', LProps);
end;

// Schema for the explicit CreateProject<Type> tools: the type is fixed by the
// tool itself, so the only inputs are the project Name (+ optional Directory) —
// no ProjectType param for an agent to guess wrong.
function _CreateProjectTypedInputSchema: TJSONObject;
var
  LProps, LName, LDir: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LName := TJSONObject.Create;
  LName.AddPair('type', 'string');
  LName.AddPair('description',
    'Project name — single Pascal identifier, no extension (e.g. "MyApp").');
  LProps.AddPair('Name', LName);
  LDir := TJSONObject.Create;
  LDir.AddPair('type', 'string');
  LDir.AddPair('description',
    'Optional sub-directory under the scratch root. ' +
    'Empty or omitted: project goes to scratch/<Name>.');
  LProps.AddPair('Directory', LDir);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('Name');
  Result.AddPair('required', LRequired);
end;

function _EmptyInputSchema: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

// Maps a consent decision to the audit-log `consent` token (ADR-067 carry).
{ TMCPUnitsToolsRegistrar }

constructor TMCPUnitsToolsRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TMCPUnitsToolsRegistrar: AFacade');
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

procedure TMCPUnitsToolsRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPUnitsToolsRegistrar.RegisterAll: AServer');
  // Order matches the catalog grouping: reads → navigation → writes.
  AServer.RegisterTool(_BuildIsUnitOpen);
  AServer.RegisterTool(_BuildGetUnitUses);
  AServer.RegisterTool(_BuildGetUnitFilePath);
  AServer.RegisterTool(_BuildOpenUnitInEditor);
  AServer.RegisterTool(_BuildAddUnitToProject);
  AServer.RegisterTool(_BuildRemoveUnitFromProject);
  AServer.RegisterTool(_BuildCreateNewUnit);
  AServer.RegisterTool(_BuildAddToUses);
  AServer.RegisterTool(_BuildRemoveFromUses);
  // Explicit, self-describing per-type project tools (the clear surface — the
  // tool name fixes the kind, so an agent never guesses a ProjectType string).
  // The old generic 'CreateNewProject' tool was removed (redundant with these six;
  // the agent never guesses a ProjectType string). The shared worker stays.
  AServer.RegisterTool(_BuildCreateProjectTyped('CreateProjectVCL',
    'Create new VCL application',
    'Creates a new VCL (classic Windows-only, Vcl.Forms) Delphi application in ' +
    'the scratch root (Temp\Aefos\<Name>) with a MainForm, and leaves the IDE ' +
    'in Design mode with the form active — ready for AddComponent. Use for a ' +
    'Windows desktop GUI.', 'vcl'));
  AServer.RegisterTool(_BuildCreateProjectTyped('CreateProjectFMX',
    'Create new FMX (FireMonkey) application',
    'Creates a new FireMonkey (FMX, cross-platform: Windows/macOS/iOS/Android) ' +
    'Delphi application in the scratch root (Temp\Aefos\<Name>) with a MainForm ' +
    '(.fmx), and leaves the IDE in Design mode with the form active — ready for ' +
    'AddComponent. Use for a cross-platform GUI.', 'fmx'));
  AServer.RegisterTool(_BuildCreateProjectTyped('CreateProjectConsole',
    'Create new console application',
    'Creates a new console application (.dpr, {$APPTYPE CONSOLE}) in the scratch ' +
    'root (Temp\Aefos\<Name>). No form is created.', 'console'));
  AServer.RegisterTool(_BuildCreateProjectTyped('CreateProjectPackage',
    'Create new package (BPL)',
    'Creates a new Delphi package (.dpk, requires rtl) in the scratch root ' +
    '(Temp\Aefos\<Name>). No form is created.', 'package'));
  AServer.RegisterTool(_BuildCreateProjectTyped('CreateProjectLibrary',
    'Create new library (DLL)',
    'Creates a new library/DLL (.dpr, library) in the scratch root ' +
    '(Temp\Aefos\<Name>). No form is created.', 'library'));
  AServer.RegisterTool(_BuildCreateProjectTyped('CreateProjectDUnitX',
    'Create new DUnitX test project',
    'Creates a new DUnitX test project (console test runner) in the scratch ' +
    'root (Temp\Aefos\<Name>). No form is created.', 'dunitx'));
  AServer.RegisterTool(_BuildCloseAllProjects);
end;

// ── Helpers ───────────────────────────────────────────────────────────

function TMCPUnitsToolsRegistrar._ReadBoolean(const AParams: TJSONObject;
  const AName: string): Boolean;
var
  LValue: TJSONValue;
begin
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create(AName + ' required');
  LValue := AParams.GetValue(AName);
  if not Assigned(LValue) then
    raise EMCPInvalidParams.Create(AName + ' required (boolean)');
  if LValue is TJSONTrue then
    Exit(True);
  if LValue is TJSONFalse then
    Exit(False);
  if LValue is TJSONBool then
    Exit(TJSONBool(LValue).AsBoolean);
  raise EMCPInvalidParams.Create(AName + ' must be a boolean');
end;

function TMCPUnitsToolsRegistrar._RequestGate(
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

procedure TMCPUnitsToolsRegistrar._AuditDenied(const AToolName,
  AArgs: string);
begin
  FAuditLog.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPUnitsToolsRegistrar._AuditApplied(const AToolName,
  AArgs: string; const ADecision: TMCPConsentDecision;
  const AChanged: Boolean);
var
  LOutcome: string;
begin
  // Per ADR-128 / BR-8: the audit-log line carries the changed flag so the
  // LLM (and the maintainer) can tell a no-op idempotent call from a real
  // source edit without a follow-up read.
  if AChanged then
    LOutcome := 'applied'
  else
    LOutcome := 'applied:changed=false';
  FAuditLog.Append(AToolName, AArgs, TMCPConsentToken.Token(ADecision), LOutcome);
end;

procedure TMCPUnitsToolsRegistrar._AuditFailed(const AToolName,
  AArgs: string; const ADecision: TMCPConsentDecision);
begin
  FAuditLog.Append(AToolName, AArgs, TMCPConsentToken.Token(ADecision), 'failed');
end;

function TMCPUnitsToolsRegistrar._BoolResult(const AValue: Boolean;
  const AChanged: Boolean; const AEmitChanged: Boolean): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(AValue));
    LObj.AddPair('applied', TJSONBool.Create(AValue));
    if AEmitChanged then
      LObj.AddPair('changed', TJSONBool.Create(AChanged));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPUnitsToolsRegistrar._StringResult(
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

function TMCPUnitsToolsRegistrar._UsesResult(const AIface,
  AImpl: TArray<string>; const AFound: Boolean): TMCPToolResult;
var
  LObj: TJSONObject;
  LIface, LImpl: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LIface := TJSONArray.Create;
    for LFor := 0 to High(AIface) do
      LIface.Add(AIface[LFor]);
    LObj.AddPair('iface', LIface);
    LImpl := TJSONArray.Create;
    for LFor := 0 to High(AImpl) do
      LImpl.Add(AImpl[LFor]);
    LObj.AddPair('impl', LImpl);
    LObj.AddPair('found', TJSONBool.Create(AFound));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPUnitsToolsRegistrar._PathResult(
  const APath: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('path', APath);
    LObj.AddPair('applied', TJSONBool.Create(APath <> ''));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

// ADR-130: write-tools reject unknown targets with -32602 InvalidParams and
// a structured data.detail payload {target, reason}. The detail is inlined
// in the message string — the server's _EmitError surfaces it verbatim.
procedure TMCPUnitsToolsRegistrar._DenyWithStructuredDetail(
  const AToolName, ATarget, AReason: string);
begin
  raise EMCPInvalidParams.Create(Format(
    '%s: target "%s" rejected; data.detail={"target":"%s","reason":"%s"}',
    [AToolName, ATarget, ATarget, AReason]));
end;

// ── Descriptors ───────────────────────────────────────────────────────

function TMCPUnitsToolsRegistrar._BuildIsUnitOpen: TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'IsUnitOpen',
    'Is unit open',
    'Checks whether a unit is currently open in the editor',
    _OneStringParamSchema('UnitName',
      'Unit name (with or without .pas extension).'),
    _BoolResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleIsUnitOpen(AParams, AContext);
    end);
end;

function TMCPUnitsToolsRegistrar._BuildGetUnitUses: TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetUnitUses',
    'Get unit uses',
    'Returns the uses clause (interface and implementation) of a unit',
    _OneStringParamSchema('UnitName',
      'Unit name whose uses clause is read.'),
    _UsesResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetUnitUses(AParams, AContext);
    end);
end;

function TMCPUnitsToolsRegistrar._BuildGetUnitFilePath: TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetUnitFilePath',
    'Get unit file path',
    'Returns the absolute path of a unit by name',
    _OneStringParamSchema('UnitName',
      'Unit name (with or without .pas extension).'),
    _StringResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetUnitFilePath(AParams, AContext);
    end);
end;

function TMCPUnitsToolsRegistrar._BuildOpenUnitInEditor: TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'OpenUnitInEditor',
    'Open unit in editor',
    'Opens a unit in the IDE code editor',
    _OneStringParamSchema('UnitName',
      'Unit name to open in the IDE editor.'),
    _BoolResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleOpenUnitInEditor(AParams, AContext);
    end);
end;

function TMCPUnitsToolsRegistrar._BuildAddUnitToProject: TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'AddUnitToProject',
    'Add unit to project',
    'Adds an existing unit to the project',
    _OneStringParamSchema('FilePath',
      'Absolute path to an existing .pas file.'),
    _BoolResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleAddUnitToProject(AParams, AContext);
    end);
end;

function TMCPUnitsToolsRegistrar._BuildRemoveUnitFromProject:
  TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'RemoveUnitFromProject',
    'Remove unit from project',
    'Removes a unit from the project (without deleting the file)',
    _OneStringParamSchema('UnitName',
      'Unit name to remove from the .dproj.'),
    _BoolResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRemoveUnitFromProject(AParams, AContext);
    end);
end;

function TMCPUnitsToolsRegistrar._BuildCreateNewUnit: TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'CreateNewUnit',
    'Create new unit',
    'Creates a new .pas unit and adds it to the active project. Use it to add ' +
    'a form to an already-open app. With WithForm=true: auto-detects the ' +
    'framework (VCL or FMX), generates the correct templates (.pas + .dfm) on ' +
    'disk and leaves the new form open in Design mode. ' +
    'For FMX: the .pas uses FMX.Forms/FMX.Controls and the .dfm uses ' +
    'FormFactor; when laying out controls use Position.X/Position.Y ' +
    '(not Left/Top). ' +
    sLineBreak +
    'RESULTING STATE (WithForm): new form active in Design mode. From there, ' +
    'fill the form by chaining the editor tools — each one describes the state ' +
    'it requires and the state it leaves: SendKeystroke (Alt+F12 = Design<->DFM ' +
    'text, F12 = Design<->Code), SetEditorFullContent (injects into the buffer ' +
    'of the current mode), SaveActiveFile (persists to disk).',
    _CreateNewUnitInputSchema,
    _PathResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleCreateNewUnit(AParams, AContext);
    end);
end;

function TMCPUnitsToolsRegistrar._BuildAddToUses: TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'AddToUses',
    'Add to uses clause',
    'Adds a unit to the uses clause',
    _AddToUsesInputSchema,
    _AppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleAddToUses(AParams, AContext);
    end,
    tiCode);
end;

function TMCPUnitsToolsRegistrar._BuildRemoveFromUses: TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'RemoveFromUses',
    'Remove from uses clause',
    'Removes a unit from the uses clause',
    _RemoveFromUsesInputSchema,
    _AppliedSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRemoveFromUses(AParams, AContext);
    end,
    tiCode);
end;

function TMCPUnitsToolsRegistrar._BuildCreateProjectTyped(
  const AName, ATitle, ADescription, AKind: string): TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
  LName, LKind: string;
begin
  LDispatch := Self;
  // Snapshot into locals so each tool's handler closure captures its OWN name +
  // kind (every factory call gets a fresh closure frame).
  LName := AName;
  LKind := AKind;
  Result := TMCPToolDescriptor.Create(
    AName,
    ATitle,
    ADescription,
    _CreateProjectTypedInputSchema,
    _PathResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleCreateProjectKind(LName, LKind, AParams, AContext);
    end);
end;

function TMCPUnitsToolsRegistrar._BuildCloseAllProjects: TMCPToolDescriptor;
var
  LDispatch: IMCPUnitsToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'CloseAllProjects',
    'Close all projects',
    'Closes all modules and projects open in the IDE (IOTAModuleServices.CloseAll).' +
    ' Use before CreateNewProject to avoid a project-group conflict.' +
    ' Destructive operation — discards unsaved changes.',
    _EmptyInputSchema,
    _BoolResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleCloseAllProjects(AParams, AContext);
    end);
end;

// ── Read / navigation handlers ────────────────────────────────────────

function TMCPUnitsToolsRegistrar._HandleIsUnitOpen(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName: string;
  LOpen: Boolean;
begin
  LUnitName := _ReadString(AParams, 'UnitName');
  LOpen := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LOpen := FFacade.IsUnitOpen(LUnitName);
    end);
  Result := _BoolResult(LOpen);
end;

function TMCPUnitsToolsRegistrar._HandleGetUnitUses(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName: string;
  LIface, LImpl: TArray<string>;
  LFound: Boolean;
begin
  LUnitName := _ReadString(AParams, 'UnitName');
  LFound := False;
  SetLength(LIface, 0);
  SetLength(LImpl, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      LFound := FFacade.GetUnitUses(LUnitName, LIface, LImpl);
    end);
  Result := _UsesResult(LIface, LImpl, LFound);
end;

function TMCPUnitsToolsRegistrar._HandleGetUnitFilePath(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName, LPath: string;
begin
  LUnitName := _ReadString(AParams, 'UnitName');
  LPath := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LPath := FFacade.GetUnitFilePath(LUnitName);
    end);
  Result := _StringResult(LPath);
end;

function TMCPUnitsToolsRegistrar._HandleOpenUnitInEditor(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName: string;
  LOpened: Boolean;
begin
  LUnitName := _ReadString(AParams, 'UnitName');
  LOpened := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LOpened := FFacade.OpenUnitInEditor(LUnitName);
    end);
  if not LOpened then
    _DenyWithStructuredDetail('OpenUnitInEditor', LUnitName,
      'unit-not-in-project');
  Result := _BoolResult(True);
end;

// ── Write handlers (consent-gated; ADR-127) ───────────────────────────

function TMCPUnitsToolsRegistrar._HandleAddUnitToProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFilePath: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LFilePath := _ReadString(AParams, 'FilePath');
  if not TFile.Exists(LFilePath) then
    _DenyWithStructuredDetail('AddUnitToProject', LFilePath, 'file-not-found');
  LDecision := _RequestGate(AContext, 'AddUnitToProject',
    'Add unit to the active project:', LFilePath);
  if LDecision = cdDenied then
  begin
    _AuditDenied('AddUnitToProject', LFilePath);
    raise EMCPUserDenied.Create('AddUnitToProject: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.AddUnitToProject(LFilePath);
    end);
  if LApplied then
    _AuditApplied('AddUnitToProject', LFilePath, LDecision, True)
  else
    _AuditFailed('AddUnitToProject', LFilePath, LDecision);
  Result := _BoolResult(LApplied);
end;

function TMCPUnitsToolsRegistrar._HandleRemoveUnitFromProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName, LPath: string;
  LDecision: TMCPConsentDecision;
  LApplied: Boolean;
begin
  LUnitName := _ReadString(AParams, 'UnitName');
  LPath := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LPath := FFacade.GetUnitFilePath(LUnitName);
    end);
  if LPath = '' then
    _DenyWithStructuredDetail('RemoveUnitFromProject', LUnitName,
      'unit-not-in-project');
  LDecision := _RequestGate(AContext, 'RemoveUnitFromProject',
    'Remove unit from the active project:', LUnitName);
  if LDecision = cdDenied then
  begin
    _AuditDenied('RemoveUnitFromProject', LUnitName);
    raise EMCPUserDenied.Create(
      'RemoveUnitFromProject: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.RemoveUnitFromProject(LUnitName);
    end);
  if LApplied then
    _AuditApplied('RemoveUnitFromProject', LUnitName, LDecision, True)
  else
    _AuditFailed('RemoveUnitFromProject', LUnitName, LDecision);
  Result := _BoolResult(LApplied);
end;

function TMCPUnitsToolsRegistrar._HandleCreateNewUnit(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName, LProjectPath, LPath: string;
  LWithForm, LApplied: Boolean;
  LDecision: TMCPConsentDecision;
begin
  LUnitName := _ReadString(AParams, 'UnitName');
  LWithForm := _ReadBoolean(AParams, 'WithForm');
  LProjectPath := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LProjectPath := FFacade.GetProjectPath;
    end);
  if LProjectPath = '' then
    _DenyWithStructuredDetail('CreateNewUnit', LUnitName, 'no-output-dir');
  // Collision pre-check (ADR-129).
  LPath := TPath.Combine(LProjectPath, LUnitName + '.pas');
  if TFile.Exists(LPath) then
    _DenyWithStructuredDetail('CreateNewUnit', LUnitName, 'name-collision');
  LDecision := _RequestGate(AContext, 'CreateNewUnit',
    'Create new unit in the active project:', LUnitName);
  if LDecision = cdDenied then
  begin
    _AuditDenied('CreateNewUnit', LUnitName);
    raise EMCPUserDenied.Create('CreateNewUnit: user denied the action');
  end;
  LApplied := False;
  LPath := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.CreateNewUnit(LUnitName, LWithForm, LPath);
    end);
  if LApplied then
    _AuditApplied('CreateNewUnit', LUnitName, LDecision, True)
  else
    _AuditFailed('CreateNewUnit', LUnitName, LDecision);
  if LApplied then
    Result := _PathResult(LPath)
  else
    Result := _PathResult('');
end;

function TMCPUnitsToolsRegistrar._HandleAddToUses(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LTarget, LUnitToAdd, LSection, LPath, LArgs: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LTarget := _ReadString(AParams, 'TargetUnit');
  LUnitToAdd := _ReadString(AParams, 'UnitToAdd');
  LSection := _ReadString(AParams, 'Section');
  if not (SameText(LSection, 'interface') or
          SameText(LSection, 'implementation')) then
    raise EMCPInvalidParams.Create('Section must be "interface" or "implementation"');
  LPath := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LPath := FFacade.GetUnitFilePath(LTarget);
    end);
  if LPath = '' then
    _DenyWithStructuredDetail('AddToUses', LTarget, 'unit-not-in-project');
  LArgs := Format('%s/%s@%s', [LTarget, LUnitToAdd, LSection]);
  LDecision := _RequestGate(AContext, 'AddToUses',
    'Add to uses clause:', LArgs);
  if LDecision = cdDenied then
  begin
    _AuditDenied('AddToUses', LArgs);
    raise EMCPUserDenied.Create('AddToUses: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.AddToUses(LTarget, LUnitToAdd, LSection, LChanged);
    end);
  if LApplied then
    _AuditApplied('AddToUses', LArgs, LDecision, LChanged)
  else
    _AuditFailed('AddToUses', LArgs, LDecision);
  Result := _BoolResult(LApplied, LChanged, True);
end;

function TMCPUnitsToolsRegistrar._HandleRemoveFromUses(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LTarget, LUnitToRemove, LPath, LArgs: string;
  LDecision: TMCPConsentDecision;
  LApplied, LChanged: Boolean;
begin
  LTarget := _ReadString(AParams, 'TargetUnit');
  LUnitToRemove := _ReadString(AParams, 'UnitToRemove');
  LPath := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LPath := FFacade.GetUnitFilePath(LTarget);
    end);
  if LPath = '' then
    _DenyWithStructuredDetail('RemoveFromUses', LTarget,
      'unit-not-in-project');
  LArgs := Format('%s/%s', [LTarget, LUnitToRemove]);
  LDecision := _RequestGate(AContext, 'RemoveFromUses',
    'Remove from uses clause:', LArgs);
  if LDecision = cdDenied then
  begin
    _AuditDenied('RemoveFromUses', LArgs);
    raise EMCPUserDenied.Create('RemoveFromUses: user denied the action');
  end;
  LApplied := False;
  LChanged := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.RemoveFromUses(LTarget, LUnitToRemove, LChanged);
    end);
  if LApplied then
    _AuditApplied('RemoveFromUses', LArgs, LDecision, LChanged)
  else
    _AuditFailed('RemoveFromUses', LArgs, LDecision);
  Result := _BoolResult(LApplied, LChanged, True);
end;

function TMCPUnitsToolsRegistrar._HandleCreateNewProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
begin
  // Generic entry — the kind comes from the ProjectType param. Kept for
  // back-compat; the explicit CreateProject<Type> tools are the clear surface.
  Result := _HandleCreateProjectKind('CreateNewProject',
    _ReadString(AParams, 'ProjectType'), AParams, AContext);
end;

// Shared project-creation worker. AKind (e.g. 'vcl'/'fmx'/'console') is supplied
// by the caller — the generic tool reads it from a param, each explicit
// CreateProject<Type> tool hard-codes it — so the facade gets one well-formed
// kind regardless of which tool the agent picked. AToolName drives the consent
// prompt, audit entries and error text.
function TMCPUnitsToolsRegistrar._HandleCreateProjectKind(
  const AToolName, AKind: string;
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LName, LDirectory, LDProjPath, LReason, LArgs: string;
  LVal: TJSONValue;
  LApplied: Boolean;
  LDecision: TMCPConsentDecision;
begin
  LName      := _ReadString(AParams, 'Name');
  LDirectory := '';
  if Assigned(AParams) then
  begin
    LVal := AParams.GetValue('Directory');
    if Assigned(LVal) then
      LDirectory := LVal.Value;
  end;
  LArgs := Format('%s (%s)', [LName, AKind]);
  LDecision := _RequestGate(AContext, AToolName, 'Create new project:', LArgs);
  if LDecision = cdDenied then
  begin
    _AuditDenied(AToolName, LArgs);
    raise EMCPUserDenied.Create(AToolName + ': user denied the action');
  end;
  LApplied   := False;
  LDProjPath := '';
  LReason    := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.CreateNewProject(LName, AKind, LDirectory,
        LDProjPath, LReason);
    end);
  if LApplied then
    _AuditApplied(AToolName, LArgs, LDecision, True)
  else
    _AuditFailed(AToolName, LArgs, LDecision);
  // A name collision (project already on disk) is a distinct, recoverable
  // condition — surface it as a clear structured error with the colliding path
  // instead of an opaque applied:false the agent cannot tell from a real
  // failure. data.detail is inlined in the message (the server forwards it
  // verbatim), mirroring _DenyWithStructuredDetail.
  if (not LApplied) and SameText(LReason, 'project-already-exists') then
    raise EMCPInvalidParams.Create(Format(
      '%s: project "%s" already exists; '
      + 'data.detail={"reason":"project-already-exists","existing":"%s"}',
      [AToolName, LName, LDProjPath]));
  Result := _PathResult(LDProjPath);
end;

function TMCPUnitsToolsRegistrar._HandleCloseAllProjects(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LApplied: Boolean;
  LDecision: TMCPConsentDecision;
begin
  LDecision := _RequestGate(AContext, 'CloseAllProjects',
    'Close all open projects in the IDE:', 'all-projects');
  if LDecision = cdDenied then
  begin
    _AuditDenied('CloseAllProjects', '');
    raise EMCPUserDenied.Create('CloseAllProjects: user denied the action');
  end;
  LApplied := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LApplied := FFacade.CloseAllProjects;
    end);
  if LApplied then
    _AuditApplied('CloseAllProjects', '', LDecision, True)
  else
    _AuditFailed('CloseAllProjects', '', LDecision);
  Result := _BoolResult(LApplied);
end;

// ── Public registration entries ───────────────────────────────────────

procedure RegisterUnitsTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: IMCPUnitsToolsRegistrar;
begin
  // Reference-counted lifetime: each tool-handler closure captures a
  // registrar reference so the registrar (and its consent/audit
  // collaborators) stays alive for the server's lifetime.
  LRegistrar := TMCPUnitsToolsRegistrar.Create(AFacade, nil, nil);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterUnitsTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPUnitsToolsRegistrar;
begin
  LRegistrar := TMCPUnitsToolsRegistrar.Create(AFacade, AConsentRegistry,
    AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

end.
