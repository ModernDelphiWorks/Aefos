unit Aefos.MCP.Tools.ProjectText;

{
  Project-wide source-text registrar — wraps the rtl-pure Aefos.Tools
  engine (Text / Files / Batch) as MCP tools for capabilities the OTA surface
  genuinely lacks (2026-06-10):

    * ReplaceInProject — literal find/replace across every file under a root
      matching a glob. The OTA FindInProject is read-only; this is its write
      counterpart. NOT a duplicate of EditUnit (single-file, anchored) or
      OverwriteFile (single-file, full content).
    * FixEncoding — add/convert the byte-order mark (e.g. a UTF-8 BOM) across a
      glob. The OTA surface has no encoding tool at all; this fixes the
      recurring ANSI/mojibake compilation trap on .pas files lacking a BOM.

  Contract — the whole point of the pure suite: the engine COMPUTES (load +
  transform, no IDE coupling) and the FACADE APPLIES. ReplaceInProject writes
  every changed file through IMCPWorkspaceFacade.OverwriteFile, which routes an
  open unit to its undoable editor buffer and a closed file to disk — a
  project-wide replace therefore never desyncs an open buffer. FixEncoding
  rewrites the BOM on disk directly (OverwriteFile controls its own encoding and
  cannot set a BOM), so it SKIPS any file currently open in the editor and
  reports it — the agent fixes those through the editor rather than corrupting a
  live buffer.

  Consent + audit: both tools mutate the filesystem/project and are gated once
  per call through the facade's consent modal (ADR-064/065) and audited
  (ADR-067), mirroring the other destructive tools. FConsent may be nil (the
  Chat host relies on the facade's HTML consent modal) and is never
  dereferenced when absent. FAudit is optional likewise.

  Lifetime (ADR-056): the registrar is reference-counted; its handler closures
  hold an IProjectTextDispatch reference, so it lives as long as the server
  holds the descriptors.

  Boundary: requires Aefos.Tools (rtl-pure) + MCP.Core. No ToolsAPI.
}

interface

uses
  Aefos.MCP.Server,
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog;

// Registers ReplaceInProject + FixEncoding on AServer. AConsent/AAudit may be
// nil (the Chat host passes nil for consent and relies on the facade modal).
procedure RegisterProjectTextTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog);

implementation

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  Aefos.Tools.Files,
  Aefos.Tools.Text,
  Aefos.Tools.Batch,
  Aefos.MCP.Tools.Common;

