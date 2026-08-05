unit Aefos.MCP.Tools;

(*
  OTA tools registered on the MCP server (ESP-002, Epic 3/5).

  Demand 1/5 — four read-only tools:
    - ReadUnit          ({unit_path: string, cursor?: string})
    - GetActiveProject  ({})
    - GetCursorPosition ({})
    - GetSelection      ({})

  Demand 2/5 — first write tool + read-before-edit concurrency guard:
    - EditUnit          ({unit_path, old_text, new_text, base_hash: string})
    - ReadUnit now records the full-body SHA-256 in the session edit
      tracker and returns it as content_hash (ADR-060).

  Threading (ADR-057):
    - The MCP dispatcher invokes the handler on the transport worker
      thread. Every OTA-touching call inside a handler runs through
      IMCPToolContext.MarshalToMainThread. Hashing stays on the worker
      thread.

  Registrar lifetime:
    - TMCPToolsRegistrar is reference-counted. The tool-handler closures
      capture a Self reference, so the registrar (and its edit tracker)
      lives as long as the server holds the tool descriptors. RegisterTools
      therefore must not free it explicitly — see RegisterTools.

  Mocking:
    - Tests inject an IMCPWorkspaceFacade. The real implementation lives next
      to Register.pas and depends on ToolsAPI / Adapter wrappers.
*)

interface

uses
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.EditTracker,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.BuildManager,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.Server;

