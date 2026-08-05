unit Aefos.MCP.Tools.Editor;

(*
  Editor-group MCP tools (ESP-002, Epic 7/7 Demand 4/8).

  Exposes 14 new tools (5 reads, 1 navigation, 8 consent-gated writes)
  routing through IMCPWorkspaceFacade. Decoupled from RAD Studio ToolsAPI.
*)

interface

uses
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.FlowGuide, // IMCPFlowState (SaveAllFiles guard)
  Aefos.MCP.Server;

type
  IMCPEditorToolsRegistrar = interface
    ['{C0E8F4D1-A923-4731-8B12-5C0E8F4D1A82}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleGetEditorActiveFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetEditorCursorPosition(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleInsertCodeAtCursor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleReplaceEditorSelection(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetEditorFullContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSetEditorFullContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleFindInEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleReplaceInEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleFindInProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSaveActiveFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSaveAllFiles(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleUndoEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetOpenEditorFiles(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleCloseFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleSendKeystroke(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

procedure RegisterEditorTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterEditorTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.SysUtils,
  Aefos.MCP.Tools.Common;

type
  TMCPEditorToolsRegistrar = class(TMCPToolsRegistrarBase, IMCPEditorToolsRegistrar)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsentRegistry: IMCPConsentRegistry;
    FAuditLog: IMCPAuditLog;

    // Descriptor builders (15 total)
    function _BuildGetEditorActiveFile: TMCPToolDescriptor;
    function _BuildSetEditorCursorPosition: TMCPToolDescriptor;
    function _BuildInsertCodeAtCursor: TMCPToolDescriptor;
    function _BuildReplaceEditorSelection: TMCPToolDescriptor;
    function _BuildGetEditorFullContent: TMCPToolDescriptor;
    function _BuildSetEditorFullContent: TMCPToolDescriptor;
    function _BuildFindInEditor: TMCPToolDescriptor;
    function _BuildReplaceInEditor: TMCPToolDescriptor;
    function _BuildFindInProject: TMCPToolDescriptor;
    function _BuildSaveActiveFile: TMCPToolDescriptor;
    function _BuildSaveAllFiles: TMCPToolDescriptor;
    function _BuildUndoEditor: TMCPToolDescriptor;
    function _BuildGetOpenEditorFiles: TMCPToolDescriptor;
    function _BuildCloseFile: TMCPToolDescriptor;
    function _BuildSendKeystroke: TMCPToolDescriptor;

    // Handlers
    function _HandleGetEditorActiveFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetEditorCursorPosition(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleInsertCodeAtCursor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleReplaceEditorSelection(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetEditorFullContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSetEditorFullContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleFindInEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleReplaceInEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleFindInProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSaveActiveFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSaveAllFiles(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleUndoEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetOpenEditorFiles(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleCloseFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleSendKeystroke(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;

    // Helpers
    function _ReadInteger(const AParams: TJSONObject; const AName: string): Integer;
    function _ReadBoolean(const AParams: TJSONObject; const AName: string): Boolean;
    function _RequestGate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    procedure _AuditDenied(const AToolName, AArgs: string);
    procedure _AuditApplied(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision; const AChanged: Boolean);
    procedure _AuditFailed(const AToolName, AArgs: string;
      const ADecision: TMCPConsentDecision);
    procedure _DenyWithStructuredDetail(const AToolName, ATarget, AReason: string);

    // IMCPEditorToolsRegistrar maps
    function IMCPEditorToolsRegistrar.HandleGetEditorActiveFile = _HandleGetEditorActiveFile;
    function IMCPEditorToolsRegistrar.HandleSetEditorCursorPosition = _HandleSetEditorCursorPosition;
    function IMCPEditorToolsRegistrar.HandleInsertCodeAtCursor = _HandleInsertCodeAtCursor;
    function IMCPEditorToolsRegistrar.HandleReplaceEditorSelection = _HandleReplaceEditorSelection;
    function IMCPEditorToolsRegistrar.HandleGetEditorFullContent = _HandleGetEditorFullContent;
    function IMCPEditorToolsRegistrar.HandleSetEditorFullContent = _HandleSetEditorFullContent;
    function IMCPEditorToolsRegistrar.HandleFindInEditor = _HandleFindInEditor;
    function IMCPEditorToolsRegistrar.HandleReplaceInEditor = _HandleReplaceInEditor;
    function IMCPEditorToolsRegistrar.HandleFindInProject = _HandleFindInProject;
    function IMCPEditorToolsRegistrar.HandleSaveActiveFile = _HandleSaveActiveFile;
    function IMCPEditorToolsRegistrar.HandleSaveAllFiles = _HandleSaveAllFiles;
    function IMCPEditorToolsRegistrar.HandleUndoEditor = _HandleUndoEditor;
    function IMCPEditorToolsRegistrar.HandleGetOpenEditorFiles = _HandleGetOpenEditorFiles;
    function IMCPEditorToolsRegistrar.HandleCloseFile = _HandleCloseFile;
    function IMCPEditorToolsRegistrar.HandleSendKeystroke = _HandleSendKeystroke;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsentRegistry: IMCPConsentRegistry;
      const AAuditLog: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

// -- Schema Builders -------------------------------------------

function _EmptyInputSchema: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

function _ActiveFileSchema: TJSONObject;
var
  LProps, LName, LPath: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LName := TJSONObject.Create;
  LName.AddPair('type', 'string');
  LProps.AddPair('name', LName);
  LPath := TJSONObject.Create;
  LPath.AddPair('type', 'string');
  LProps.AddPair('path', LPath);
  Result.AddPair('properties', LProps);
end;

function _CursorInputSchema: TJSONObject;
var
  LProps, LLine, LCol: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LLine := TJSONObject.Create;
  LLine.AddPair('type', 'integer');
  LProps.AddPair('Line', LLine);
  LCol := TJSONObject.Create;
  LCol.AddPair('type', 'integer');
  LProps.AddPair('Col', LCol);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('Line');
  LRequired.Add('Col');
  Result.AddPair('required', LRequired);
end;

function _InsertCodeInputSchema: TJSONObject;
var
  LProps, LCode: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LCode := TJSONObject.Create;
  LCode.AddPair('type', 'string');
  LProps.AddPair('Code', LCode);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('Code');
  Result.AddPair('required', LRequired);
end;

function _ReplaceSelectionInputSchema: TJSONObject;
var
  LProps, LNewText: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LNewText := TJSONObject.Create;
  LNewText.AddPair('type', 'string');
  LProps.AddPair('NewText', LNewText);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('NewText');
  Result.AddPair('required', LRequired);
end;

function _SetFullContentInputSchema: TJSONObject;
var
  LProps, LSource: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LSource := TJSONObject.Create;
  LSource.AddPair('type', 'string');
  LProps.AddPair('Source', LSource);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('Source');
  Result.AddPair('required', LRequired);
end;

function _FindInEditorInputSchema: TJSONObject;
var
  LProps, LText, LCase: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LText := TJSONObject.Create;
  LText.AddPair('type', 'string');
  LProps.AddPair('Text', LText);
  LCase := TJSONObject.Create;
  LCase.AddPair('type', 'boolean');
  LProps.AddPair('CaseSensitive', LCase);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('Text');
  LRequired.Add('CaseSensitive');
  Result.AddPair('required', LRequired);
end;

function _ReplaceInEditorInputSchema: TJSONObject;
var
  LProps, LFind, LReplace, LAll: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LFind := TJSONObject.Create;
  LFind.AddPair('type', 'string');
  LProps.AddPair('Find', LFind);
  LReplace := TJSONObject.Create;
  LReplace.AddPair('type', 'string');
  LProps.AddPair('Replace', LReplace);
  LAll := TJSONObject.Create;
  LAll.AddPair('type', 'boolean');
  LProps.AddPair('All', LAll);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('Find');
  LRequired.Add('Replace');
  LRequired.Add('All');
  Result.AddPair('required', LRequired);
end;

function _CloseFileInputSchema: TJSONObject;
var
  LProps, LPath, LSave: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LPath := TJSONObject.Create;
  LPath.AddPair('type', 'string');
  LProps.AddPair('FilePath', LPath);
  LSave := TJSONObject.Create;
  LSave.AddPair('type', 'boolean');
  LProps.AddPair('SaveFirst', LSave);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add('FilePath');
  LRequired.Add('SaveFirst');
  Result.AddPair('required', LRequired);
end;

function _OccurrencesResultSchema: TJSONObject;
var
  LProps, LLine, LCol: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LLine := TJSONObject.Create;
  LLine.AddPair('type', 'integer');
  LProps.AddPair('line', LLine);
  LCol := TJSONObject.Create;
  LCol.AddPair('type', 'integer');
  LProps.AddPair('col', LCol);
  Result.AddPair('properties', LProps);
end;

function _FindInProjectResultSchema: TJSONObject;
var
  LProps, LFile, LLine, LCol: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LFile := TJSONObject.Create;
  LFile.AddPair('type', 'string');
  LProps.AddPair('file', LFile);
  LLine := TJSONObject.Create;
  LLine.AddPair('type', 'integer');
  LProps.AddPair('line', LLine);
  LCol := TJSONObject.Create;
  LCol.AddPair('type', 'integer');
  LProps.AddPair('col', LCol);
  Result.AddPair('properties', LProps);
end;

function _OpenFilesResultSchema: TJSONObject;
var
  LProps, LName, LPath, LModified: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LName := TJSONObject.Create;
  LName.AddPair('type', 'string');
  LProps.AddPair('name', LName);
  LPath := TJSONObject.Create;
  LPath.AddPair('type', 'string');
  LProps.AddPair('path', LPath);
  LModified := TJSONObject.Create;
  LModified.AddPair('type', 'boolean');
  LProps.AddPair('modified', LModified);
  Result.AddPair('properties', LProps);
end;

function _IntegerResultSchema: TJSONObject;
var
  LProps, LValue: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'integer');
  LProps.AddPair('value', LValue);
  Result.AddPair('properties', LProps);
end;

function _BoolResultSchema: TJSONObject;
var
  LProps, LValue, LApplied, LChanged: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LValue := TJSONObject.Create;
  LValue.AddPair('type', 'boolean');
  LProps.AddPair('value', LValue);
  LApplied := TJSONObject.Create;
  LApplied.AddPair('type', 'boolean');
  LProps.AddPair('applied', LApplied);
  LChanged := TJSONObject.Create;
  LChanged.AddPair('type', 'boolean');
  LProps.AddPair('changed', LChanged);
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

// -- RegisterEditorTools Procedures ----------------------------

procedure RegisterEditorTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
begin
  RegisterEditorTools(AServer, AFacade, nil, nil);
end;

procedure RegisterEditorTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPEditorToolsRegistrar;
begin
  LRegistrar := TMCPEditorToolsRegistrar.Create(AFacade, AConsentRegistry, AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

{ TMCPEditorToolsRegistrar }

constructor TMCPEditorToolsRegistrar.Create(
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TMCPEditorToolsRegistrar: AFacade');
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

procedure TMCPEditorToolsRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create('TMCPEditorToolsRegistrar.RegisterAll: AServer');
  AServer.RegisterTool(_BuildGetEditorActiveFile);
  AServer.RegisterTool(_BuildSetEditorCursorPosition);
  AServer.RegisterTool(_BuildInsertCodeAtCursor);
  AServer.RegisterTool(_BuildReplaceEditorSelection);
  AServer.RegisterTool(_BuildGetEditorFullContent);
  AServer.RegisterTool(_BuildSetEditorFullContent);
  AServer.RegisterTool(_BuildFindInEditor);
  AServer.RegisterTool(_BuildReplaceInEditor);
  AServer.RegisterTool(_BuildFindInProject);
  AServer.RegisterTool(_BuildSaveActiveFile);
  AServer.RegisterTool(_BuildSaveAllFiles);
  AServer.RegisterTool(_BuildUndoEditor);
  AServer.RegisterTool(_BuildGetOpenEditorFiles);
  AServer.RegisterTool(_BuildCloseFile);
  AServer.RegisterTool(_BuildSendKeystroke);
end;

// -- Helpers ---------------------------------------------------

function TMCPEditorToolsRegistrar._ReadInteger(const AParams: TJSONObject;
  const AName: string): Integer;
var
  LValue: TJSONValue;
begin
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create(AName + ' required');
  LValue := AParams.GetValue(AName);
  if not (Assigned(LValue) and (LValue is TJSONNumber)) then
    raise EMCPInvalidParams.Create(AName + ' required (integer)');
  Result := TJSONNumber(LValue).AsInt;
end;

function TMCPEditorToolsRegistrar._ReadBoolean(const AParams: TJSONObject;
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

function TMCPEditorToolsRegistrar._RequestGate(
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

procedure TMCPEditorToolsRegistrar._AuditDenied(const AToolName, AArgs: string);
begin
  FAuditLog.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPEditorToolsRegistrar._AuditApplied(const AToolName, AArgs: string;
  const ADecision: TMCPConsentDecision; const AChanged: Boolean);
var
  LOutcome: string;
begin
  if AChanged then
    LOutcome := 'applied'
  else
    LOutcome := 'applied:changed=false';
  FAuditLog.Append(AToolName, AArgs, TMCPConsentToken.Token(ADecision), LOutcome);
end;

procedure TMCPEditorToolsRegistrar._AuditFailed(const AToolName, AArgs: string;
  const ADecision: TMCPConsentDecision);
begin
  FAuditLog.Append(AToolName, AArgs, TMCPConsentToken.Token(ADecision), 'failed');
end;

procedure TMCPEditorToolsRegistrar._DenyWithStructuredDetail(
  const AToolName, ATarget, AReason: string);
begin
  raise EMCPInvalidParams.Create(Format(
    '%s: target "%s" rejected; data.detail={"target":"%s","reason":"%s"}',
    [AToolName, ATarget, ATarget, AReason]));
end;

// -- Descriptor Builders ---------------------------------------

function TMCPEditorToolsRegistrar._BuildGetEditorActiveFile: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetEditorActiveFile',
    'Get editor active file',
    'Returns the file currently active in the editor',
    _EmptyInputSchema,
    _ActiveFileSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetEditorActiveFile(AParams, AContext);
    end);
end;

function TMCPEditorToolsRegistrar._BuildSetEditorCursorPosition: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SetEditorCursorPosition',
    'Set editor cursor position',
    'Moves the cursor to a specific line/column',
    _CursorInputSchema,
    _BoolResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetEditorCursorPosition(AParams, AContext);
    end);
end;

function TMCPEditorToolsRegistrar._BuildInsertCodeAtCursor: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'InsertCodeAtCursor',
    'Insert code at cursor',
    'Inserts code at the current cursor position',
    _InsertCodeInputSchema,
    _BoolResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleInsertCodeAtCursor(AParams, AContext);
    end,
    tiCode);
end;

function TMCPEditorToolsRegistrar._BuildReplaceEditorSelection: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'ReplaceEditorSelection',
    'Replace editor selection',
    'Replaces the current selection in the editor',
    _ReplaceSelectionInputSchema,
    _BoolResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleReplaceEditorSelection(AParams, AContext);
    end,
    tiCode);
end;

function TMCPEditorToolsRegistrar._BuildGetEditorFullContent: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetEditorFullContent',
    'Get editor full content',
    'Returns the full content of the active editor buffer',
    _EmptyInputSchema,
    _StringResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetEditorFullContent(AParams, AContext);
    end);
end;

function TMCPEditorToolsRegistrar._BuildSetEditorFullContent: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SetEditorFullContent',
    'Set editor full content',
    'ADVANCED / WHOLESALE ONLY — replaces the ENTIRE active editor buffer (a ' +
    '.pas) in one shot. This is NOT the normal way to write code, and it ' +
    'BYPASSES the inline red/green diff review — the user does not get to ' +
    'approve the change line-by-line, the source just appears all at once. ' +
    'For incremental code changes use EditUnit (old_text -> new_text), which ' +
    'shows the user an inline diff to approve/reject. To add an event handler ' +
    'use AddEventHandler (creates the method in the published section AND wires ' +
    'the event in one designer step). To add a control use AddComponent — it ' +
    'sprouts LIVE in the Designer and the IDE DECLARES ITS FIELD FOR YOU. NEVER ' +
    'hand-write a component field (e.g. "btn1: TButton;") in a form class: that ' +
    'is the Designer''s job, and a field with no live component desyncs .pas<->.dfm. ' +
    'Reserve SetEditorFullContent for a genuine full-file rewrite of RUNTIME LOGIC ' +
    'where an anchored EditUnit is impractical — never to introduce UI structure. ' +
    'RESULTING STATE: content is in the in-memory BUFFER, NOT on disk — call ' +
    'SaveActiveFile afterwards to persist. GUARDED: on a form unit the write is ' +
    'REFUSED (pas-dfm-desync) when the new source drops Designer-managed ' +
    'component fields still on the live form — keep every field the Designer ' +
    'declared (RemoveComponent deletes controls; EditUnit edits code; AddComponent ' +
    'creates new ones in the Designer).',
    _SetFullContentInputSchema,
    _BoolResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSetEditorFullContent(AParams, AContext);
    end,
    tiCode);
end;

function TMCPEditorToolsRegistrar._BuildFindInEditor: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'FindInEditor',
    'Find in editor',
    'Searches for text in the currently open file',
    _FindInEditorInputSchema,
    _OccurrencesResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleFindInEditor(AParams, AContext);
    end);
end;

function TMCPEditorToolsRegistrar._BuildReplaceInEditor: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'ReplaceInEditor',
    'Replace in editor',
    'Replaces text occurrences in the active editor buffer (find/replace, no ' +
    'disk write). This applies SILENTLY — it does NOT show the inline diff for ' +
    'the user to approve. For a reviewable code change on the unit currently ' +
    'OPEN in the editor, PREFER EditUnit (old_text -> new_text after a ReadUnit): ' +
    'it shows the red/green inline diff the user approves or rejects. Use ' +
    'ReplaceInEditor only for a bulk/mechanical replace where no review is wanted.',
    _ReplaceInEditorInputSchema,
    _IntegerResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleReplaceInEditor(AParams, AContext);
    end,
    tiCode);
end;

function TMCPEditorToolsRegistrar._BuildFindInProject: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'FindInProject',
    'Find in project',
    'Searches for text across all files in the project',
    _FindInEditorInputSchema,
    _FindInProjectResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleFindInProject(AParams, AContext);
    end);
