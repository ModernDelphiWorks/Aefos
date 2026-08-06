unit Aefos.MCP.Tools.PyTools;

{
  Python-tool registrar — exposes each pytools/<tool>/tool.json manifest as a
  live MCP tool, run as an external Python subprocess (ESP, 2026-06-08).

  Mechanism: at server start, RegisterPyTools scans a root folder; every
  subfolder carrying a tool.json becomes one MCP tool. When the agent calls it,
  the handler:
    1. gates through the destructive-action consent modal (ADR-064) — running
       arbitrary Python is sensitive — and audits the invocation (ADR-067);
    2. resolves a Python interpreter (Aefos.Tools.PyTool);
    3. runs the script with the tool arguments as JSON on stdin and returns the
       script's stdout (JSON) as the tool result (Aefos.Tools.Process).

  This is the apply side ("there") of the pure mechanism: the runner/launcher live
  in Aefos.Tools (rtl-pure, validated standalone); here we only wire them
  to the MCP surface and the existing consent/audit collaborators. No OTA buffer
  is touched — Python tools are headless compute (the facade is used only for
  the consent modal, exactly like the other destructive tools).

  Lifetime (ADR-056): the registrar is reference-counted; its handler closures
  hold an IPyToolDispatch reference, so it lives as long as the server holds the
  descriptors. RegisterPyTools must not free it — see RegisterPyTools.

  Boundary: requires Aefos.Tools (rtl-pure). No new infrastructure.
}

interface

uses
  Aefos.MCP.Server,
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog;

// Scans APyToolsRoot for <tool>\tool.json manifests and registers one MCP tool
// per manifest on AServer. A missing/empty root registers nothing (no error).
procedure RegisterPyTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog; const APyToolsRoot: string);

implementation

uses
  System.SysUtils,
  System.Types,
  System.IOUtils,
  System.JSON,
  Aefos.Tools.Process,
  Aefos.Tools.PyTool,
  Aefos.MCP.Tools.Common;