type
  // Dispatch surface for the registered tools. Each tool-handler closure
  // captures an IMCPToolsRegistrar reference and dispatches through it, so
  // the registrar (and its session edit tracker) is reference-counted alive
  // for the server's lifetime and released only when the server frees its
  // tool descriptors (BR-7 / ADR-056).
  IMCPToolsRegistrar = interface
    ['{C5E7A1F4-9D82-4B36-AE10-7F2C6D914B83}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleReadUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetActiveProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetCursorPosition(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetSelection(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleEditUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleDeleteUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleOverwriteFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleAddUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRunBuild(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetBuildStatus(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleGetCompilerErrors(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

  TMCPToolsRegistrar = class(TInterfacedObject, IMCPToolsRegistrar)
  private
    FFacade: IMCPWorkspaceFacade;
    FEditTracker: IMCPEditTracker;
    FConsentRegistry: IMCPConsentRegistry;
    FAuditLog: IMCPAuditLog;
    FBuildManager: IMCPBuildManager;
    function _BuildReadUnitDescriptor: TMCPToolDescriptor;
    function _BuildGetActiveProjectDescriptor: TMCPToolDescriptor;
    function _BuildGetCursorPositionDescriptor: TMCPToolDescriptor;
    function _BuildGetSelectionDescriptor: TMCPToolDescriptor;
    function _BuildEditUnitDescriptor: TMCPToolDescriptor;
    function _BuildDeleteUnitDescriptor: TMCPToolDescriptor;
    function _BuildOverwriteFileDescriptor: TMCPToolDescriptor;
    function _BuildAddUnitDescriptor: TMCPToolDescriptor;
    function _BuildRunBuildDescriptor: TMCPToolDescriptor;
    function _BuildGetBuildStatusDescriptor: TMCPToolDescriptor;
    function _BuildGetCompilerErrorsDescriptor: TMCPToolDescriptor;
    function _HandleReadUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetActiveProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetCursorPosition(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetSelection(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleEditUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleDeleteUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleOverwriteFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleAddUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRunBuild(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetBuildStatus(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetCompilerErrors(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _BuildReadUnitChunk(const ABody: string;
      const ACursorBytes: Integer): TMCPToolResult;
    function _ReadCurrentBody(const AContext: IMCPToolContext;
      const AUnitPath: string): string;
    procedure _RaiseIfEditFailed(const AOutcome: TMCPEditOutcome;
      const AError: string);
    // Destructive-tool gating flow (ADR-064/065).
    function _RequestGate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    procedure _RaiseIfFileActionFailed(const AToolName, ANoun: string;
      const AOutcome: TMCPFileActionOutcome; const AError: string);
    // IMCPToolsRegistrar handler dispatch — mapped to the private _Handle*
    // implementations via method resolution so the _-prefixed convention
    // is preserved while the interface stays the closures' dispatch surface.
    function IMCPToolsRegistrar.HandleReadUnit = _HandleReadUnit;
    function IMCPToolsRegistrar.HandleGetActiveProject = _HandleGetActiveProject;
    function IMCPToolsRegistrar.HandleGetCursorPosition = _HandleGetCursorPosition;
    function IMCPToolsRegistrar.HandleGetSelection = _HandleGetSelection;
    function IMCPToolsRegistrar.HandleEditUnit = _HandleEditUnit;
    function IMCPToolsRegistrar.HandleDeleteUnit = _HandleDeleteUnit;
    function IMCPToolsRegistrar.HandleOverwriteFile = _HandleOverwriteFile;
    function IMCPToolsRegistrar.HandleAddUnit = _HandleAddUnit;
    function IMCPToolsRegistrar.HandleRunBuild = _HandleRunBuild;
    function IMCPToolsRegistrar.HandleGetBuildStatus = _HandleGetBuildStatus;
    function IMCPToolsRegistrar.HandleGetCompilerErrors = _HandleGetCompilerErrors;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsentRegistry: IMCPConsentRegistry = nil;
      const AAuditLog: IMCPAuditLog = nil;
      const ABuildManager: IMCPBuildManager = nil);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

procedure RegisterTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const ABuildManager: IMCPBuildManager); overload;
procedure RegisterTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;
procedure RegisterTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog; const ABuildManager: IMCPBuildManager); overload;

implementation

uses
  System.SysUtils,
  Aefos.MCP.Tools.Common;

function _MakeStringSchema(const ARequired: array of string;
  const ADescriptions: array of string): TJSONObject;
var
  LProps: TJSONObject;
  LRequired: TJSONArray;
  LIndex: Integer;
  LProp: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LIndex := 0;
  while LIndex < Length(ADescriptions) - 1 do
  begin
    LProp := TJSONObject.Create;
    LProp.AddPair('type', 'string');
    LProp.AddPair('description', ADescriptions[LIndex + 1]);
    LProps.AddPair(ADescriptions[LIndex], LProp);
    Inc(LIndex, 2);
  end;
  Result.AddPair('properties', LProps);
  if Length(ARequired) > 0 then
  begin
    LRequired := TJSONArray.Create;
    for LIndex := 0 to High(ARequired) do
      LRequired.Add(ARequired[LIndex]);
    Result.AddPair('required', LRequired);
  end;
end;

function _MakeEmptySchema: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

procedure _AddStringProp(const AProps: TJSONObject; const AName: string);
var
  LField: TJSONObject;
begin
  LField := TJSONObject.Create;
  LField.AddPair('type', 'string');
  AProps.AddPair(AName, LField);
end;

function _MakeReadUnitOutputSchema: TJSONObject;
var
  LProps: TJSONObject;
  LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  _AddStringProp(LProps, 'content');
  LField := TJSONObject.Create;
  LField.AddPair('type', 'boolean');
  LProps.AddPair('has_more', LField);
  _AddStringProp(LProps, 'next_cursor');
  _AddStringProp(LProps, 'content_hash');
  Result.AddPair('properties', LProps);
end;

function _MakeEditUnitOutputSchema: TJSONObject;
var
  LProps: TJSONObject;
  LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create;
  LField.AddPair('type', 'boolean');
  LProps.AddPair('applied', LField);
  _AddStringProp(LProps, 'content_hash');
  Result.AddPair('properties', LProps);
end;

// Output schema for the destructive tools — a single boolean `applied`.
function _MakeAppliedOutputSchema: TJSONObject;
var
  LProps: TJSONObject;
  LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create;
  LField.AddPair('type', 'boolean');
  LProps.AddPair('applied', LField);
  Result.AddPair('properties', LProps);
end;

// Maps a consent decision to the audit-log `consent` token (ADR-067).
// Maps a file-action outcome to the audit-log `outcome` token (ADR-067).
function _OutcomeToken(const AOutcome: TMCPFileActionOutcome): string;
begin
  case AOutcome of
    faApplied:         Result := 'faApplied';
    faNotFound:        Result := 'faNotFound';
    faAlreadyExists:   Result := 'faAlreadyExists';
    faNoActiveProject: Result := 'faNoActiveProject';
  else
    Result := 'faAccessError';
  end;
end;

// Maps a build state to the GetBuildStatus `status` token (ADR-070).
function _BuildStateToken(const AState: TMCPBuildState): string;
begin
  case AState of
    bsRunning:   Result := 'running';
    bsSucceeded: Result := 'succeeded';
    bsFailed:    Result := 'failed';
  else
    Result := 'cancelled';
  end;
end;

// Maps a compiler severity to the GetCompilerErrors `severity` token.
function _SeverityToken(const ASeverity: TMCPCompilerSeverity): string;
begin
  case ASeverity of
    csError:   Result := 'error';
    csWarning: Result := 'warning';
  else
    Result := 'hint';
  end;
end;

// Extracts a required string parameter; raises -32602 when absent or
// non-string. The dispatcher's schema check already enforces this; the
// handler re-checks defensively (BR-9).
function _ParamStr(const AParams: TJSONObject; const AName: string): string;
var
  LValue: TJSONValue;
begin
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create('arguments required');
  LValue := AParams.GetValue(AName);
  if not (Assigned(LValue) and (LValue is TJSONString)) then
    raise EMCPInvalidParams.Create(AName + ' required (string)');
  Result := TJSONString(LValue).Value;
end;

{ TMCPToolsRegistrar }

constructor TMCPToolsRegistrar.Create(const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog;
  const ABuildManager: IMCPBuildManager);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TMCPToolsRegistrar: AFacade');
  FFacade := AFacade;
  // Session-scoped collaborators (ADR-056/060/064/067): one per registrar,
  // alive for the server's lifetime via the handler-closure Self reference.
  FEditTracker := TMCPEditTracker.Create;
  if Assigned(AConsentRegistry) then
    FConsentRegistry := AConsentRegistry
  else
    FConsentRegistry := TMCPConsentRegistry.Create;
  if Assigned(AAuditLog) then
    FAuditLog := AAuditLog
  else
    FAuditLog := TMCPAuditLog.Create;
  // The build manager is shared with the server's cancel sink when the
  // composition root injects one; a standalone use gets a fresh manager.
  if Assigned(ABuildManager) then
    FBuildManager := ABuildManager
  else
    FBuildManager := TMCPBuildManager.Create;
end;

procedure TMCPToolsRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create('TMCPToolsRegistrar.RegisterAll: AServer');
  AServer.RegisterTool(_BuildReadUnitDescriptor);
  AServer.RegisterTool(_BuildGetActiveProjectDescriptor);
  AServer.RegisterTool(_BuildGetCursorPositionDescriptor);
  AServer.RegisterTool(_BuildGetSelectionDescriptor);
  AServer.RegisterTool(_BuildEditUnitDescriptor);
  AServer.RegisterTool(_BuildDeleteUnitDescriptor);
  AServer.RegisterTool(_BuildOverwriteFileDescriptor);
  AServer.RegisterTool(_BuildAddUnitDescriptor);
  AServer.RegisterTool(_BuildRunBuildDescriptor);
  AServer.RegisterTool(_BuildGetBuildStatusDescriptor);
  AServer.RegisterTool(_BuildGetCompilerErrorsDescriptor);
end;

function TMCPToolsRegistrar._BuildReadUnitDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'ReadUnit',
    'Read unit body',
    'Reads the source of a Delphi unit. Returns up to 64 KB per call; ' +
    'if has_more is true, re-call with the same unit_path and ' +
    'cursor=next_cursor to fetch the next chunk. content_hash is the ' +
    'SHA-256 of the full body — pass it as base_hash to EditUnit.',
    _MakeStringSchema(
      ['unit_path'],
      ['unit_path', 'Absolute or relative path of the unit to read.',
       'cursor',    'Opaque continuation token returned by a previous call.']),
    _MakeReadUnitOutputSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleReadUnit(AParams, AContext);
    end);
end;

function TMCPToolsRegistrar._BuildGetActiveProjectDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetActiveProject',
    'Get active project',
    'Returns project_name, project_path, target_platform of the IDE''s ' +
    'currently active project. Errors with -32000 when no project is open.',
    _MakeEmptySchema,
    _MakeEmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetActiveProject(AParams, AContext);
    end);
end;

function TMCPToolsRegistrar._BuildGetCursorPositionDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetCursorPosition',
    'Get cursor position',
    'Returns {unit_path, line, column} of the active source editor''s ' +
    'caret. Returns JSON null when no source editor has focus.',
    _MakeEmptySchema,
    _MakeEmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetCursorPosition(AParams, AContext);
    end);