end;

function TMCPEditorToolsRegistrar._BuildSaveActiveFile: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SaveActiveFile',
    'Save active file',
    'Persists the active buffer to disk (ForceSave — clears the modified indicator). ' +
    'Call after SetEditorFullContent or any buffer modification to ensure ' +
    'the file is saved. The "changed" field returns true if there was anything to save.',
    _EmptyInputSchema,
    _BoolResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSaveActiveFile(AParams, AContext);
    end);
end;

function TMCPEditorToolsRegistrar._BuildSaveAllFiles: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SaveAllFiles',
    'Save all files',
    'Persists all open buffers to disk (ForceSave on each module). ' +
    'Use at the end of an editing sequence to ensure everything is saved. ' +
    'Note: project files (.dproj) may not be captured — ' +
    'use SaveProjectGroup to save the project group.',
    _EmptyInputSchema,
    _BoolResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSaveAllFiles(AParams, AContext);
    end);
end;

function TMCPEditorToolsRegistrar._BuildUndoEditor: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'UndoEditor',
    'Undo editor',
    'Undoes the last action in the active editor',
    _EmptyInputSchema,
    _BoolResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleUndoEditor(AParams, AContext);
    end,
    tiCode);
end;

function TMCPEditorToolsRegistrar._BuildGetOpenEditorFiles: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetOpenEditorFiles',
    'Get open editor files',
    'Lists all files open in the editor (tabs)',
    _EmptyInputSchema,
    _OpenFilesResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetOpenEditorFiles(AParams, AContext);
    end);