type
  // Resolved per-tool data captured by the handler closure.
  TPyToolSpec = record
    Name: string;
    EntryPath: string;   // absolute path of the script to run
    ToolDir: string;     // working directory (the tool's own folder)
    Python: string;      // explicit interpreter from the manifest ('' = auto)
    TimeoutMs: Cardinal;
  end;

  // Dispatch seam so handler closures hold a ref-counted anchor to the
  // registrar (mirrors IMCPToolsRegistrar in Aefos.MCP.Tools).
  IPyToolDispatch = interface
    ['{2B7E9A41-5C3D-4E18-9F62-8A0D1C4B7E35}']
    function RunTool(const ASpec: TPyToolSpec; const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

  TMCPPyToolsRegistrar = class(TInterfacedObject, IPyToolDispatch)
  private
    FFacade: IMCPWorkspaceFacade;
    FConsent: IMCPConsentRegistry;
    FAudit: IMCPAuditLog;
    FRoot: string;
    function _RequestGate(const AContext: IMCPToolContext;
      const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    function _BuildDescriptor(const ASpec: TPyToolSpec; const ATitle,
      ADescription: string;
      const AInputSchema: TJSONObject): TMCPToolDescriptor;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog;
      const ARoot: string);
    // IPyToolDispatch
    function RunTool(const ASpec: TPyToolSpec; const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Returns the number of tools registered.
    function RegisterAll(const AServer: IMCPServer): Integer;
  end;

// ── small JSON / string helpers ──────────────────────────────────────────

function _Str(const AObj: TJSONObject; const AName: string): string;
var
  LValue: TJSONValue;
begin
  LValue := AObj.GetValue(AName);
  if (LValue <> nil) and (LValue is TJSONString) then
    Result := TJSONString(LValue).Value
  else
    Result := '';
end;

function _StrDef(const AObj: TJSONObject; const AName, ADefault: string): string;
begin
  Result := _Str(AObj, AName);
  if Result = '' then
    Result := ADefault;
end;

function _IntDef(const AObj: TJSONObject; const AName: string;
  const ADefault: Integer): Integer;
var
  LValue: TJSONValue;
begin
  LValue := AObj.GetValue(AName);
  if (LValue <> nil) and (LValue is TJSONNumber) then
    Result := TJSONNumber(LValue).AsInt
  else
    Result := ADefault;
end;

// An owned, independent copy of the manifest's inputSchema (the server takes
// ownership of descriptor schemas). Falls back to a permissive object schema.
function _ExtractSchema(const AObj: TJSONObject): TJSONObject;
var
  LValue: TJSONValue;
begin
  Result := nil;
  LValue := AObj.GetValue('inputSchema');
  if (LValue <> nil) and (LValue is TJSONObject) then
    Result := TJSONObject.ParseJSONValue(LValue.ToJSON) as TJSONObject;
  if Result = nil then
    Result := TJSONObject.ParseJSONValue('{"type":"object"}') as TJSONObject;
end;

function _FirstLine(const AText: string): string;
var
  LPos: Integer;
begin
  Result := Trim(AText);
  LPos := Pos(#10, Result);
  if LPos > 0 then
    Result := Trim(Copy(Result, 1, LPos - 1));
end;

{ TMCPPyToolsRegistrar }

constructor TMCPPyToolsRegistrar.Create(const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog;
  const ARoot: string);
begin
  inherited Create;
  FFacade := AFacade;
  FConsent := AConsent;
  FAudit := AAudit;
  FRoot := ARoot;
end;

// Mirrors TMCPToolsRegistrar._RequestGate: session grant short-circuits, else
// the modal runs on the main thread and a session grant is recorded.
function TMCPPyToolsRegistrar._RequestGate(const AContext: IMCPToolContext;
  const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
var
  LDecision: TMCPConsentDecision;
begin
  // FConsent is optional (the Chat hosts pass nil and rely on the facade's
  // HTML consent modal). When absent we skip the session-grant cache and ask
  // the facade every time — never deref a nil registry.
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

function TMCPPyToolsRegistrar.RunTool(const ASpec: TPyToolSpec;
  const AParams: TJSONObject; const AContext: IMCPToolContext): TMCPToolResult;
var
  LDecision: TMCPConsentDecision;
  LInterp, LInput, LConsent: string;
  LRun: TToolProcessResult;
begin
  LDecision := _RequestGate(AContext, ASpec.Name,
    'Run the Python tool "' + ASpec.Name + '" as an external process:',
    ASpec.EntryPath);
  if LDecision = cdDenied then
  begin
    FAudit.Append(ASpec.Name, ASpec.EntryPath, 'denied', 'denied');
    raise EMCPUserDenied.Create(ASpec.Name + ': user denied the action');
  end;
  LConsent := TMCPConsentToken.Token(LDecision);

  LInterp := TPythonRunner.ResolveInterpreter(ASpec.Python);
  if LInterp = '' then
  begin
    FAudit.Append(ASpec.Name, ASpec.EntryPath, LConsent, 'no-python');
    raise EMCPError.Create(MCP_ERR_SERVER,
      ASpec.Name + ': no Python interpreter found (set "python" in tool.json ' +
      'or put py/python on PATH)');
  end;

  if Assigned(AParams) then
    LInput := AParams.ToJSON
  else
    LInput := '{}';

  // Runs on the MCP worker thread already; the runner enforces the timeout.
  LRun := TPythonRunner.RunScript(LInterp, ASpec.EntryPath, LInput, ASpec.ToolDir,
    ASpec.TimeoutMs);

  case LRun.Outcome of
    poTimedOut:
      begin
        FAudit.Append(ASpec.Name, ASpec.EntryPath, LConsent, 'timed-out');
        raise EMCPError.Create(MCP_ERR_SERVER, ASpec.Name + ': timed out');
      end;
    poSpawnError:
      begin
        FAudit.Append(ASpec.Name, ASpec.EntryPath, LConsent, 'spawn-error');
        raise EMCPError.Create(MCP_ERR_SERVER,
          ASpec.Name + ': could not start the Python process');
      end;
  end;

  if not LRun.Ok then
  begin
    FAudit.Append(ASpec.Name, ASpec.EntryPath, LConsent, 'error');
    raise EMCPError.Create(MCP_ERR_SERVER, ASpec.Name + ' failed (exit ' +
      IntToStr(LRun.ExitCode) + '): ' + _FirstLine(LRun.StdErr));
  end;

  FAudit.Append(ASpec.Name, ASpec.EntryPath, LConsent, 'applied');
  Result := TMCPToolResult.Text(LRun.StdOut);
end;

function TMCPPyToolsRegistrar._BuildDescriptor(const ASpec: TPyToolSpec;
  const ATitle, ADescription: string;
  const AInputSchema: TJSONObject): TMCPToolDescriptor;
var
  LDispatch: IPyToolDispatch;
  LSpec: TPyToolSpec;
begin
  LDispatch := Self;  // ref-counted anchor captured by the closure
  LSpec := ASpec;     // per-call copy so each tool's handler is independent
  Result := TMCPToolDescriptor.Create(
    ASpec.Name,
    ATitle,
    ADescription,
    AInputSchema,
    TJSONObject.ParseJSONValue('{"type":"object"}') as TJSONObject,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.RunTool(LSpec, AParams, AContext);
    end);
end;

function TMCPPyToolsRegistrar.RegisterAll(const AServer: IMCPServer): Integer;
var
  LDirs: TStringDynArray;
  LDir, LManifest, LRaw: string;
  LJson: TJSONObject;
  LSpec: TPyToolSpec;
begin
  Result := 0;
  if not TDirectory.Exists(FRoot) then
    Exit;
  LDirs := TDirectory.GetDirectories(FRoot);
  for LDir in LDirs do
  begin
    LManifest := TPath.Combine(LDir, 'tool.json');
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
      LSpec := Default(TPyToolSpec);
      LSpec.Name := _Str(LJson, 'name');
      if LSpec.Name = '' then
        Continue;
      LSpec.ToolDir := LDir;
      LSpec.EntryPath := TPath.Combine(LDir, _StrDef(LJson, 'entry', 'main.py'));
      LSpec.Python := _Str(LJson, 'python');
      LSpec.TimeoutMs := _IntDef(LJson, 'timeoutMs', 30000);
      AServer.RegisterTool(_BuildDescriptor(LSpec,
        _StrDef(LJson, 'title', LSpec.Name), _Str(LJson, 'description'),
        _ExtractSchema(LJson)));
      Inc(Result);
    finally
      LJson.Free;
    end;
  end;
end;

procedure RegisterPyTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade; const AConsent: IMCPConsentRegistry;
  const AAudit: IMCPAuditLog; const APyToolsRoot: string);
var
  LRegistrar: TMCPPyToolsRegistrar;
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create('RegisterPyTools: AServer');
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('RegisterPyTools: AFacade');
  LRegistrar := TMCPPyToolsRegistrar.Create(AFacade, AConsent, AAudit,
    APyToolsRoot);
  // Not freed when tools were registered: the handler closures hold an
  // IPyToolDispatch reference and own the lifetime (ADR-056). When nothing was
  // registered, no closure exists, so free it here to avoid a leak.
  if LRegistrar.RegisterAll(AServer) = 0 then
    LRegistrar.Free;
end;

end.