end;

function TMCPToolsRegistrar._BuildGetSelectionDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetSelection',
    'Get current selection',
    'Returns the selection envelope (unit_path, selection_text, start_line, ' +
    'start_column, end_line, end_column) or JSON null when no selection.',
    _MakeEmptySchema,
    _MakeEmptySchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetSelection(AParams, AContext);
    end);
end;

function TMCPToolsRegistrar._BuildEditUnitDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'EditUnit',
    'Edit unit body',
    'Applies a single anchored replacement to a Delphi unit''s IDE editor ' +
    'buffer: old_text must occur exactly once and is replaced by new_text. ' +
    'base_hash must be the content_hash returned by a prior ReadUnit (or a ' +
    'prior EditUnit) for this unit. The edit is rejected if the unit was ' +
    'not read this session (-32002) or has changed since (-32001); re-read ' +
    'and retry. The buffer is left dirty and undoable; the file is not ' +
    'saved. The returned content_hash chains directly into a follow-up edit. ' +
    'PREFERRED for code changes: when the edited unit is the one OPEN in the ' +
    'editor, the change is shown to the user as an inline red/green diff ' +
    '(removed lines red, added lines green) that they approve or reject before ' +
    'it lands — so use anchored EditUnit calls rather than SetEditorFullContent ' +
    '(which dumps the whole buffer at once and shows no diff).',
    _MakeStringSchema(
      ['unit_path', 'old_text', 'new_text', 'base_hash'],
      ['unit_path', 'Path of the open unit to edit.',
       'old_text',  'Exact text to replace; must occur exactly once.',
       'new_text',  'Replacement text.',
       'base_hash', 'content_hash from the last ReadUnit/EditUnit of this unit.']),
    _MakeEditUnitOutputSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleEditUnit(AParams, AContext);
    end,
    tiCode);
end;