end;

function TMCPEditorToolsRegistrar._BuildCloseFile: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'CloseFile',
    'Close file',
    'Closes a tab in the editor',
    _CloseFileInputSchema,
    _BoolResultSchema,
    function(const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleCloseFile(AParams, AContext);
    end);
end;

// -- Handlers --------------------------------------------------

function TMCPEditorToolsRegistrar._HandleGetEditorActiveFile(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LName, LPath: string;
  LFound: Boolean;
  LObj: TJSONObject;
begin
  LName := '';
  LPath := '';
  LFound := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LFound := FFacade.GetEditorActiveFile(LName, LPath);
    end);

  LObj := TJSONObject.Create;
  try
    if LFound then
    begin
      LObj.AddPair('name', LName);
      LObj.AddPair('path', LPath);
    end
    else
    begin
      LObj.AddPair('name', '');
      LObj.AddPair('path', '');
    end;
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleSetEditorCursorPosition(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LLine, LCol: Integer;
  LSuccess: Boolean;
  LObj: TJSONObject;
begin
  LLine := _ReadInteger(AParams, 'Line');
  LCol := _ReadInteger(AParams, 'Col');
  LSuccess := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LSuccess := FFacade.SetEditorCursorPosition(LLine, LCol);
    end);

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(LSuccess));
    LObj.AddPair('applied', TJSONBool.Create(LSuccess));
    LObj.AddPair('changed', TJSONBool.Create(False));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleInsertCodeAtCursor(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCode: string;
  LDecision: TMCPConsentDecision;
  LSuccess: Boolean;
  LObj: TJSONObject;
begin
  LCode := _ReadString(AParams, 'Code');
  LDecision := _RequestGate(AContext, 'InsertCodeAtCursor',
    'Insert code at cursor', 'Code length: ' + IntToStr(Length(LCode)) + ' chars.');

  if LDecision = cdDenied then
  begin
    _AuditDenied('InsertCodeAtCursor', 'Code: ' + LCode);
    raise EMCPUserDenied.Create('User denied insert code at cursor');
  end;

  LSuccess := False;
  try
    AContext.MarshalToMainThread(
      procedure
      begin
        LSuccess := FFacade.InsertCodeAtCursor(LCode);
      end);
    _AuditApplied('InsertCodeAtCursor', 'Code: ' + LCode, LDecision, LSuccess);
  except
    _AuditFailed('InsertCodeAtCursor', 'Code: ' + LCode, LDecision);
    raise;
  end;

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(LSuccess));
    LObj.AddPair('applied', TJSONBool.Create(LSuccess));
    LObj.AddPair('changed', TJSONBool.Create(LSuccess));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleReplaceEditorSelection(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LNewText: string;
  LSelection: TMCPSelectionInfo;
  LDecision: TMCPConsentDecision;
  LSuccess: Boolean;
  LObj: TJSONObject;
begin
  LNewText := _ReadString(AParams, 'NewText');

  // Verify that a selection actually exists
  LSelection := FFacade.GetSelection;
  if (not LSelection.Available) or (LSelection.Text = '') then
    _DenyWithStructuredDetail('ReplaceEditorSelection', 'selection', 'no-selection');

  LDecision := _RequestGate(AContext, 'ReplaceEditorSelection',
    'Replace active selection', 'Old: "' + LSelection.Text + '" -> New: "' + LNewText + '"');

  if LDecision = cdDenied then
  begin
    _AuditDenied('ReplaceEditorSelection', 'NewText: ' + LNewText);
    raise EMCPUserDenied.Create('User denied replace selection');
  end;

  LSuccess := False;
  try
    AContext.MarshalToMainThread(
      procedure
      begin
        LSuccess := FFacade.ReplaceEditorSelection(LNewText);
      end);
    _AuditApplied('ReplaceEditorSelection', 'NewText: ' + LNewText, LDecision, LSuccess);
  except
    _AuditFailed('ReplaceEditorSelection', 'NewText: ' + LNewText, LDecision);
    raise;
  end;

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(LSuccess));
    LObj.AddPair('applied', TJSONBool.Create(LSuccess));
    LObj.AddPair('changed', TJSONBool.Create(LSuccess));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleGetEditorFullContent(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LContent: string;
  LObj: TJSONObject;
begin
  LContent := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.GetEditorFullContent(LContent);
    end);

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', LContent);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleSetEditorFullContent(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LSource: string;
  LDecision: TMCPConsentDecision;
  LSuccess: Boolean;
  LObj: TJSONObject;
