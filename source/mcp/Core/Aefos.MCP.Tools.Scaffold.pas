unit Aefos.MCP.Tools.Scaffold;

(*
  Project-scaffolding registrar — turns a folder-based template library into
  MCP tools, so the agent creates a whole project from a template instead of
  spelling out the boilerplate (2026-06-10).

  Two tools:
    * ListProjectTemplates — read-only. Scans ATemplatesRoot for <id>/template.json
      manifests and returns {id, name, category, description, vars} for each. The
      agent uses this to discover what exists (and to group by `category` —
      VCL / FMX / Package… — when asking the dev which one).
    * CreateProjectFromTemplate — consent-gated. Materialises a template FOLDER
      into a target directory: every file's name AND content is rendered with the
      given variables ({{Key}}), so `{{Name}}.dpr` becomes `MyApp.dpr`.

  Contract (engine=here, apply=there): the heavy lifting is the rtl-pure
  Aefos.Tools.Project.TProjectOps.ScaffoldFolder (validated standalone). This
  layer only wires it to the MCP surface + the consent/audit collaborators. It
  does NOT open the materialised project in the IDE yet — that needs a new OTA
  primitive (IMCPWorkspaceFacade.OpenFile) and lands as a focused follow-up; the
  tool returns project_path / main_file so the caller knows what to open.

  The template library is file-based and extensible: drop a folder with a
  template.json under ATemplatesRoot and it shows up — no rebuild (same pattern
  as the pytools and the MCP-server config).

  Boundary: requires Aefos.Tools (rtl-pure) + MCP.Core. No ToolsAPI.
*)

interface

uses
  Aefos.MCP.Server,
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog;

// Registers ListProjectTemplates + CreateProjectFromTemplate on AServer.
// ATemplatesRoot is the folder holding the template subfolders. AConsent may be
// nil (the Chat host relies on the facade's consent modal).
procedure RegisterScaffoldTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog; const ATemplatesRoot: string);

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  Aefos.Tools.Templates,
  Aefos.Tools.Project,
  Aefos.Tools.Files,
  Aefos.MCP.Tools.Common;