function TMCPToolsRegistrar._BuildDeleteUnitDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'DeleteUnit',
    'Delete unit',
    'Removes a Delphi unit from the active project and deletes the file ' +
    'from disk. This is irreversible — there is no IDE undo for a deleted ' +
    'file. The first call this session shows a confirmation modal; the ' +
    'call blocks until the user decides and returns -32003 if denied.',
    _MakeStringSchema(
      ['unit_path'],
      ['unit_path', 'Absolute path of the unit to delete.']),
    _MakeAppliedOutputSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleDeleteUnit(AParams, AContext);
    end);
end;

function TMCPToolsRegistrar._BuildOverwriteFileDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'OverwriteFile',
    'Overwrite file',
    'Replaces the full content of an existing file. When the file is open ' +
    'in an editor the change is undoable; when closed it is written to ' +
    'disk directly. Use AddUnit to create a new file. The first call this ' +
    'session shows a confirmation modal and returns -32003 if denied.',
    _MakeStringSchema(
      ['file_path', 'content'],
      ['file_path', 'Absolute path of the existing file to overwrite.',
       'content',   'New full content of the file.']),
    _MakeAppliedOutputSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleOverwriteFile(AParams, AContext);
    end);
end;

function TMCPToolsRegistrar._BuildAddUnitDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'AddUnit',
    'Add unit',
    'Creates a new unit file with the given content and adds it to the ' +
    'active project. Fails if the file already exists — use OverwriteFile ' +
    'to replace. The first call this session shows a confirmation modal ' +
    'and returns -32003 if denied.',
    _MakeStringSchema(
      ['unit_path', 'content'],
      ['unit_path', 'Absolute path of the new unit file to create.',
       'content',   'Full content of the new unit.']),
    _MakeAppliedOutputSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleAddUnit(AParams, AContext);
    end);
end;

function TMCPToolsRegistrar._BuildRunBuildDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'RunBuild',
    'Run build',
    'Starts an asynchronous build of the IDE''s active project and returns ' +
    'immediately with an opaque build_id. mode is optional: "make" ' +
    '(default, incremental) or "build" (full rebuild). Poll GetBuildStatus ' +
    'with the returned build_id for the result, and pass that build_id as ' +
    'the requestId of a notifications/cancelled to cancel the build. A ' +
    'second RunBuild while a build is still running fails with -32004.',
    _MakeStringSchema(
      [],
      ['mode', 'Optional build mode: "make" (default) or "build".']),
    nil,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRunBuild(AParams, AContext);
    end);
end;

function TMCPToolsRegistrar._BuildGetBuildStatusDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetBuildStatus',
    'Get build status',
    'Polls the state of a build started by RunBuild. Returns {build_id, ' +
    'status} where status is "running", "succeeded", "failed" or ' +
    '"cancelled". An unknown or expired build_id errors with -32000.',
    _MakeStringSchema(
      ['build_id'],
      ['build_id', 'The build_id returned by a prior RunBuild call.']),
    nil,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetBuildStatus(AParams, AContext);
    end);
end;

function TMCPToolsRegistrar._BuildGetCompilerErrorsDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPToolsRegistrar;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'GetCompilerErrors',
    'Get compiler errors',
    'Returns the compiler diagnostics as a JSON array; each element is ' +
    '{path, line, column, severity, text} with severity "error", "warning" ' +
    'or "hint". Two sources: after a RunBuild it returns that build''s full ' +
    'diagnostics (whole project, incl. link/cross-unit errors); if no build ' +
    'has run this session it falls back to the IDE Structure pane''s live ' +
    'Error Insight for the ACTIVE unit (instant, no build, active-file only). ' +
    'Reading never triggers a build. Empty array when there are none.',
    _MakeEmptySchema,
    nil,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleGetCompilerErrors(AParams, AContext);
    end);
end;

function TMCPToolsRegistrar._BuildReadUnitChunk(const ABody: string;
  const ACursorBytes: Integer): TMCPToolResult;
var
  LBytes: TBytes;
  LTotal: Integer;
  LRemaining: Integer;
  LChunkBytes: TBytes;
  LChunkLen: Integer;
begin
  // Paging primitive: this is the one Result that sets HasMore/NextCursor
  // (conditionally, across two exit paths), so it stays a hand-built Default
  // rather than a TMCPToolResult.Text factory (which is for the non-paging case).
  Result := Default(TMCPToolResult);
  LBytes := TEncoding.UTF8.GetBytes(ABody);
  LTotal := Length(LBytes);
  if (ACursorBytes < 0) or (ACursorBytes > LTotal) then
    raise EMCPInvalidParams.Create('cursor out of range');
  LRemaining := LTotal - ACursorBytes;
  if LRemaining <= MCP_TOOL_RESULT_BUDGET then
  begin
    SetLength(LChunkBytes, LRemaining);
    if LRemaining > 0 then
      Move(LBytes[ACursorBytes], LChunkBytes[0], LRemaining);
    Result.Content := TEncoding.UTF8.GetString(LChunkBytes);
    Result.HasMore := False;
    Result.NextCursor := '';
    Exit;
  end;
  // R1: cut the chunk on a UTF-8 boundary so GetString never raises on a split multibyte char;
  // NextCursor advances by the SAME safe length, so the next chunk resumes exactly at the boundary
  // (no bytes lost, no split at the seam).
  LChunkLen := TMCPUtf8Utils.SafeLen(LBytes, ACursorBytes, MCP_TOOL_RESULT_BUDGET);
  SetLength(LChunkBytes, LChunkLen);
  if LChunkLen > 0 then
    Move(LBytes[ACursorBytes], LChunkBytes[0], LChunkLen);
  Result.Content := TEncoding.UTF8.GetString(LChunkBytes);
  Result.HasMore := True;
  Result.NextCursor := IntToStr(ACursorBytes + LChunkLen);
