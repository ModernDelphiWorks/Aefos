unit Aefos.OTA.Terminal.MCP.Composition;

{
  Shared composition routine (ESP-070, S0; extended ESP-096, S2).

  RTL-only — no ToolsAPI, no VCL. Both TTerminalMCPHost and TestHost call
  RegisterTerminalMcpTools. The first 15 registrar groups are Core-owned and
  lock the 115-tool baseline to the production path (ADR-070-02).

  ESP-096 adds the first consumer-defined tool, CreateNewProject, registered
  after the 15 Core registrars via Core's public IMCPServer.RegisterTool — Core
  is never forked (ADR-096-01). Its handler binds to the consumer-owned
  IProjectCreatorService (ADR-096-03), obtained from the
  GProjectCreatorServiceFactory the UI ProjectCreator unit wires at BPL load. In
  the headless host that factory is nil: the descriptor still registers (so the
  catalog asserts 116), and an actual invocation without a live OTA service is
  refused. Catalog grows 115 -> 116 (ADR-096-02).

  ESP-096 follow-on adds SaveProjectGroup (#117) and RenameProjectGroup (#118) via
  RegisterTerminalProjectGroupManagementTools. Same pattern: consumer-owned
  IProjectGroupManagerService, factory wired by ProjectCreator at BPL load, nil in
  headless host. Catalog grows 116 -> 118.
}

interface

uses
  System.SysUtils,
  Aefos.MCP.Types,
  Aefos.MCP.Server,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog;

procedure RegisterTerminalMcpTools(
  const AServer:       IMCPServer;
  const AFacade:       IMCPWorkspaceFacade;
  const AConsent:      IMCPConsentRegistry;
  const AAudit:        IMCPAuditLog;
  const ARepoRootFunc: TFunc<string>);

// Consumer-side registrar for the project-lifecycle tools (ESP-096+). Builds the
// CreateNewProject descriptor and registers it via the public RegisterTool. The
// seam reused by ESP-097-103.
procedure RegisterTerminalProjectLifecycleTools(
  const AServer:  IMCPServer;
  const AFacade:  IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry;
  const AAudit:   IMCPAuditLog);

// Consumer-side registrar for project-group management tools (ESP-096 follow-on).
// Registers SaveProjectGroup (#117) and RenameProjectGroup (#118).
procedure RegisterTerminalProjectGroupManagementTools(
  const AServer:  IMCPServer;
  const AFacade:  IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry;
  const AAudit:   IMCPAuditLog);

implementation

uses
  System.JSON,
  System.IOUtils,
  System.StrUtils,
  Aefos.MCP.GitFacade,
  Aefos.MCP.Tools,
  Aefos.MCP.Tools.Project,
  Aefos.MCP.Tools.Units,
  Aefos.MCP.Tools.Editor,
  Aefos.MCP.Tools.Build,
  Aefos.MCP.Tools.Debug,
  Aefos.MCP.Tools.FormsDFM,
  Aefos.MCP.Tools.DPR,
  Aefos.MCP.Tools.CodeInsight,
  Aefos.MCP.Tools.ProjectGroup,
  Aefos.MCP.Tools.Packages,
  Aefos.MCP.Tools.IDE,
  Aefos.MCP.Tools.Resources,
  Aefos.MCP.Tools.Git,
  Aefos.MCP.Tools.VCS,
  Aefos.MCP.Tools.Rename,
  Aefos.MCP.Tools.AuditQuery,
  Aefos.MCP.Tools.PyTools,
  Aefos.MCP.Tools.ProjectText,
  Aefos.MCP.Tools.Scaffold,
  Aefos.OTA.Terminal.MCP.ProjectCreatePolicy,
  Aefos.OTA.Terminal.MCP.ProjectGroupManagerPolicy;

const
  CREATE_NEW_PROJECT   = 'CreateNewProject';
  SAVE_PROJECT_GROUP   = 'SaveProjectGroup';
  RENAME_PROJECT_GROUP = 'RenameProjectGroup';
  CLOSE_ALL_PROJECTS   = 'CloseAllProjects';
  // Disposable scratch root for created projects (BR10) — never the RADShell
  // tree. Sub-directory of %TEMP%; the optional `directory` arg is confined here.
  SCRATCH_SUBDIR = 'aefos-esp096';

type
  // Dispatch surface so the descriptor handler closure can capture a
  // reference-counted registrar (kept alive for the server's lifetime — the
  // lifetime contract Core's registrars use).
  ITerminalProjectLifecycleRegistrar = interface
    ['{3D6B1F08-9C42-4A7E-8B15-6E2F0A9C4D31}']
    function HandleCreateNewProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

  TTerminalProjectLifecycleRegistrar = class(TInterfacedObject,
    ITerminalProjectLifecycleRegistrar)
  private
    FFacade:  IMCPWorkspaceFacade;
    FConsent: IMCPConsentRegistry;
    FAudit:   IMCPAuditLog;
    FService: IProjectCreatorService;
    function _BuildDescriptor: TMCPToolDescriptor;
    function _ScratchRoot: string;
    function _RequestGate(const AContext: IMCPToolContext;
      const ADetail: string): TMCPConsentDecision;
    function _Result(const ACreated: Boolean;
      const APath, AType: string): TMCPToolResult;
    function HandleCreateNewProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

  ITerminalProjectGroupManagementRegistrar = interface
    ['{C4E8B2F1-7A93-4D65-B871-9E0F5C3A1D28}']
    function HandleSaveProjectGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRenameProjectGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleCloseAllProjects(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

  TTerminalProjectGroupManagementRegistrar = class(TInterfacedObject,
    ITerminalProjectGroupManagementRegistrar)
  private
    FFacade:  IMCPWorkspaceFacade;
    FConsent: IMCPConsentRegistry;
    FAudit:   IMCPAuditLog;
    FService: IProjectGroupManagerService;
    function _RequestGate(const AContext: IMCPToolContext;
      const ATool, ADetail: string): TMCPConsentDecision;
    function _Result(const AApplied: Boolean;
      const APath: string): TMCPToolResult;
    function HandleSaveProjectGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRenameProjectGroup(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleCloseAllProjects(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

// ── Schema builders ───────────────────────────────────────────────────

function _CreateNewProjectInputSchema: TJSONObject;
var
  LProps, LName, LType, LDir: TJSONObject;
  LEnum, LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;

  LName := TJSONObject.Create;
  LName.AddPair('type', 'string');
  LName.AddPair('description',
    'Project name (a single Pascal identifier; no path or extension).');
  LProps.AddPair('name', LName);

  LType := TJSONObject.Create;
  LType.AddPair('type', 'string');
  LType.AddPair('description', 'Project type to create.');
  LEnum := TJSONArray.Create;
  LEnum.Add('vcl');
  LEnum.Add('fmx');
  LEnum.Add('console');
  LEnum.Add('package');
  LEnum.Add('library');
  LType.AddPair('enum', LEnum);
  LProps.AddPair('type', LType);

  LDir := TJSONObject.Create;
  LDir.AddPair('type', 'string');
  LDir.AddPair('description',
    'Optional sub-directory under the scratch root; confined to it.');
  LProps.AddPair('directory', LDir);

  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('name');
  LRequired.Add('type');
  Result.AddPair('required', LRequired);
end;

function _CreateNewProjectOutputSchema: TJSONObject;
var
  LProps, LCreated, LPath, LType, LApplied: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LCreated := TJSONObject.Create;
  LCreated.AddPair('type', 'boolean');
  LProps.AddPair('created', LCreated);
  LPath := TJSONObject.Create;
  LPath.AddPair('type', 'string');
  LProps.AddPair('path', LPath);
  LType := TJSONObject.Create;
  LType.AddPair('type', 'string');
  LProps.AddPair('type', LType);
  LApplied := TJSONObject.Create;
  LApplied.AddPair('type', 'boolean');
  LProps.AddPair('applied', LApplied);
  Result.AddPair('properties', LProps);
end;

function _SaveProjectGroupInputSchema: TJSONObject;
var
  LProps, LPath: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LPath  := TJSONObject.Create;
  LPath.AddPair('type', 'string');
  LPath.AddPair('description',
    'Absolute path for the .groupproj file to write (including filename and extension).');
  LProps.AddPair('path', LPath);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('path');
  Result.AddPair('required', LRequired);
end;

function _RenameProjectGroupInputSchema: TJSONObject;
var
  LProps, LName: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LName  := TJSONObject.Create;
  LName.AddPair('type', 'string');
  LName.AddPair('description',
    'New base name for the project group (no path, no extension).');
  LProps.AddPair('name', LName);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('name');
  Result.AddPair('required', LRequired);
end;

function _ProjectGroupSaveOutputSchema: TJSONObject;
var
  LProps, LApplied, LPath: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps   := TJSONObject.Create;
  LApplied := TJSONObject.Create;
  LApplied.AddPair('type', 'boolean');
  LProps.AddPair('applied', LApplied);
  LPath := TJSONObject.Create;
  LPath.AddPair('type', 'string');
  LProps.AddPair('path', LPath);
  Result.AddPair('properties', LProps);
end;

// ── Helpers ───────────────────────────────────────────────────────────

function _ReadString(const AParams: TJSONObject; const AName: string;
  const ARequired: Boolean): string;
var
  LValue: TJSONValue;
begin
  Result := '';
  if not Assigned(AParams) then
  begin
    if ARequired then
      raise EMCPInvalidParams.Create(AName + ' required');
    Exit;
  end;
  LValue := AParams.GetValue(AName);
  if not (Assigned(LValue) and (LValue is TJSONString)) then
  begin
    if ARequired then
      raise EMCPInvalidParams.Create(AName + ' required (string)');
    Exit;
  end;
  Result := TJSONString(LValue).Value;
end;

// Non-partial refusal: raise InvalidParams with the kebab sentinel inlined in a
// structured data.detail, so the server surfaces it verbatim. No file written.
procedure _Refuse(const ATarget, AReason: string);
begin
  raise EMCPInvalidParams.Create(Format(
    '%s: target "%s" refused; data.detail={"target":"%s","reason":"%s"}',
    [CREATE_NEW_PROJECT, ATarget, ATarget, AReason]));
end;

function _ConsentToken(const ADecision: TMCPConsentDecision): string;
begin
  case ADecision of
    cdAllowOnce:    Result := 'once';
    cdAllowSession: Result := 'session';
  else
    Result := 'denied';
  end;
end;

{ TTerminalProjectLifecycleRegistrar }

constructor TTerminalProjectLifecycleRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade; const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create(
      'TTerminalProjectLifecycleRegistrar: AFacade');
  FFacade := AFacade;
  if Assigned(AConsent) then
    FConsent := AConsent
  else
    FConsent := TMCPConsentRegistry.Create;
  if Assigned(AAudit) then
    FAudit := AAudit
  else
    FAudit := TMCPAuditLog.Create;
  // Bind the OTA-backed creator service (nil in the headless host — the
  // descriptor still registers; an invocation without a service is refused).
  if Assigned(GProjectCreatorServiceFactory) then
    FService := GProjectCreatorServiceFactory();
end;

procedure TTerminalProjectLifecycleRegistrar.RegisterAll(
  const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TTerminalProjectLifecycleRegistrar.RegisterAll: AServer');
  AServer.RegisterTool(_BuildDescriptor);
end;

function TTerminalProjectLifecycleRegistrar._ScratchRoot: string;
begin
  Result := TPath.Combine(TPath.GetTempPath, SCRATCH_SUBDIR);
end;

function TTerminalProjectLifecycleRegistrar._BuildDescriptor: TMCPToolDescriptor;
var
  LDispatch: ITerminalProjectLifecycleRegistrar;
begin
  LDispatch := Self;
  Result := Default(TMCPToolDescriptor);
  Result.Name := CREATE_NEW_PROJECT;
  Result.Title := 'Create new project';
  Result.Description :=
    'Creates a fresh Delphi project (VCL/FMX/Console/Package/Library) in a ' +
    'disposable scratch root via ToolsAPI; works with no project open.';
  Result.InputSchema := _CreateNewProjectInputSchema;
  Result.OutputSchema := _CreateNewProjectOutputSchema;
  Result.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleCreateNewProject(AParams, AContext);
    end;
end;

function TTerminalProjectLifecycleRegistrar._RequestGate(
  const AContext: IMCPToolContext; const ADetail: string): TMCPConsentDecision;
var
  LDecision: TMCPConsentDecision;
begin
  if FConsent.IsSessionAllowed(CREATE_NEW_PROJECT) then
    Exit(cdAllowSession);
  LDecision := cdDenied;
  AContext.MarshalToMainThread(
    procedure
    begin
      LDecision := FFacade.RequestConsent(CREATE_NEW_PROJECT,
        'Create a new project in the scratch root:', ADetail);
    end);
  if LDecision = cdAllowSession then
    FConsent.GrantSession(CREATE_NEW_PROJECT);
  Result := LDecision;
end;

function TTerminalProjectLifecycleRegistrar._Result(const ACreated: Boolean;
  const APath, AType: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  Result := Default(TMCPToolResult);
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('created', TJSONBool.Create(ACreated));
    LObj.AddPair('applied', TJSONBool.Create(ACreated));
    LObj.AddPair('path', APath);
    LObj.AddPair('type', AType);
    Result.Content := LObj.ToJSON;
  finally
    LObj.Free;
  end;
end;

function TTerminalProjectLifecycleRegistrar.HandleCreateNewProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LName, LType, LDir: string;
  LPlan: TProjectCreatePlan;
  LDecision: TMCPConsentDecision;
  LOutcome: TProjectCreateResult;
begin
  LName := _ReadString(AParams, 'name', True);
  LType := _ReadString(AParams, 'type', True);
  LDir  := _ReadString(AParams, 'directory', False);

  // Pure plan: validate + classify + confine + no-overwrite. Refusals are
  // non-partial sentinels — nothing is written (AC4).
  LPlan := TProjectCreatePolicy.PlanCreate(LName, _ScratchRoot, LDir, LType,
    function(const APath: string): Boolean
    begin
      Result := TFile.Exists(APath);
    end);
  if not LPlan.Accepted then
    _Refuse(LName, LPlan.Reason);

  LDecision := _RequestGate(AContext, LName + ' (' + LPlan.Spec.TypeName + ')');
  if LDecision = cdDenied then
  begin
    FAudit.Append(CREATE_NEW_PROJECT, LName, 'denied', 'denied');
    raise EMCPUserDenied.Create(CREATE_NEW_PROJECT + ': user denied the action');
  end;

  if not Assigned(FService) then
    _Refuse(LName, 'no-viable-ota-path');

  LOutcome := Default(TProjectCreateResult);
  AContext.MarshalToMainThread(
    procedure
    begin
      LOutcome := FService.CreateProject(LPlan);
    end);

  if LOutcome.Created then
    FAudit.Append(CREATE_NEW_PROJECT, LName, _ConsentToken(LDecision), 'applied')
  else
    FAudit.Append(CREATE_NEW_PROJECT, LName, _ConsentToken(LDecision),
      'failed:' + LOutcome.ErrorReason);

  Result := _Result(LOutcome.Created, LOutcome.DProjPath, LOutcome.ProjectType);
end;

// ── Public registration entries ───────────────────────────────────────

procedure RegisterTerminalProjectLifecycleTools(
  const AServer:  IMCPServer;
  const AFacade:  IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry;
  const AAudit:   IMCPAuditLog);
var
  LRegistrar: ITerminalProjectLifecycleRegistrar;
  LImpl: TTerminalProjectLifecycleRegistrar;
begin
  LImpl := TTerminalProjectLifecycleRegistrar.Create(AFacade, AConsent, AAudit);
  LRegistrar := LImpl; // keep alive via the handler closure's captured reference
  LImpl.RegisterAll(AServer);
end;

{ TTerminalProjectGroupManagementRegistrar }

constructor TTerminalProjectGroupManagementRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade; const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create(
      'TTerminalProjectGroupManagementRegistrar: AFacade');
  FFacade  := AFacade;
  if Assigned(AConsent) then FConsent := AConsent
  else FConsent := TMCPConsentRegistry.Create;
  if Assigned(AAudit) then FAudit := AAudit
  else FAudit := TMCPAuditLog.Create;
  if Assigned(GProjectGroupManagerServiceFactory) then
    FService := GProjectGroupManagerServiceFactory();
end;

procedure TTerminalProjectGroupManagementRegistrar.RegisterAll(
  const AServer: IMCPServer);
var
  LDispatch: ITerminalProjectGroupManagementRegistrar;
  LSave, LRename: TMCPToolDescriptor;
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TTerminalProjectGroupManagementRegistrar.RegisterAll: AServer');
  LDispatch := Self;

  LSave := Default(TMCPToolDescriptor);
  LSave.Name := SAVE_PROJECT_GROUP;
  LSave.Title := 'Save project group';
  LSave.Description :=
    'Saves the current IDE project group to a .groupproj file at the specified path ' +
    '(SetFileName + Save). Works for both new unsaved groups and existing ones.';
  LSave.InputSchema  := _SaveProjectGroupInputSchema;
  LSave.OutputSchema := _ProjectGroupSaveOutputSchema;
  LSave.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSaveProjectGroup(AParams, AContext);
    end;
  AServer.RegisterTool(LSave);

  LRename := Default(TMCPToolDescriptor);
  LRename.Name := RENAME_PROJECT_GROUP;
  LRename.Title := 'Rename project group';
  LRename.Description :=
    'Renames the current project group .groupproj file in-place (same directory, ' +
    'new base name). Deletes the old file after writing the new one. Requires the ' +
    'group to already be saved (use SaveProjectGroup first if not).';
  LRename.InputSchema  := _RenameProjectGroupInputSchema;
  LRename.OutputSchema := _ProjectGroupSaveOutputSchema;
  LRename.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRenameProjectGroup(AParams, AContext);
    end;
  AServer.RegisterTool(LRename);
  // CloseAllProjects moved to MCP.Core - already registered by RegisterUnitsTools.
end;

function TTerminalProjectGroupManagementRegistrar._RequestGate(
  const AContext: IMCPToolContext;
  const ATool, ADetail: string): TMCPConsentDecision;
var
  LDecision: TMCPConsentDecision;
begin
  if FConsent.IsSessionAllowed(ATool) then
    Exit(cdAllowSession);
  LDecision := cdDenied;
  AContext.MarshalToMainThread(
    procedure
    begin
      LDecision := FFacade.RequestConsent(ATool,
        'Modify the project group file:', ADetail);
    end);
  if LDecision = cdAllowSession then
    FConsent.GrantSession(ATool);
  Result := LDecision;
end;

function TTerminalProjectGroupManagementRegistrar._Result(
  const AApplied: Boolean; const APath: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  Result := Default(TMCPToolResult);
  LObj   := TJSONObject.Create;
  try
    LObj.AddPair('applied', TJSONBool.Create(AApplied));
    LObj.AddPair('path', APath);
    Result.Content := LObj.ToJSON;
  finally
    LObj.Free;
  end;
end;

function TTerminalProjectGroupManagementRegistrar.HandleSaveProjectGroup(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LPath:    string;
  LOutcome: TProjectGroupSaveResult;
begin
  LPath := _ReadString(AParams, 'path', True);
  if not LPath.EndsWith('.groupproj', True) then
    LPath := LPath + '.groupproj';

  if not Assigned(FService) then
    raise EMCPInvalidParams.Create(
      SAVE_PROJECT_GROUP + ': no-viable-ota-path');

  LOutcome := Default(TProjectGroupSaveResult);
  AContext.MarshalToMainThread(
    procedure
    begin
      LOutcome := FService.SaveGroupAs(LPath);
    end);

  FAudit.Append(SAVE_PROJECT_GROUP, LPath, 'once',
    IfThen(LOutcome.Applied, 'applied', 'failed:' + LOutcome.ErrorReason));

  if not LOutcome.Applied then
    raise EMCPInvalidParams.Create(Format(
      '%s: %s refused; data.detail={"reason":"%s"}',
      [SAVE_PROJECT_GROUP, LPath, LOutcome.ErrorReason]));

  Result := _Result(True, LOutcome.Path);
end;

function TTerminalProjectGroupManagementRegistrar.HandleRenameProjectGroup(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LName:     string;
  LDecision: TMCPConsentDecision;
  LOutcome:  TProjectGroupSaveResult;
begin
  LName := _ReadString(AParams, 'name', True);

  LDecision := _RequestGate(AContext, RENAME_PROJECT_GROUP, LName + '.groupproj');
  if LDecision = cdDenied then
  begin
    FAudit.Append(RENAME_PROJECT_GROUP, LName, 'denied', 'denied');
    raise EMCPUserDenied.Create(RENAME_PROJECT_GROUP + ': user denied the action');
  end;

  if not Assigned(FService) then
    raise EMCPInvalidParams.Create(
      RENAME_PROJECT_GROUP + ': no-viable-ota-path');

  LOutcome := Default(TProjectGroupSaveResult);
  AContext.MarshalToMainThread(
    procedure
    begin
      LOutcome := FService.RenameGroup(LName);
    end);

  FAudit.Append(RENAME_PROJECT_GROUP, LName, _ConsentToken(LDecision),
    IfThen(LOutcome.Applied, 'applied', 'failed:' + LOutcome.ErrorReason));

  if not LOutcome.Applied then
    raise EMCPInvalidParams.Create(Format(
      '%s: "%s" refused; data.detail={"reason":"%s"}',
      [RENAME_PROJECT_GROUP, LName, LOutcome.ErrorReason]));

  Result := _Result(True, LOutcome.Path);
end;

function TTerminalProjectGroupManagementRegistrar.HandleCloseAllProjects(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDone: Boolean;
begin
  if not Assigned(FService) then
    raise EMCPInvalidParams.Create(CLOSE_ALL_PROJECTS + ': no-viable-ota-path');

  LDone := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LDone := FService.CloseAll;
    end);

  FAudit.Append(CLOSE_ALL_PROJECTS, '', 'once',
    IfThen(LDone, 'applied', 'failed:close-canceled'));

  if not LDone then
    raise EMCPInvalidParams.Create(
      CLOSE_ALL_PROJECTS + ': close-canceled; data.detail={"reason":"close-canceled"}');

  Result := _Result(True, '');
end;

procedure RegisterTerminalProjectGroupManagementTools(
  const AServer:  IMCPServer;
  const AFacade:  IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry;
  const AAudit:   IMCPAuditLog);
var
  LRegistrar: ITerminalProjectGroupManagementRegistrar;
  LImpl: TTerminalProjectGroupManagementRegistrar;
begin
  LImpl      := TTerminalProjectGroupManagementRegistrar.Create(AFacade, AConsent, AAudit);
  LRegistrar := LImpl;
  LImpl.RegisterAll(AServer);
end;

procedure RegisterTerminalMcpTools(
  const AServer:       IMCPServer;
  const AFacade:       IMCPWorkspaceFacade;
  const AConsent:      IMCPConsentRegistry;
  const AAudit:        IMCPAuditLog;
  const ARepoRootFunc: TFunc<string>);
var
  LGit: IMCPGitFacade;
begin
  RegisterTools(AServer, AFacade, AConsent, AAudit);
  RegisterProjectTools(AServer, AFacade, AConsent, AAudit);
  RegisterUnitsTools(AServer, AFacade, AConsent, AAudit);
  RegisterEditorTools(AServer, AFacade, AConsent, AAudit);
  RegisterBuildTools(AServer, AFacade, AConsent, AAudit);
  // Agent debug family (breakpoints / state / step / evaluate / call stack /
  // threads / locals / tracepoint) - same shared registrar the chat server
  // uses; the Terminal-hosted agent gets debug parity. OTA in DebugService,
  // guards in the headless-tested DebugPolicy.
  RegisterDebugTools(AServer);
  RegisterFormsDFMTools(AServer, AFacade, AConsent, AAudit);
  RegisterDPRTools(AServer, AFacade, AConsent, AAudit);
  RegisterCodeInsightTools(AServer, AFacade, AConsent, AAudit);
  RegisterProjectGroupTools(AServer, AFacade, AConsent, AAudit);
  RegisterPackagesTools(AServer, AFacade, AConsent, AAudit);
  RegisterIDETools(AServer, AFacade, AConsent, AAudit);
  RegisterResourcesTools(AServer, AFacade, AConsent, AAudit);
  // ONE facade for both git groups: the plain subprocess tools AND the HEAD side
  // of the IDE-only VCS group (buffer-vs-HEAD diff / history fallback).
  LGit := TGitFacade.Create(ARepoRootFunc);
  RegisterGitTools(AServer, LGit);
  // IDE-ONLY VCS group (ShowDiffInIDE / GetFileHistory / GetDiffOfActiveFile):
  // the IDE's native diff viewer, its own file-history providers, and the DIRTY
  // editor buffer vs HEAD — what a raw terminal cannot reach.
  RegisterVCSTools(AServer, LGit);
  RegisterRenameTools(AServer, AFacade, AConsent, AAudit);
  RegisterAuditQueryTools(AServer);
  // ESP-096 follow-on - SaveProjectGroup + RenameProjectGroup.
  // CreateNewProject and CloseAllProjects moved to MCP.Core (RegisterUnitsTools).
  RegisterTerminalProjectGroupManagementTools(AServer, AFacade, AConsent, AAudit);
  // Python tools: each <tool>\tool.json becomes a live MCP tool, consent + audit
  // gated. TWO sources now - the user's own pytools folder (still where new ones
  // are created) and the tools shipped by installed addons, namespaced
  // <slug>__. Empty/missing roots register nothing. See PyToolRoots.
  RegisterPyTools(AServer, AFacade, AConsent, AAudit,
    PyToolRoots(TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'),
      'pytools')));
  // Project-wide text/encoding tools (ReplaceInProject / FixEncoding) wrapping
  // the rtl-pure Aefos.Tools engine; consent + audit gated.
  RegisterProjectTextTools(AServer, AFacade, AConsent, AAudit);
  // Project scaffolding (drop-a-folder templates): ListProjectTemplates +
  // CreateProjectFromTemplate, wrapping the rtl-pure engine; consent + audit.
  RegisterScaffoldTools(AServer, AFacade, AConsent, AAudit,
    TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'), 'templates'));
end;

end.