type
  // Dispatch seam so handler closures hold a ref-counted anchor to the
  // registrar (mirrors IPyToolDispatch in Aefos.MCP.Tools.PyTools).
  IProjectTextDispatch = interface
    ['{6F1C4B83-7A2E-4D59-9C18-0E5B3A7F2D64}']
    function ReplaceInProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function FixEncoding(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

  TMCPProjectTextRegistrar = class(TInterfacedObject, IProjectTextDispatch)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsent: IMCPConsentRegistry;
    FAudit: IMCPAuditLog;
    function _RequestGate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    procedure _Audit(const AName, ADetail, AConsent, AOutcome: string);
    function _ResolveRoot(const AContext: IMCPToolContext;
      const AParamRoot: string): string;
    function _OpenFileSet(const AContext: IMCPToolContext):
      TDictionary<string, Boolean>;
    function _BuildReplaceDescriptor: TMCPToolDescriptor;
    function _BuildFixEncodingDescriptor: TMCPToolDescriptor;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog);
    // IProjectTextDispatch
    function ReplaceInProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function FixEncoding(const AParams: TJSONObject;
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

// Boolean param: accepts a JSON true/false; absent or non-boolean -> ADefault.
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

function _BomFromName(const AName: string): TToolFileBom;
var
  LKey: string;
begin
  LKey := LowerCase(StringReplace(Trim(AName), '-', '', [rfReplaceAll]));
  if (LKey = 'none') or (LKey = 'nobom') then
    Result := fbNone
  else if (LKey = 'utf16le') or (LKey = 'utf16') then
    Result := fbUtf16LE
  else if LKey = 'utf16be' then
    Result := fbUtf16BE
  else
    Result := fbUtf8; // default — the common "add a UTF-8 BOM" case
end;

{ TMCPProjectTextRegistrar }

constructor TMCPProjectTextRegistrar.Create(const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog);
begin
  inherited Create;
  FFacade := AFacade;
  FConsent := AConsent;
  FAudit := AAudit;
end;

// Mirrors TMCPToolsRegistrar._RequestGate: a session grant short-circuits, else
// the modal runs on the main thread and a session grant is recorded. FConsent
// may be nil (Chat host) — then we ask the facade modal every time.
function TMCPProjectTextRegistrar._RequestGate(const AContext: IMCPToolContext;
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

procedure TMCPProjectTextRegistrar._Audit(const AName, ADetail, AConsent,
  AOutcome: string);
begin
  if Assigned(FAudit) then
    FAudit.Append(AName, ADetail, AConsent, AOutcome);
end;

// The glob root: the explicit param wins; otherwise the active project path.
function TMCPProjectTextRegistrar._ResolveRoot(const AContext: IMCPToolContext;
  const AParamRoot: string): string;
var
  LRoot: string;
begin
  if Trim(AParamRoot) <> '' then
    Exit(Trim(AParamRoot));
  LRoot := '';
  AContext.MarshalToMainThread(
    procedure
    begin
      LRoot := FFacade.GetProjectPath;
    end);
  Result := Trim(LRoot);
end;

// Lower-cased set of files currently open in the IDE editor (so FixEncoding can
// skip them — rewriting a BOM on disk under an open buffer would desync it).
function TMCPProjectTextRegistrar._OpenFileSet(
  const AContext: IMCPToolContext): TDictionary<string, Boolean>;
var
  LFiles: TArray<TMCPRecordEditorFile>;
  LOk: Boolean;
  LItem: TMCPRecordEditorFile;
begin
  Result := TDictionary<string, Boolean>.Create;
  LOk := False;
  LFiles := nil;
  AContext.MarshalToMainThread(
    procedure
    begin
      LOk := FFacade.GetOpenEditorFiles(LFiles);
    end);
  if not LOk then
    Exit;
  for LItem in LFiles do
    if LItem.Path <> '' then
      Result.AddOrSetValue(LowerCase(LItem.Path), True);
end;

function TMCPProjectTextRegistrar.ReplaceInProject(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LRoot, LMask, LFind, LReplace, LConsent: string;
  LRecursive, LCase: Boolean;
  LDecision: TMCPConsentDecision;
  LFiles: TArray<string>;
  LPath, LError: string;
  LInfo: TToolFileInfo;
  LEdit: TToolTextResult;
  LWrite: TMCPFileActionOutcome;
  LScanned, LChanged, LReplacements, LFailed: Integer;
  LSummary: TJSONObject;
begin
  LFind := _Str(AParams, 'find');
  if LFind = '' then
    raise EMCPError.Create(MCP_ERR_SERVER,
      'ReplaceInProject: "find" must not be empty');
  LReplace := _Str(AParams, 'replace');
  LMask := _StrDef(AParams, 'mask', '*.pas');
  LRecursive := _BoolDef(AParams, 'recursive', True);
  LCase := _BoolDef(AParams, 'case_sensitive', True);
  LRoot := _ResolveRoot(AContext, _Str(AParams, 'root'));
  if LRoot = '' then
    raise EMCPError.Create(MCP_ERR_SERVER,
      'ReplaceInProject: no "root" given and no active project to default to');

  LDecision := _RequestGate(AContext, 'ReplaceInProject',
    'Find/replace across project source files:' + sLineBreak +
    'root: ' + LRoot + '  (' + LMask + ')' + sLineBreak +
    'find:    ' + LFind + sLineBreak +
    'replace: ' + LReplace, '');
  if LDecision = cdDenied then
  begin
    _Audit('ReplaceInProject', LRoot, 'denied', 'denied');
    raise EMCPUserDenied.Create('ReplaceInProject: user denied the action');
  end;
  LConsent := TMCPConsentToken.Token(LDecision);

  LFiles := TFileBatch.ListFiles(LRoot, LMask, LRecursive); // pure enumeration
  LScanned := Length(LFiles);
  LChanged := 0;
  LReplacements := 0;
  LFailed := 0;

  for LPath in LFiles do
  begin
    LInfo := Default(TToolFileInfo);
    if TFileIO.Load(LPath, LInfo) <> tfApplied then
    begin
      Inc(LFailed);
      Continue;
    end;
    LEdit := TTextEditor.ReplaceAll(LInfo.Content, LFind, LReplace, LCase); // pure
    if (not LEdit.Ok) or (LEdit.LinesAffected = 0) then
      Continue; // no occurrence in this file — leave it untouched
    // Apply through the facade so an open unit edits its undoable buffer and a
    // closed file is written to disk — never a raw disk write under a buffer.
    LWrite := faAccessError;
    LError := '';
    AContext.MarshalToMainThread(
      procedure
      begin
        LWrite := FFacade.OverwriteFile(LPath, LEdit.Content, LError);
      end);
    if LWrite = faApplied then
    begin
      Inc(LChanged);
      Inc(LReplacements, LEdit.LinesAffected);
    end
    else
      Inc(LFailed);
  end;

  _Audit('ReplaceInProject',
    Format('%s (%s): %d files, %d replacements', [LRoot, LMask, LChanged,
    LReplacements]), LConsent, 'applied');

  LSummary := TJSONObject.Create;
  try
    LSummary.AddPair('applied', TJSONBool.Create(True));
    LSummary.AddPair('files_scanned', TJSONNumber.Create(LScanned));
    LSummary.AddPair('files_changed', TJSONNumber.Create(LChanged));
    LSummary.AddPair('replacements', TJSONNumber.Create(LReplacements));
    LSummary.AddPair('failed', TJSONNumber.Create(LFailed));
    Result := TMCPToolResult.Text(LSummary.ToJSON);
  finally
    LSummary.Free;
  end;
end;

function TMCPProjectTextRegistrar.FixEncoding(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LRoot, LMask, LConsent: string;
  LRecursive: Boolean;
  LBom: TToolFileBom;
  LDecision: TMCPConsentDecision;
  LFiles: TArray<string>;
  LPath: string;
  LInfo: TToolFileInfo;
  LRes: TToolFileResult;
  LOpen: TDictionary<string, Boolean>;
  LScanned, LConverted, LUnchanged, LFailed: Integer;
  LSkipped: TJSONArray;
  LSummary: TJSONObject;
begin
  LMask := _StrDef(AParams, 'mask', '*.pas');
  LRecursive := _BoolDef(AParams, 'recursive', True);
  LBom := _BomFromName(_StrDef(AParams, 'encoding', 'utf8'));
  LRoot := _ResolveRoot(AContext, _Str(AParams, 'root'));
  if LRoot = '' then
    raise EMCPError.Create(MCP_ERR_SERVER,
      'FixEncoding: no "root" given and no active project to default to');

  LDecision := _RequestGate(AContext, 'FixEncoding',
    'Convert the byte-order mark of project source files:' + sLineBreak +
    'root: ' + LRoot + '  (' + LMask + ')' + sLineBreak +
    'target: ' + TFileIO.BomText(LBom), '');
  if LDecision = cdDenied then
  begin
    _Audit('FixEncoding', LRoot, 'denied', 'denied');
    raise EMCPUserDenied.Create('FixEncoding: user denied the action');
  end;
  LConsent := TMCPConsentToken.Token(LDecision);

  LFiles := TFileBatch.ListFiles(LRoot, LMask, LRecursive); // pure enumeration
  LScanned := Length(LFiles);
  LConverted := 0;
  LUnchanged := 0;
  LFailed := 0;

  LSkipped := TJSONArray.Create;
  try
    LOpen := _OpenFileSet(AContext);
    try
      for LPath in LFiles do
      begin
        // Never rewrite the BOM of an open buffer's file on disk — it desyncs
        // the editor. Report it so the agent handles those via the editor.
        if LOpen.ContainsKey(LowerCase(LPath)) then
        begin
          LSkipped.Add(LPath);
          Continue;
        end;
        LInfo := Default(TToolFileInfo);
        if TFileIO.Load(LPath, LInfo) <> tfApplied then
        begin
          Inc(LFailed);
          Continue;
        end;
        if LInfo.Bom = LBom then
        begin
          Inc(LUnchanged); // already at target — idempotent, no rewrite
          Continue;
        end;
        LRes := TFileIO.ConvertBom(LPath, LInfo.Hash, LBom); // pure disk, text kept
        if LRes.Ok then
          Inc(LConverted)
        else
          Inc(LFailed);
      end;
    finally
      LOpen.Free;
    end;

    _Audit('FixEncoding',
      Format('%s (%s)->%s: %d converted, %d skipped-open', [LRoot, LMask,
      TFileIO.BomText(LBom), LConverted, LSkipped.Count]), LConsent, 'applied');

    LSummary := TJSONObject.Create;
    try
      LSummary.AddPair('applied', TJSONBool.Create(True));
      LSummary.AddPair('target_bom', TFileIO.BomText(LBom));
      LSummary.AddPair('files_scanned', TJSONNumber.Create(LScanned));
      LSummary.AddPair('converted', TJSONNumber.Create(LConverted));
      LSummary.AddPair('unchanged', TJSONNumber.Create(LUnchanged));
      LSummary.AddPair('failed', TJSONNumber.Create(LFailed));
      // Ownership of LSkipped passes to LSummary here.
      LSummary.AddPair('skipped_open', LSkipped);
      LSkipped := nil;
      Result := TMCPToolResult.Text(LSummary.ToJSON);
    finally
      LSummary.Free;
    end;
  finally
    LSkipped.Free; // nil after ownership transfer — harmless otherwise
  end;
end;

function TMCPProjectTextRegistrar._BuildReplaceDescriptor: TMCPToolDescriptor;
var
  LDispatch: IProjectTextDispatch;
begin
  LDispatch := Self; // ref-counted anchor captured by the closure
  Result := TMCPToolDescriptor.Create(
    'ReplaceInProject',
    'Replace in project',
    'Literal find/replace across every file under a root matching a glob ' +
    '(the write counterpart of the read-only FindInProject). root defaults ' +
    'to the active project directory; mask defaults to "*.pas"; recursive ' +
    'and case_sensitive default to true. Each changed file is written ' +
    'through the editor when open (undoable) or to disk when closed, so an ' +
    'open buffer is never desynced. The first call this session shows a ' +
    'confirmation modal and returns -32003 if denied. Returns ' +
    '{files_scanned, files_changed, replacements, failed}.',
    TJSONObject.ParseJSONValue(
    '{"type":"object","required":["find"],"properties":{' +
    '"find":{"type":"string","description":"Literal text to search for ' +
    '(must occur to change a file)."},' +
    '"replace":{"type":"string","description":"Replacement text (default ' +
    'empty = delete the matches)."},' +
    '"root":{"type":"string","description":"Directory to search under ' +
    '(default: the active project directory)."},' +
    '"mask":{"type":"string","description":"Filename glob, e.g. \"*.pas\" ' +
    '(default \"*.pas\")."},' +
    '"recursive":{"type":"boolean","description":"Recurse into ' +
    'subdirectories (default true)."},' +
    '"case_sensitive":{"type":"boolean","description":"Case-sensitive ' +
    'match (default true)."}}}') as TJSONObject,
    TJSONObject.ParseJSONValue('{"type":"object"}') as TJSONObject,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.ReplaceInProject(AParams, AContext);
    end);
end;

function TMCPProjectTextRegistrar._BuildFixEncodingDescriptor: TMCPToolDescriptor;
var
  LDispatch: IProjectTextDispatch;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'FixEncoding',
    'Fix file encoding',
    'Adds or converts the byte-order mark of every file under a root ' +
    'matching a glob, leaving the text content untouched. Use the default ' +
    'encoding "utf8" to add a UTF-8 BOM to .pas files that lack one (this ' +
    'fixes the ANSI/mojibake compilation trap). root defaults to the active ' +
    'project directory; mask defaults to "*.pas"; recursive defaults to ' +
    'true. encoding is one of "utf8" (default), "utf16le", "utf16be", ' +
    '"none". Files already at the target BOM are left untouched; files ' +
    'currently OPEN in the editor are skipped (rewriting their BOM on disk ' +
    'would desync the buffer) and listed in skipped_open — fix those via ' +
    'the editor. The first call this session shows a confirmation modal and ' +
    'returns -32003 if denied. Returns {target_bom, files_scanned, ' +
    'converted, unchanged, failed, skipped_open}.',
    TJSONObject.ParseJSONValue(
    '{"type":"object","properties":{' +
    '"root":{"type":"string","description":"Directory to scan (default: the ' +
    'active project directory)."},' +
    '"mask":{"type":"string","description":"Filename glob (default ' +
    '\"*.pas\")."},' +
    '"recursive":{"type":"boolean","description":"Recurse into ' +
    'subdirectories (default true)."},' +
    '"encoding":{"type":"string","enum":["utf8","utf16le","utf16be","none"],' +
    '"description":"Target BOM (default \"utf8\")."}}}') as TJSONObject,
    TJSONObject.ParseJSONValue('{"type":"object"}') as TJSONObject,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.FixEncoding(AParams, AContext);
    end);
end;

procedure TMCPProjectTextRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  AServer.RegisterTool(_BuildReplaceDescriptor);
  AServer.RegisterTool(_BuildFixEncodingDescriptor);
end;

procedure RegisterProjectTextTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog);
var
  LRegistrar: TMCPProjectTextRegistrar;
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create('RegisterProjectTextTools: AServer');
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('RegisterProjectTextTools: AFacade');
  // Not freed: the handler closures hold an IProjectTextDispatch reference and
  // own the lifetime (ADR-056), exactly like RegisterPyTools.
  LRegistrar := TMCPProjectTextRegistrar.Create(AFacade, AConsent, AAudit);
  LRegistrar.RegisterAll(AServer);
end;

end.