end;

function TMCPToolsRegistrar._HandleReadUnit(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitPath: string;
  LCursor: string;
  LCursorBytes: Integer;
  LBody: string;
  LFacadeOk: Boolean;
  LCursorValue: TJSONValue;
  LUnitPathValue: TJSONValue;
begin
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create('ReadUnit: arguments required');
  LUnitPath := '';
  LUnitPathValue := AParams.GetValue('unit_path');
  if Assigned(LUnitPathValue) and (LUnitPathValue is TJSONString) then
    LUnitPath := TJSONString(LUnitPathValue).Value;
  if LUnitPath = '' then
    raise EMCPInvalidParams.Create('ReadUnit: unit_path required');
  LCursor := '';
  LCursorValue := AParams.GetValue('cursor');
  if Assigned(LCursorValue) and (LCursorValue is TJSONString) then
    LCursor := TJSONString(LCursorValue).Value;
  LCursorBytes := 0;
  if LCursor <> '' then
    if not TryStrToInt(LCursor, LCursorBytes) then
      raise EMCPInvalidParams.Create('ReadUnit: cursor must be an integer string');
  LBody := '';
  LFacadeOk := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LFacadeOk := FFacade.ReadUnit(LUnitPath, LBody);
    end);
  if not LFacadeOk then
    raise EMCPError.Create(MCP_ERR_SERVER, 'ReadUnit: unit not found: ' + LUnitPath);
  // Record the full-body hash so EditUnit can verify it later (ADR-060).
  FEditTracker.&Record(LUnitPath, LBody);
  Result := _BuildReadUnitChunk(LBody, LCursorBytes);
  // content_hash is the full-body hash — stable across every chunk (BR-3).
  Result.ContentHash := TMCPEditTracker.HashContent(LBody);
end;