type
  // Dispatch seam so handler closures hold a ref-counted anchor to the
  // registrar (mirrors IPyToolDispatch / IProjectTextDispatch).
  IScaffoldDispatch = interface
    ['{2D9E7C14-3B86-4A57-9E20-5F8C1B40A7D2}']
    function ListProjectTemplates(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function CreateProjectFromTemplate(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

  TMCPScaffoldRegistrar = class(TInterfacedObject, IScaffoldDispatch)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsent: IMCPConsentRegistry;
    FAudit: IMCPAuditLog;
    FRoot: string;
    function _RequestGate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    procedure _Audit(const AName, ADetail, AConsent, AOutcome: string);
    function _BuildListDescriptor: TMCPToolDescriptor;
    function _BuildCreateDescriptor: TMCPToolDescriptor;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog;
      const ARoot: string);
    // IScaffoldDispatch
    function ListProjectTemplates(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function CreateProjectFromTemplate(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    procedure RegisterAll(const AServer: IMCPServer);
  end;

// ── small JSON / string helpers ──────────────────────────────────────────

function _Str(const AObj: TJSONObject; const AName: string): string;
var
  LValue: TJSONValue;
begin
  Result := '';
  if AObj = nil then
    Exit;
  LValue := AObj.GetValue(AName);
  if (LValue <> nil) and (LValue is TJSONString) then
    Result := TJSONString(LValue).Value;
end;

function _StrDef(const AObj: TJSONObject; const AName, ADefault: string): string;
begin
  Result := _Str(AObj, AName);
  if Result = '' then
    Result := ADefault;
end;

function _BoolDef(const AObj: TJSONObject; const AName: string;
  const ADefault: Boolean): Boolean;
var
  LValue: TJSONValue;
begin
  Result := ADefault;
  if AObj = nil then
    Exit;
  LValue := AObj.GetValue(AName);
  if LValue is TJSONTrue then
    Result := True
  else if LValue is TJSONFalse then
    Result := False;
end;

// A template variable value as a string (vars come as a JSON object).
function _VarStr(const AValue: TJSONValue): string;
begin
  if AValue is TJSONString then
    Result := TJSONString(AValue).Value
  else if AValue is TJSONNumber then
    Result := TJSONNumber(AValue).ToString
  else if AValue is TJSONTrue then
    Result := 'true'
  else if AValue is TJSONFalse then
    Result := 'false'
  else
    Result := '';
end;

function _JoinStr(const AItems: TArray<string>; const ASep: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AItems) do
    if I = 0 then
      Result := AItems[I]
    else
      Result := Result + ASep + AItems[I];
end;

{ TMCPScaffoldRegistrar }

constructor TMCPScaffoldRegistrar.Create(const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog;
  const ARoot: string);
begin
  inherited Create;
  FFacade := AFacade;
  FConsent := AConsent;
  FAudit := AAudit;
  FRoot := ARoot;
end;

function TMCPScaffoldRegistrar._RequestGate(const AContext: IMCPToolContext;
  const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
var
  LDecision: TMCPConsentDecision;
begin
  if Assigned(FConsent) and FConsent.IsSessionAllowed(AToolName) then
    Exit(cdAllowSession);
  LDecision := cdDenied;
  AContext.MarshalToMainThread(
    procedure
    begin
      LDecision := FFacade.RequestConsent(AToolName, ASummary, ADetail);
    end);
  if (LDecision = cdAllowSession) and Assigned(FConsent) then
    FConsent.GrantSession(AToolName);
  Result := LDecision;
end;

procedure TMCPScaffoldRegistrar._Audit(const AName, ADetail, AConsent,
  AOutcome: string);
begin
  if Assigned(FAudit) then
    FAudit.Append(AName, ADetail, AConsent, AOutcome);
end;

function TMCPScaffoldRegistrar.ListProjectTemplates(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDir, LManifest, LRaw: string;
  LJson, LItem, LRootObj: TJSONObject;
  LArr: TJSONArray;
  LVars: TJSONValue;
begin
  LArr := TJSONArray.Create;
  try
    if TDirectory.Exists(FRoot) then
      for LDir in TDirectory.GetDirectories(FRoot) do
      begin
        LManifest := TPath.Combine(LDir, 'template.json');
        if not TFile.Exists(LManifest) then
          Continue;
        LJson := nil;
        try
          try
            LRaw := TFile.ReadAllText(LManifest, TEncoding.UTF8);
            LJson := TJSONObject.ParseJSONValue(LRaw) as TJSONObject;
          except
            LJson := nil;
          end;
          if LJson = nil then
            Continue;
          LItem := TJSONObject.Create;
          LItem.AddPair('id', TPath.GetFileName(LDir));
          LItem.AddPair('name', _StrDef(LJson, 'name', TPath.GetFileName(LDir)));
          LItem.AddPair('category', _Str(LJson, 'category'));
          LItem.AddPair('description', _Str(LJson, 'description'));
          LVars := LJson.GetValue('vars');
          if LVars <> nil then
            LItem.AddPair('vars', LVars.Clone as TJSONValue);
          LArr.AddElement(LItem);
        finally
          LJson.Free;
        end;
      end;
    LRootObj := TJSONObject.Create;
    try
      LRootObj.AddPair('templates', LArr);
      LArr := nil; // ownership moved to LRootObj
      Result := TMCPToolResult.Text(LRootObj.ToJSON);
    finally
      LRootObj.Free;
    end;
  finally
    LArr.Free; // nil after ownership transfer
  end;
end;

function TMCPScaffoldRegistrar.CreateProjectFromTemplate(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LTemplateId, LTargetDir, LConsent: string;
  LOverwrite: Boolean;
  LTemplateDir: string;
  LVars: TArray<TToolTemplateVar>;
  LVarsObj: TJSONObject;
  LVarsVal: TJSONValue;
  LPair: TJSONPair;
  LDecision: TMCPConsentDecision;
  LRes: TToolScaffoldFolderResult;
  LSummary: TJSONObject;
  LFilesArr: TJSONArray;
  LRel, LProjectPath, LMsg: string;
  LOpened: Boolean;
begin
  LTemplateId := _Str(AParams, 'template_id');
  if LTemplateId = '' then
    raise EMCPError.Create(MCP_ERR_SERVER,
      'CreateProjectFromTemplate: "template_id" is required');
  LTargetDir := _Str(AParams, 'target_dir');
  if LTargetDir = '' then
    raise EMCPError.Create(MCP_ERR_SERVER,
      'CreateProjectFromTemplate: "target_dir" is required');
  LOverwrite := _BoolDef(AParams, 'overwrite', False);

  LTemplateDir := TPath.Combine(FRoot, LTemplateId);
  if not TDirectory.Exists(LTemplateDir) then
    raise EMCPError.Create(MCP_ERR_SERVER,
      'CreateProjectFromTemplate: unknown template "' + LTemplateId +
      '" (call ListProjectTemplates first)');

  // vars: a JSON object {Key: value, ...} -> TToolTemplateVar list.
  LVars := nil;
  LVarsVal := AParams.GetValue('vars');
  if LVarsVal is TJSONObject then
  begin
    LVarsObj := TJSONObject(LVarsVal);
    for LPair in LVarsObj do
      LVars := LVars + [TToolTemplateVar.Make(LPair.JsonString.Value,
        _VarStr(LPair.JsonValue))];
  end;

  LDecision := _RequestGate(AContext, 'CreateProjectFromTemplate',
    'Create a new project from template "' + LTemplateId + '" in:' +
    sLineBreak + LTargetDir, '');
  if LDecision = cdDenied then
  begin
    _Audit('CreateProjectFromTemplate', LTemplateId, 'denied', 'denied');
    raise EMCPUserDenied.Create(
      'CreateProjectFromTemplate: user denied the action');
  end;
  LConsent := TMCPConsentToken.Token(LDecision);

  // Materialise (pure engine): renders names + contents, refuses to clobber a
  // non-empty target unless overwrite, refuses wholesale if a var is missing.
  LRes := TProjectOps.ScaffoldFolder(LTemplateDir, LTargetDir, LVars,
    fbUtf8, LOverwrite);

  if LRes.TemplateMissing then
  begin
    _Audit('CreateProjectFromTemplate', LTemplateId, LConsent, 'empty-template');
    raise EMCPError.Create(MCP_ERR_SERVER,
      'CreateProjectFromTemplate: template "' + LTemplateId +
      '" has no files');
  end;
  if LRes.DestExists then
  begin
    _Audit('CreateProjectFromTemplate', LTargetDir, LConsent, 'dest-exists');
    raise EMCPError.Create(MCP_ERR_SERVER,
      'CreateProjectFromTemplate: target directory is not empty — pass ' +
      'overwrite=true to materialise into it anyway');
  end;
  if Length(LRes.Unresolved) > 0 then
  begin
    _Audit('CreateProjectFromTemplate', LTemplateId, LConsent, 'missing-vars');
    raise EMCPError.Create(MCP_ERR_SERVER,
      'CreateProjectFromTemplate: missing template variables: ' +
      _JoinStr(LRes.Unresolved, ', '));
  end;

  _Audit('CreateProjectFromTemplate',
    LTemplateId + ' -> ' + LTargetDir, LConsent, 'applied');

  // Open the freshly materialised project/group in the IDE (default true). The
  // facade routes to IOTAActionServices.OpenFile; main_file is the .groupproj/
  // .dproj/.dpr to open.
  if LRes.MainFile <> '' then
    LProjectPath := TPath.Combine(LTargetDir, LRes.MainFile)
  else
    LProjectPath := LTargetDir;
  LOpened := False;
  if _BoolDef(AParams, 'open', True) and (LRes.MainFile <> '') then
    AContext.MarshalToMainThread(
      procedure
      begin
        LOpened := FFacade.OpenFile(LProjectPath);
      end);

  LSummary := TJSONObject.Create;
  try
    LSummary.AddPair('created', TJSONBool.Create(True));
    // Clear English, agent-relayable feedback — the tool (not the agent) rendered
    // the template, so the agent just reports this back to the user.
    LMsg := Format(
      'Project generated from the "%s" template - %d file(s) written (main: %s).',
      [LTemplateId, LRes.FilesWritten, LRes.MainFile]);
    if LOpened then
      LMsg := LMsg + ' Opened in the IDE.';
    LSummary.AddPair('message', LMsg);
    LSummary.AddPair('template', LTemplateId);
    LSummary.AddPair('files_written', TJSONNumber.Create(LRes.FilesWritten));
    LSummary.AddPair('main_file', LRes.MainFile);
    LSummary.AddPair('project_path', LProjectPath);
    LSummary.AddPair('opened', TJSONBool.Create(LOpened));
    LFilesArr := TJSONArray.Create;
    for LRel in LRes.Written do
      LFilesArr.Add(LRel);
    LSummary.AddPair('files', LFilesArr);
    Result := TMCPToolResult.Text(LSummary.ToJSON);
  finally
    LSummary.Free;
  end;
end;

function TMCPScaffoldRegistrar._BuildListDescriptor: TMCPToolDescriptor;
var
  LDispatch: IScaffoldDispatch;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'ListProjectTemplates',
    'List project templates',
    'Lists the project templates available in the file-based template library ' +
    '(a folder per template, each with a template.json manifest). Returns an ' +
    'array of {id, name, category, description, vars}, where category groups ' +
    'them (e.g. VCL / FMX / Package / Console) and vars lists the variables ' +
    'CreateProjectFromTemplate expects. Read-only; call it first to discover ' +
    'what exists before creating a project.',
    TJSONObject.ParseJSONValue('{"type":"object"}') as TJSONObject,
    TJSONObject.ParseJSONValue('{"type":"object"}') as TJSONObject,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.ListProjectTemplates(AParams, AContext);
    end);
end;

function TMCPScaffoldRegistrar._BuildCreateDescriptor: TMCPToolDescriptor;
var
  LDispatch: IScaffoldDispatch;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'CreateProjectFromTemplate',
    'Create project from template',
    'Materialises a project template (a whole folder) into target_dir: every ' +
    'file''s name AND content is rendered, so a template file named ' +
    '"{{Name}}.dpr" becomes "MyApp.dpr". Supply template_id (from ' +
    'ListProjectTemplates), target_dir (an empty folder), and vars (an object ' +
    'of the template''s variables, e.g. {"Name":"MyApp"}). Refuses a non-empty ' +
    'target unless overwrite=true, and refuses entirely if a variable is ' +
    'missing (nothing is written). Returns {files_written, files, main_file, ' +
    'project_path, opened}. By default the new project/group is opened in the ' +
    'IDE (pass open=false to skip). The first call this session shows a ' +
    'confirmation modal and returns -32003 if denied.',
    TJSONObject.ParseJSONValue(
    '{"type":"object","required":["template_id","target_dir"],"properties":{' +
    '"template_id":{"type":"string","description":"Template id from ' +
    'ListProjectTemplates."},' +
    '"target_dir":{"type":"string","description":"Absolute path of the ' +
    '(empty) folder to create the project in."},' +
    '"vars":{"type":"object","description":"Template variables, e.g. ' +
    '{\"Name\":\"MyApp\"}. Every {{Var}} in the template must be provided."},' +
    '"overwrite":{"type":"boolean","description":"Materialise into a ' +
    'non-empty target_dir (default false)."},' +
    '"open":{"type":"boolean","description":"Open the created project in the ' +
    'IDE (default true)."}}}') as TJSONObject,
    TJSONObject.ParseJSONValue('{"type":"object"}') as TJSONObject,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.CreateProjectFromTemplate(AParams, AContext);
    end);
end;

procedure TMCPScaffoldRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  AServer.RegisterTool(_BuildListDescriptor);
  AServer.RegisterTool(_BuildCreateDescriptor);
end;

procedure RegisterScaffoldTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog; const ATemplatesRoot: string);
var
  LRegistrar: TMCPScaffoldRegistrar;
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create('RegisterScaffoldTools: AServer');
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('RegisterScaffoldTools: AFacade');
  // Not freed: the handler closures hold an IScaffoldDispatch reference and own
  // the lifetime (ADR-056), exactly like RegisterPyTools / RegisterProjectText.
  LRegistrar := TMCPScaffoldRegistrar.Create(AFacade, AConsent, AAudit,
    ATemplatesRoot);
  LRegistrar.RegisterAll(AServer);
end;

end.