begin
  LSource := _ReadString(AParams, 'Source');
  LDecision := _RequestGate(AContext, 'SetEditorFullContent',
    'Set active editor full content', 'Replace entire buffer with ' + IntToStr(Length(LSource)) + ' chars.');

  if LDecision = cdDenied then
  begin
    _AuditDenied('SetEditorFullContent', 'Source len: ' + IntToStr(Length(LSource)));
    raise EMCPUserDenied.Create('User denied set full content');
  end;

  LSuccess := False;
  try
    AContext.MarshalToMainThread(
      procedure
      begin
        LSuccess := FFacade.SetEditorFullContent(LSource);
      end);
    _AuditApplied('SetEditorFullContent', 'Source len: ' + IntToStr(Length(LSource)), LDecision, LSuccess);
  except
    _AuditFailed('SetEditorFullContent', 'Source len: ' + IntToStr(Length(LSource)), LDecision);
    raise;
  end;

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(LSuccess));
    LObj.AddPair('applied', TJSONBool.Create(LSuccess));
    LObj.AddPair('changed', TJSONBool.Create(LSuccess));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleFindInEditor(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LText: string;
  LCase: Boolean;
  LOccs: TArray<TMCPCursorInfo>;
  LArr: TJSONArray;
  LItem: TJSONObject;
  LFor: Integer;
begin
  LText := _ReadString(AParams, 'Text');
  LCase := _ReadBoolean(AParams, 'CaseSensitive');
  SetLength(LOccs, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.FindInEditor(LText, LCase, LOccs);
    end);

  LArr := TJSONArray.Create;
  try
    for LFor := 0 to High(LOccs) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('line', TJSONNumber.Create(LOccs[LFor].Line));
      LItem.AddPair('col', TJSONNumber.Create(LOccs[LFor].Column));
      LArr.Add(LItem);
    end;
    Result := TMCPToolResult.Text(LArr.ToJSON);
  finally
    LArr.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleReplaceInEditor(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFind, LReplace: string;
  LAll: Boolean;
  LDecision: TMCPConsentDecision;
  LCount: Integer;
  LObj: TJSONObject;
begin
  LFind := _ReadString(AParams, 'Find');
  LReplace := _ReadString(AParams, 'Replace');
  LAll := _ReadBoolean(AParams, 'All');

  LDecision := _RequestGate(AContext, 'ReplaceInEditor',
    'Replace in editor', 'Find: "' + LFind + '" -> Replace: "' + LReplace + '" (All: ' + BoolToStr(LAll, True) + ')');

  if LDecision = cdDenied then
  begin
    _AuditDenied('ReplaceInEditor', 'Find: ' + LFind);
    raise EMCPUserDenied.Create('User denied replace in editor');
  end;

  LCount := 0;
  try
    AContext.MarshalToMainThread(
      procedure
      begin
        FFacade.ReplaceInEditor(LFind, LReplace, LAll, LCount);
      end);
    _AuditApplied('ReplaceInEditor', 'Find: ' + LFind, LDecision, LCount > 0);
  except
    _AuditFailed('ReplaceInEditor', 'Find: ' + LFind, LDecision);
    raise;
  end;

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONNumber.Create(LCount));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleFindInProject(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LText: string;
  LCase: Boolean;
  LOccs: TArray<TMCPCursorInfo>;
  LArr: TJSONArray;
  LItem: TJSONObject;
  LFor: Integer;
begin
  LText := _ReadString(AParams, 'Text');
  LCase := _ReadBoolean(AParams, 'CaseSensitive');
  SetLength(LOccs, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.FindInProject(LText, LCase, LOccs);
    end);

  LArr := TJSONArray.Create;
  try
    for LFor := 0 to High(LOccs) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('file', LOccs[LFor].UnitPath);
      LItem.AddPair('line', TJSONNumber.Create(LOccs[LFor].Line));
      LItem.AddPair('col', TJSONNumber.Create(LOccs[LFor].Column));
      LArr.Add(LItem);
    end;
    Result := TMCPToolResult.Text(LArr.ToJSON);
  finally
    LArr.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleSaveActiveFile(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDecision: TMCPConsentDecision;
  LChanged: Boolean;
  LSuccess: Boolean;
  LObj: TJSONObject;
  LFlow: IMCPFlowState;
  LGuardReason: string;
begin
  // Same FlowGuide save-guard (-32008) as SaveAllFiles: SaveActiveFile runs the SAME
  // global review-save-flush (auto-accepting EVERY pending ✓/✗ gutter across all units)
  // and does not check V2, so without this an agent blocked on SaveAllFiles could dodge
  // the guard by calling SaveActiveFile. Refuse BEFORE saving on the same global condition.
  LGuardReason := '';
  if Supports(FFacade, IMCPFlowState, LFlow) then
    AContext.MarshalToMainThread(
      procedure
      begin
        try
          LGuardReason := LFlow.SaveAllFilesGuardReason;
        except
          LGuardReason := '';
        end;
      end);
  if LGuardReason <> '' then
  begin
    _AuditDenied('SaveActiveFile', LGuardReason);
    raise EMCPSaveBlocked.Create(LGuardReason);
  end;

  LDecision := _RequestGate(AContext, 'SaveActiveFile',
    'Save active file', 'Save all pending changes in active buffer to disk.');

  if LDecision = cdDenied then
  begin
    _AuditDenied('SaveActiveFile', '');
    raise EMCPUserDenied.Create('User denied save active file');
  end;

  LChanged := False;
  LSuccess := False;
  try
    AContext.MarshalToMainThread(
      procedure
      begin
        LSuccess := FFacade.SaveActiveFile(LChanged);
      end);
    _AuditApplied('SaveActiveFile', '', LDecision, LChanged);
  except
    _AuditFailed('SaveActiveFile', '', LDecision);
    raise;
  end;

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(LSuccess));
    LObj.AddPair('applied', TJSONBool.Create(LSuccess));
    LObj.AddPair('changed', TJSONBool.Create(LChanged));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleSaveAllFiles(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDecision: TMCPConsentDecision;
  LChanged: Boolean;
  LSuccess: Boolean;
  LObj: TJSONObject;
  LFlow: IMCPFlowState;
  LGuardReason: string;
begin
  // FlowGuide SaveAllFiles guard (-32008): refuse BEFORE saving when firing the save now
  // would let the Delphi IDE — not the agent — do damage: clear unresolved ✓/✗ review
  // gutters (auto-accept) or strip a .dfm event whose handler is not in code yet. The
  // facade honours the "Agent auto-save edits" opt-in. Read on the main thread (OTA review
  // state); guard off when the facade does not expose IMCPFlowState (tests / no OTA host).
  LGuardReason := '';
  if Supports(FFacade, IMCPFlowState, LFlow) then
    AContext.MarshalToMainThread(
      procedure
      begin
        try
          LGuardReason := LFlow.SaveAllFilesGuardReason;
        except
          LGuardReason := '';
        end;
      end);
  if LGuardReason <> '' then
  begin
    _AuditDenied('SaveAllFiles', LGuardReason);
    raise EMCPSaveBlocked.Create(LGuardReason);
  end;

  LDecision := _RequestGate(AContext, 'SaveAllFiles',
    'Save all open files', 'Save all pending modifications across all editor tabs.');

  if LDecision = cdDenied then
  begin
    _AuditDenied('SaveAllFiles', '');
    raise EMCPUserDenied.Create('User denied save all files');
  end;

  LChanged := False;
  LSuccess := False;
  try
    AContext.MarshalToMainThread(
      procedure
      begin
        LSuccess := FFacade.SaveAllFiles(LChanged);
      end);
    _AuditApplied('SaveAllFiles', '', LDecision, LChanged);
  except
    _AuditFailed('SaveAllFiles', '', LDecision);
    raise;
  end;

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(LSuccess));
    LObj.AddPair('applied', TJSONBool.Create(LSuccess));
    LObj.AddPair('changed', TJSONBool.Create(LChanged));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleUndoEditor(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LDecision: TMCPConsentDecision;
  LSuccess: Boolean;
  LObj: TJSONObject;
begin
  LDecision := _RequestGate(AContext, 'UndoEditor',
    'Undo editor action', 'Revert the last modification in the active editor buffer.');

  if LDecision = cdDenied then
  begin
    _AuditDenied('UndoEditor', '');
    raise EMCPUserDenied.Create('User denied undo editor');
  end;

  LSuccess := False;
  try
    AContext.MarshalToMainThread(
      procedure
      begin
        LSuccess := FFacade.UndoEditor;
      end);
    _AuditApplied('UndoEditor', '', LDecision, LSuccess);
  except
    _AuditFailed('UndoEditor', '', LDecision);
    raise;
  end;

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(LSuccess));
    LObj.AddPair('applied', TJSONBool.Create(LSuccess));
    LObj.AddPair('changed', TJSONBool.Create(LSuccess));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleGetOpenEditorFiles(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LAFiles: TArray<TMCPRecordEditorFile>;
  LArr: TJSONArray;
  LItem: TJSONObject;
  LFor: Integer;
begin
  SetLength(LAFiles, 0);
  AContext.MarshalToMainThread(
    procedure
    begin
      FFacade.GetOpenEditorFiles(LAFiles);
    end);

  LArr := TJSONArray.Create;
  try
    for LFor := 0 to High(LAFiles) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('name', LAFiles[LFor].Name);
      LItem.AddPair('path', LAFiles[LFor].Path);
      LItem.AddPair('modified', TJSONBool.Create(LAFiles[LFor].Modified));
      LArr.Add(LItem);
    end;
    Result := TMCPToolResult.Text(LArr.ToJSON);
  finally
    LArr.Free;
  end;
end;

function TMCPEditorToolsRegistrar._HandleCloseFile(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFilePath: string;
  LSaveFirst: Boolean;
  LDecision: TMCPConsentDecision;
  LSuccess: Boolean;
  LObj: TJSONObject;
begin
  LFilePath := _ReadString(AParams, 'FilePath');
  LSaveFirst := _ReadBoolean(AParams, 'SaveFirst');

  // Consent is gated (Low risk)
  LDecision := _RequestGate(AContext, 'CloseFile',
    'Close editor tab', 'Close "' + LFilePath + '" (SaveFirst: ' + BoolToStr(LSaveFirst, True) + ')');

  if LDecision = cdDenied then
  begin
    _AuditDenied('CloseFile', 'FilePath: ' + LFilePath);
    raise EMCPUserDenied.Create('User denied close file');
  end;

  LSuccess := False;
  try
    AContext.MarshalToMainThread(
      procedure
      begin
        LSuccess := FFacade.CloseFile(LFilePath, LSaveFirst);
      end);
    _AuditApplied('CloseFile', 'FilePath: ' + LFilePath, LDecision, LSuccess);
  except
    _AuditFailed('CloseFile', 'FilePath: ' + LFilePath, LDecision);
    raise;
  end;

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(LSuccess));
    LObj.AddPair('applied', TJSONBool.Create(LSuccess));
    LObj.AddPair('changed', TJSONBool.Create(LSuccess));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function _SendKeystrokeInputSchema: TJSONObject;
var
  LProps, LKeys: TJSONObject;
  LRequired: TJSONArray;
begin
  Result   := TJSONObject.Create;
  LProps   := TJSONObject.Create;
  LKeys    := TJSONObject.Create;
  LRequired := TJSONArray.Create;
  LKeys.AddPair('type', 'string');
  LKeys.AddPair('description',
    'Keyboard shortcut to send, e.g. "Alt+F12", "Ctrl+S", "F9", "Shift+F10"');
  LProps.AddPair('Keys', LKeys);
  LRequired.Add('Keys');
  Result.AddPair('type', 'object');
  Result.AddPair('properties', LProps);
  Result.AddPair('required', LRequired);
end;

function TMCPEditorToolsRegistrar._BuildSendKeystroke: TMCPToolDescriptor;
var
  LDispatch: IMCPEditorToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'SendKeystroke',
    'Send keyboard shortcut',
    'Sends an auxiliary keyboard shortcut to the IDE (Ctrl+S, F9, F8, Shift+F9, etc.). ' +
    'Use it to trigger shortcuts that have no dedicated MCP tool. ' +
    'WARNING: to switch editor modes (Design<->Code, Design<->DFM text) use the ' +
    'dedicated OTA tools — OpenFormDesigner (goes to Design) and OpenUnitInEditor ' +
    '(goes to Code) — instead of F12/Alt+F12 via SendKeystroke, which depend on ' +
    'window focus and may not work when the IDE is in the background.',
    _SendKeystrokeInputSchema,
    _BoolResultSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleSendKeystroke(AParams, AContext);
    end);
end;

function TMCPEditorToolsRegistrar._HandleSendKeystroke(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LKeys: string;
  LSuccess: Boolean;
  LObj: TJSONObject;
begin
  LKeys    := _ReadString(AParams, 'Keys');
  LSuccess := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LSuccess := FFacade.SendKeystroke(LKeys);
    end);

  LObj := TJSONObject.Create;
  try
    LObj.AddPair('applied', TJSONBool.Create(LSuccess));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

end.