function TMCPToolsRegistrar._HandleGetActiveProject(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LInfo: TMCPActiveProjectInfo;
  LObj: TJSONObject;
begin
  AContext.MarshalToMainThread(
    procedure
    begin
      LInfo := FFacade.GetActiveProject;
    end);
  if not LInfo.Available then
    raise EMCPError.Create(MCP_ERR_SERVER, 'no active project');
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('project_name', LInfo.Name);
    LObj.AddPair('project_path', LInfo.Path);
    LObj.AddPair('target_platform', LInfo.TargetPlatform);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPToolsRegistrar._HandleGetCursorPosition(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LInfo: TMCPCursorInfo;
  LObj: TJSONObject;
begin
  AContext.MarshalToMainThread(
    procedure
    begin
      LInfo := FFacade.GetCursorPosition;
    end);
  if not LInfo.Available then
  begin
    Result := TMCPToolResult.Text('null');
    Exit;
  end;
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('unit_path', LInfo.UnitPath);
    LObj.AddPair('line', TJSONNumber.Create(LInfo.Line));
    LObj.AddPair('column', TJSONNumber.Create(LInfo.Column));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPToolsRegistrar._HandleGetSelection(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LInfo: TMCPSelectionInfo;
  LObj: TJSONObject;
begin
  AContext.MarshalToMainThread(
    procedure
    begin
      LInfo := FFacade.GetSelection;
    end);
  if not LInfo.Available then
  begin
    Result := TMCPToolResult.Text('null');
    Exit;
  end;
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('unit_path', LInfo.UnitPath);
    LObj.AddPair('selection_text', LInfo.Text);
    LObj.AddPair('start_line', TJSONNumber.Create(LInfo.StartLine));
    LObj.AddPair('start_column', TJSONNumber.Create(LInfo.StartColumn));
    LObj.AddPair('end_line', TJSONNumber.Create(LInfo.EndLine));
    LObj.AddPair('end_column', TJSONNumber.Create(LInfo.EndColumn));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

// Re-reads the live unit body on the main thread; raises -32000 when the
// unit cannot be read (not open in the editor).
function TMCPToolsRegistrar._ReadCurrentBody(const AContext: IMCPToolContext;
  const AUnitPath: string): string;
var
  LBody: string;
  LOk: Boolean;
begin
  LBody := '';
  LOk := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LOk := FFacade.ReadUnit(AUnitPath, LBody);
    end);
  if not LOk then
    raise EMCPError.Create(MCP_ERR_SERVER, 'EditUnit: unit not open: ' + AUnitPath);
  Result := LBody;
end;

procedure TMCPToolsRegistrar._RaiseIfEditFailed(const AOutcome: TMCPEditOutcome;
  const AError: string);
begin
  // eoApplied is the success path and raises nothing.
  if AOutcome = eoApplied then
    Exit;
  case AOutcome of
    eoUnitNotOpen:
      raise EMCPError.Create(MCP_ERR_SERVER, 'EditUnit: unit not open');
    eoAnchorNotFound:
      raise EMCPError.Create(MCP_ERR_SERVER, 'EditUnit: anchor not found');
    eoAnchorAmbiguous:
      raise EMCPError.Create(MCP_ERR_SERVER,
        'EditUnit: anchor ambiguous — provide a longer old_text');
  else
    raise EMCPError.Create(MCP_ERR_SERVER, 'EditUnit: ' + AError);
  end;
end;

function TMCPToolsRegistrar._HandleEditUnit(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitPath, LOldText, LNewText, LBaseHash: string;
  LBody, LCurrentHash, LNewBody, LError: string;
  LOutcome: TMCPEditOutcome;
begin
  LUnitPath := _ParamStr(AParams, 'unit_path');
  LOldText := _ParamStr(AParams, 'old_text');
  LNewText := _ParamStr(AParams, 'new_text');
  LBaseHash := _ParamStr(AParams, 'base_hash');
  // Re-read the live content and hash it on the worker thread (ADR-057).
  LBody := _ReadCurrentBody(AContext, LUnitPath);
  LCurrentHash := TMCPEditTracker.HashContent(LBody);
  if not FEditTracker.WasRead(LUnitPath) then
    raise EMCPNotRead.Create(
      'EditUnit: unit not read this session — call ReadUnit first: ' + LUnitPath);
  if LBaseHash <> LCurrentHash then
    raise EMCPStaleRead.Create(
      'EditUnit: base_hash is stale — re-read the unit: ' + LUnitPath);
  LOutcome := eoApplied;
  LError := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LOutcome := FFacade.EditUnit(LUnitPath, LOldText, LNewText, LError);
    end);
  _RaiseIfEditFailed(LOutcome, LError);
  // Re-read the post-edit body for an authoritative content_hash (BR-6).
  LNewBody := _ReadCurrentBody(AContext, LUnitPath);
  FEditTracker.&Record(LUnitPath, LNewBody);
  Result := TMCPToolResult.Text('{"applied":true}',
    TMCPEditTracker.HashContent(LNewBody));
end;

// Runs the destructive-action gate (ADR-064). A live session grant returns
// cdAllowSession with no modal; otherwise RequestConsent is marshalled to
// the IDE main thread and an "allow for this session" answer is recorded.
function TMCPToolsRegistrar._RequestGate(const AContext: IMCPToolContext;
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

// Maps a non-applied TMCPFileActionOutcome to a -32000 server error with a
// tool-specific message (ADR-066). faApplied raises nothing.
procedure TMCPToolsRegistrar._RaiseIfFileActionFailed(
  const AToolName, ANoun: string; const AOutcome: TMCPFileActionOutcome;
  const AError: string);
begin
  if AOutcome = faApplied then
    Exit;
  case AOutcome of
    faNotFound:
      raise EMCPError.Create(MCP_ERR_SERVER,
        AToolName + ': ' + ANoun + ' not found');
    faAlreadyExists:
      raise EMCPError.Create(MCP_ERR_SERVER,
        AToolName + ': unit already exists');
    faNoActiveProject:
      raise EMCPError.Create(MCP_ERR_SERVER,
        AToolName + ': no active project');
  else
    raise EMCPError.Create(MCP_ERR_SERVER, AToolName + ': ' + AError);
  end;
end;

function TMCPToolsRegistrar._HandleDeleteUnit(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitPath, LError: string;
  LDecision: TMCPConsentDecision;
  LOutcome: TMCPFileActionOutcome;
begin
  LUnitPath := _ParamStr(AParams, 'unit_path');
  LDecision := _RequestGate(AContext, 'DeleteUnit',
    'Delete this unit and remove it from the active project:', LUnitPath);
  if LDecision = cdDenied then
  begin
    FAuditLog.Append('DeleteUnit', LUnitPath, 'denied', 'denied');
    raise EMCPUserDenied.Create('DeleteUnit: user denied the action');
  end;
  LOutcome := faAccessError;
  LError := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LOutcome := FFacade.DeleteUnit(LUnitPath, LError);
    end);
  FAuditLog.Append('DeleteUnit', LUnitPath, TMCPConsentToken.Token(LDecision),
    _OutcomeToken(LOutcome));
  _RaiseIfFileActionFailed('DeleteUnit', 'unit', LOutcome, LError);
  Result := TMCPToolResult.Text('{"applied":true}');
end;

function TMCPToolsRegistrar._HandleOverwriteFile(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFilePath, LContent, LError, LExt: string;
  LDecision: TMCPConsentDecision;
  LOutcome: TMCPFileActionOutcome;
begin
  LFilePath := _ParamStr(AParams, 'file_path');
  LContent := _ParamStr(AParams, 'content');
  // GUARD (intent->view policy): OverwriteFile is a raw disk write that flips the
  // view to Code and bypasses the Form Designer. Refuse the two shapes that were
  // hijacking the Design->Code flow into a file-first dead end (the agent was
  // following the old SetDFMContent "OverwriteFile .pas first" contract):
  //  - a .dfm  => forms are designer-owned; use AddComponent/SetDFMContent.
  //  - a .pas that does NOT exist yet (a phantom new unit) => designer tools
  //    would then fail form-not-found; use AddUnit for a new unit, or
  //    AddComponent/AddEventHandler to grow the OPEN form live in Design.
  // An EXISTING .pas still overwrites freely — ReplaceInProject/FixEncoding call
  // the facade directly (not this handler), and plain full-file edits on a file
  // that already exists are legitimate.
  LExt := LowerCase(ExtractFileExt(LFilePath));
  if LExt = '.dfm' then
    raise EMCPInvalidParams.Create(
      'OverwriteFile refused for a .dfm: a form is owned by the Form Designer. ' +
      'Add controls with AddComponent (they appear live in the Designer), set ' +
      'properties with SetComponentProperty/SetFormProperty, and wire events ' +
      'with AddEventHandler. Use SetDFMContent only for a deliberate bulk ' +
      '.dfm replace on an existing form.');
  if (LExt = '.pas') and not FileExists(LFilePath) then
    raise EMCPInvalidParams.Create(
      'OverwriteFile refused for a .pas that does not exist yet (a phantom unit ' +
      'the IDE never opened — every designer tool would then fail ' +
      'form-not-found). To create a NEW unit use AddUnit. To build UI on the ' +
      'form already OPEN in the Designer, use AddComponent + AddEventHandler so ' +
      'it grows live in Design mode.');
  LDecision := _RequestGate(AContext, 'OverwriteFile',
    'Replace the full content of this file:' + sLineBreak + LFilePath,
    LContent);
  if LDecision = cdDenied then
  begin
    FAuditLog.Append('OverwriteFile', LFilePath, 'denied', 'denied');
    raise EMCPUserDenied.Create('OverwriteFile: user denied the action');
  end;
  LOutcome := faAccessError;
  LError := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LOutcome := FFacade.OverwriteFile(LFilePath, LContent, LError);
    end);
  FAuditLog.Append('OverwriteFile', LFilePath, TMCPConsentToken.Token(LDecision),
    _OutcomeToken(LOutcome));
  _RaiseIfFileActionFailed('OverwriteFile', 'file', LOutcome, LError);
  Result := TMCPToolResult.Text('{"applied":true}');
end;

function TMCPToolsRegistrar._HandleAddUnit(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitPath, LContent, LError: string;
  LDecision: TMCPConsentDecision;
  LOutcome: TMCPFileActionOutcome;
begin
  LUnitPath := _ParamStr(AParams, 'unit_path');
  LContent := _ParamStr(AParams, 'content');
  LDecision := _RequestGate(AContext, 'AddUnit',
    'Create this unit and add it to the active project:' + sLineBreak +
    LUnitPath, LContent);
  if LDecision = cdDenied then
  begin
    FAuditLog.Append('AddUnit', LUnitPath, 'denied', 'denied');
    raise EMCPUserDenied.Create('AddUnit: user denied the action');
  end;
  LOutcome := faAccessError;
  LError := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LOutcome := FFacade.AddUnit(LUnitPath, LContent, LError);
    end);
  FAuditLog.Append('AddUnit', LUnitPath, TMCPConsentToken.Token(LDecision),
    _OutcomeToken(LOutcome));
  _RaiseIfFileActionFailed('AddUnit', 'unit', LOutcome, LError);
  Result := TMCPToolResult.Text('{"applied":true}');
end;

// Reads the optional `mode` parameter of RunBuild, defaulting to "make".
// A non-string mode or any value other than "make"/"build" → -32602.
function _ReadBuildMode(const AParams: TJSONObject): string;
var
  LModeValue: TJSONValue;
begin
  Result := 'make';
  if not Assigned(AParams) then
    Exit;
  LModeValue := AParams.GetValue('mode');
  if not Assigned(LModeValue) then
    Exit;
  if not (LModeValue is TJSONString) then
    raise EMCPInvalidParams.Create('RunBuild: mode must be a string');
  Result := TJSONString(LModeValue).Value;
  if (Result <> 'make') and (Result <> 'build') then
    raise EMCPInvalidParams.Create(
      'RunBuild: mode must be "make" or "build"');
end;

function TMCPToolsRegistrar._HandleRunBuild(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LMode, LError, LBuildId: string;
  LStarted: Boolean;
  LObj: TJSONObject;
begin
  LMode := _ReadBuildMode(AParams);
  // Single-active-build model (BR-2): a second RunBuild is rejected outright.
  if FBuildManager.HasActiveBuild then
    raise EMCPBuildInProgress.Create('RunBuild: a build is already in progress');
  LStarted := False;
  LError := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LStarted := FFacade.StartBuild(LMode, LError);
    end);
  if not LStarted then
  begin
    if LError = '' then
      LError := 'no active project';
    raise EMCPError.Create(MCP_ERR_SERVER, 'RunBuild: ' + LError);
  end;
  // Register the job only after the build actually started (BR-4).
  LBuildId := FBuildManager.NewBuildId;
  FBuildManager.Register(LBuildId);
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('build_id', LBuildId);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPToolsRegistrar._HandleGetBuildStatus(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LBuildId: string;
  LState, LQueried: TMCPBuildState;
  LObj: TJSONObject;
begin
  LBuildId := _ParamStr(AParams, 'build_id');
  if not FBuildManager.GetState(LBuildId, LState) then
    raise EMCPError.Create(MCP_ERR_SERVER,
      'GetBuildStatus: unknown build_id: ' + LBuildId);
  if (LState = bsRunning) and FBuildManager.IsCancelled(LBuildId) then
  begin
    // RN-C02 (BR-7): act on the flipped token once, then latch bsCancelled.
    AContext.MarshalToMainThread(
      procedure
      begin
        FFacade.CancelBuild;
      end);
    FBuildManager.SetState(LBuildId, bsCancelled);
    LState := bsCancelled;
  end
  else if LState = bsRunning then
  begin
    LQueried := bsRunning;
    AContext.MarshalToMainThread(
      procedure
      begin
        LQueried := FFacade.QueryBuildResult;
      end);
    if LQueried <> bsRunning then
    begin
      FBuildManager.SetState(LBuildId, LQueried);
      LState := LQueried;
    end;
  end;
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('build_id', LBuildId);
    LObj.AddPair('status', _BuildStateToken(LState));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPToolsRegistrar._HandleGetCompilerErrors(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LMessages: TArray<TMCPCompilerMessage>;
  LArray: TJSONArray;
  LObj: TJSONObject;
  LIndex: Integer;
begin
  AContext.MarshalToMainThread(
    procedure
    begin
      LMessages := FFacade.GetCompilerMessages;
    end);
  LArray := TJSONArray.Create;
  try
    for LIndex := 0 to High(LMessages) do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('path', LMessages[LIndex].Path);
      LObj.AddPair('line', TJSONNumber.Create(LMessages[LIndex].Line));
      LObj.AddPair('column', TJSONNumber.Create(LMessages[LIndex].Column));
      LObj.AddPair('severity', _SeverityToken(LMessages[LIndex].Severity));
      LObj.AddPair('text', LMessages[LIndex].Text);
      LArray.AddElement(LObj);
    end;
    Result := TMCPToolResult.Text(LArray.ToJSON);
  finally
    LArray.Free;
  end;
end;

procedure RegisterTools(const AServer: IMCPServer; const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: IMCPToolsRegistrar;
begin
  // The registrar is reference-counted through IMCPToolsRegistrar: each
  // tool-handler closure captures a registrar reference and dispatches
  // through it, so the registrar (and its edit tracker) stays alive for the
  // server's lifetime and is released only when the server frees its tool
  // descriptors. Holding it as an interface here also guarantees it is
  // freed if RegisterAll raises before any closure is built (BR-7 /
  // ADR-056). Do NOT free the registrar explicitly.
  LRegistrar := TMCPToolsRegistrar.Create(AFacade);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const ABuildManager: IMCPBuildManager);
var
  LRegistrar: IMCPToolsRegistrar;
begin
  // Overload that injects a caller-owned build manager (Demand 4/5) so the
  // composition root can share one TMCPBuildManager between the registrar's
  // build tools and the server's IMCPCancellationSink. Same lifetime
  // contract as the other overloads.
  LRegistrar := TMCPToolsRegistrar.Create(AFacade, nil, nil, ABuildManager);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPToolsRegistrar;
begin
  // Overload that injects a caller-owned consent registry and audit log —
  // used to share a session-scoped registry with tests and to point the
  // audit log at a non-default path. Same lifetime contract as above.
  LRegistrar := TMCPToolsRegistrar.Create(AFacade, AConsentRegistry, AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog; const ABuildManager: IMCPBuildManager);
var
  LRegistrar: IMCPToolsRegistrar;
begin
  // Composition-root overload (ADR-263): shares one session-stamped audit log
  // AND the server's cancel-sink build manager across the shipped tools, so a
  // single minted session id reaches every destructive registrar with no
  // per-registrar fallback (AC-06). Same lifetime contract as above.
  LRegistrar := TMCPToolsRegistrar.Create(AFacade, AConsentRegistry, AAuditLog,
    ABuildManager);
  LRegistrar.RegisterAll(AServer);
end;

end.
