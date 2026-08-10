unit Aefos.MCP.Tools.Rename;

(*
  Rename/Move cascade MCP tools (ESP-002, Epic 1/3 Demand 2/5).

  Catalog rows: docs/mcp-catalog/catalog.json — groups "Project" + "Units",
  verdict "new" (promoted from "deferred-paid", ADR-203). 3 consent-gated
  write tools: RenameProject, RenameUnit, MoveUnitToFolder.

  Layering (ADR-115 / ADR-203 §4):
    - Zero uses ToolsAPI. All OTA contact flows through IMCPWorkspaceFacade.
    - Single public entry RegisterRenameTools(AServer, AFacade) called from
      Register.pas after the Git-group registration.

  Atomicity (ADR-204):
    - Each cascade is pre-flight (zero side effects) → staged plan → apply
      with snapshot/rollback. The pure Cascade* helpers below own the
      filesystem + `.dproj`/`.groupproj`/`unit X;` surgery and the
      snapshot/restore harness; they are reused by both TOTAFacade (live OTA)
      and TStubWorkspaceFacade (DUnit) so the rollback path is exercised
      byte-identically without an IDE (AC-09). The Cascade* helpers do plain
      text edits (no IXMLDocument) so they run headless and are byte-rollback
      safe.

  Gating (BR-7 / ADR-204 §4):
    - All three are risk Low, EMCPUserDenied (-32003) on denial, audited on
      apply. Pre-flight validation failures surface as -32602 with
      data.detail={"reason":"<code>"} (ADR-130). A rolled-back apply is a
      success-shaped envelope {changed:false, reason:"apply-failed"}.
*)

interface

uses
  System.SysUtils,
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.Consent,
  Aefos.MCP.AuditLog,
  Aefos.MCP.Tools.Common,
  Aefos.MCP.Server;

type
  IMCPRenameToolsDispatch = interface
    ['{4B1E7C30-9A52-4D6F-B284-3E9C1A7D5F40}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleRenameProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleRenameUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function HandleMoveUnitToFolder(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

type
  // ── Pure cascade helpers (RTL-only; reused by facade + stub) as a sealed
  // static namespace (never instantiated). Each cascade is pre-flight ->
  // staged plan -> apply with snapshot/rollback (ADR-204).
  TRenameCascade = class sealed
  public
    // True when AName is a valid Pascal identifier (BR-7). Empty / leading
    // digit / non-alphanumeric characters are rejected.
    class function IsValidIdentifier(const AName: string): Boolean; static;

    // Renames a project source file (`.dpr`/`.dpk`) + its sibling `.dproj`
    // (<MainSource> fix) and the owning `.groupproj` reference (when present)
    // to ANewName, atomically (ADR-204). AGroupProjPath may be '' (standalone).
    // AFail is an optional fault injector evaluated after the first filesystem
    // op — when it returns True the plan is rolled back (test seam, AC-09).
    class function RenameProject(const AProjectSrcPath, ANewName,
      AGroupProjPath: string; const AFail: TFunc<Boolean>;
      out AOutcome: TRenameOutcome): Boolean; static;

    // Renames a unit `.pas` (+ paired `.dfm`) to ANewUnitName, rewrites the
    // `unit X;` clause, and fixes the `.dproj` reference, atomically. ADProjPath
    // may be '' (no reference fix). Foreign `uses` clauses are NOT rewritten
    // (BR-6 / out of scope).
    class function RenameUnit(const AUnitPath, ANewUnitName,
      ADProjPath: string; const AFail: TFunc<Boolean>;
      out AOutcome: TRenameOutcome): Boolean; static;

    // Moves a unit `.pas` (+ paired `.dfm`) into ATargetFolder (project-relative,
    // created if absent, rejected when outside AProjectRoot) and fixes the
    // `.dproj` relative path, atomically. The unit name is unchanged.
    class function MoveUnitToFolder(const AUnitPath, ATargetFolder,
      ADProjPath, AProjectRoot: string; const AFail: TFunc<Boolean>;
      out AOutcome: TRenameOutcome): Boolean; static;
  end;

procedure RegisterRenameTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade); overload;
procedure RegisterRenameTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog); overload;

implementation

uses
  System.Classes,
  System.IOUtils,
  Aefos.Compat.IO,
  System.RegularExpressions,
  System.Generics.Collections;

type
  // Raised by the AFail test seam (and any in-plan error) to trigger a full
  // snapshot rollback. Never crosses the MCP boundary.
  ERenameApplyFault = class(Exception);

  // Snapshot/restore harness for an N-file cascade (ADR-204). Snapshot every
  // path the plan will touch before mutating it; on any failure Rollback
  // restores each file to its pre-call bytes (or deletes files that did not
  // exist) — byte-identical restoration.
  TRenameTxn = class
  private
    FPaths: TStringList;
    FBytes: TList<TBytes>;
    FExisted: TList<Boolean>;
    FCreatedDirs: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Snapshot(const APath: string);
    procedure MarkDirCreated(const ADir: string);
    procedure Rollback;
  end;

{ TRenameTxn }

constructor TRenameTxn.Create;
begin
  inherited Create;
  FPaths := TStringList.Create;
  // CaseSensitive False so the IndexOf guard in Snapshot dedups path-insensitively.
  // No Duplicates/Sorted: FPaths is index-aligned with FBytes/FExisted (parallel
  // append), so a sorted insert would misalign them and corrupt rollback; the
  // explicit IndexOf guard in Snapshot already prevents duplicate snapshots.
  FPaths.CaseSensitive := False;
  FBytes := TList<TBytes>.Create;
  FExisted := TList<Boolean>.Create;
  FCreatedDirs := TStringList.Create;
end;

destructor TRenameTxn.Destroy;
begin
  FCreatedDirs.Free;
  FExisted.Free;
  FBytes.Free;
  FPaths.Free;
  inherited Destroy;
end;

procedure TRenameTxn.Snapshot(const APath: string);
var
  LBytes: TBytes;
begin
  if APath = '' then
    Exit;
  if FPaths.IndexOf(APath) >= 0 then
    Exit;
  FPaths.Add(APath);
  if TFile.Exists(APath) then
  begin
    LBytes := TFile.ReadAllBytes(APath);
    FBytes.Add(LBytes);
    FExisted.Add(True);
  end
  else
  begin
    SetLength(LBytes, 0);
    FBytes.Add(LBytes);
    FExisted.Add(False);
  end;
end;

procedure TRenameTxn.MarkDirCreated(const ADir: string);
begin
  if ADir <> '' then
    FCreatedDirs.Add(ADir);
end;

procedure TRenameTxn.Rollback;
var
  LFor: Integer;
  LPath, LDir: string;
begin
  // Restore files in reverse declaration order.
  for LFor := FPaths.Count - 1 downto 0 do
  begin
    LPath := FPaths[LFor];
    try
      if FExisted[LFor] then
        TFile.WriteAllBytes(LPath, FBytes[LFor])
      else if TFile.Exists(LPath) then
        TFile.Delete(LPath);
    except
    end;
  end;
  // Remove directories we created, deepest first, only when empty.
  for LFor := FCreatedDirs.Count - 1 downto 0 do
  begin
    LDir := FCreatedDirs[LFor];
    try
      if TDirectory.Exists(LDir)
        and (Length(TDirectory.GetFileSystemEntries(LDir)) = 0) then
        TDirectory.Delete(LDir);
    except
    end;
  end;
end;

// ── Pure helpers ────────────────────────────────────────────────────────

class function TRenameCascade.IsValidIdentifier(const AName: string): Boolean;
var
  LFor: Integer;
  LCh: Char;
begin
  Result := False;
  if AName = '' then
    Exit;
  if not CharInSet(AName[1], ['A'..'Z', 'a'..'z', '_']) then
    Exit;
  for LFor := 2 to Length(AName) do
  begin
    LCh := AName[LFor];
    if not CharInSet(LCh, ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit;
  end;
  Result := True;
end;

// Rewrites the `unit <old>;` clause of ASource to `unit <new>`. Only the
// declaration token is touched; foreign references are left intact (BR-6).
function _RewriteUnitClause(const ASource, AOldName, ANewName: string): string;
begin
  Result := TRegEx.Replace(ASource,
    '\bunit\s+' + TRegEx.Escape(AOldName) + '\b',
    'unit ' + ANewName, [roIgnoreCase]);
end;

// Replaces every occurrence of AOldToken with ANewToken in the text file at
// APath. No-op when the file does not exist.
procedure _ReplaceInFile(const APath, AOldToken, ANewToken: string);
var
  LText: string;
begin
  if not TFile.Exists(APath) then
    Exit;
  LText := TAefosText.ReadAllUtf8(APath);
  LText := StringReplace(LText, AOldToken, ANewToken,
    [rfReplaceAll, rfIgnoreCase]);
  TFile.WriteAllText(APath, LText, TEncoding.UTF8);
end;

// Project-dir-relative path for APath (the form the `.dproj` <DCCReference>
// Include uses).
function _RelTo(const ABaseDir, APath: string): string;
begin
  Result := ExtractRelativePath(IncludeTrailingPathDelimiter(ABaseDir), APath);
end;

// Fixes the unit's `.dproj` <DCCReference> path(s) after a rename or move:
// rewrites the AOldPas→ANewPas reference and, when AHasDfm, the AOldDfm→ANewDfm
// reference, anchored on project-dir-relative tokens. Shared by RenameUnit and
// MoveUnitToFolder (identical surgery; the only difference is the new dir).
procedure _FixDProjUnitRef(const ADProjPath, AOldPas, ANewPas, AOldDfm,
  ANewDfm: string; const AHasDfm: Boolean);
var
  LDProjDir: string;
begin
  LDProjDir := ExtractFilePath(ADProjPath);
  _ReplaceInFile(ADProjPath, _RelTo(LDProjDir, AOldPas),
    _RelTo(LDProjDir, ANewPas));
  if AHasDfm then
    _ReplaceInFile(ADProjPath, _RelTo(LDProjDir, AOldDfm),
      _RelTo(LDProjDir, ANewDfm));
end;

// Resolves ATargetFolder against AProjectRoot and validates it stays inside the
// root (rejects `..\` escapes and absolute siblings). On success returns True
// with ATargetFull (absolute, trailing-delimited); otherwise False with
// AReason='outside-root'. Zero side effects (BR-2).
function _ValidateMoveTarget(const AProjectRoot, ATargetFolder: string;
  out ATargetFull, AReason: string): Boolean;
var
  LRootFull: string;
begin
  ATargetFull := '';
  AReason := '';
  if (AProjectRoot = '') or (Trim(ATargetFolder) = '') then
  begin
    AReason := 'outside-root';
    Exit(False);
  end;
  LRootFull := IncludeTrailingPathDelimiter(
    TPath.GetFullPath(ExcludeTrailingPathDelimiter(AProjectRoot)));
  ATargetFull := IncludeTrailingPathDelimiter(
    TPath.GetFullPath(TPath.Combine(AProjectRoot, ATargetFolder)));
  if not ATargetFull.StartsWith(LRootFull, True) then
  begin
    AReason := 'outside-root';
    Exit(False);
  end;
  Result := True;
end;

class function TRenameCascade.RenameProject(const AProjectSrcPath, ANewName,
  AGroupProjPath: string; const AFail: TFunc<Boolean>;
  out AOutcome: TRenameOutcome): Boolean;
var
  LDir, LExt, LOldBase, LNewSrc, LOldDproj, LNewDproj: string;
  LHasDproj: Boolean;
  LTxn: TRenameTxn;
  LTouched: TList<string>;
begin
  AOutcome := Default(TRenameOutcome);
  // Pre-flight (zero side effects).
  if not IsValidIdentifier(ANewName) then
  begin
    AOutcome.Reason := 'invalid-name';
    Exit(False);
  end;
  if (AProjectSrcPath = '') or not TFile.Exists(AProjectSrcPath) then
  begin
    AOutcome.Reason := 'project-not-found';
    Exit(False);
  end;
  LDir := ExtractFilePath(AProjectSrcPath);
  LExt := ExtractFileExt(AProjectSrcPath);             // .dpr / .dpk
  LOldBase := ChangeFileExt(ExtractFileName(AProjectSrcPath), '');
  LNewSrc := LDir + ANewName + LExt;
  if SameText(LNewSrc, AProjectSrcPath) then
    Exit(True);                                         // idempotent (FR-8)
  if TFile.Exists(LNewSrc) then
  begin
    AOutcome.Reason := 'name-collision';
    Exit(False);
  end;
  LOldDproj := ChangeFileExt(AProjectSrcPath, '.dproj');
  LHasDproj := TFile.Exists(LOldDproj);
  LNewDproj := LDir + ANewName + '.dproj';
  if LHasDproj and TFile.Exists(LNewDproj) then
  begin
    AOutcome.Reason := 'name-collision';
    Exit(False);
  end;
  // Apply with rollback.
  LTxn := TRenameTxn.Create;
  LTouched := TList<string>.Create;
  try
    try
      LTxn.Snapshot(AProjectSrcPath);
      LTxn.Snapshot(LNewSrc);
      if LHasDproj then
      begin
        LTxn.Snapshot(LOldDproj);
        LTxn.Snapshot(LNewDproj);
      end;
      if (AGroupProjPath <> '') and TFile.Exists(AGroupProjPath) then
        LTxn.Snapshot(AGroupProjPath);

      TFile.Move(AProjectSrcPath, LNewSrc);
      LTouched.Add(LNewSrc);
      if Assigned(AFail) and AFail() then
        raise ERenameApplyFault.Create('fault-injected');

      if LHasDproj then
      begin
        TFile.Move(LOldDproj, LNewDproj);
        _ReplaceInFile(LNewDproj, LOldBase + LExt, ANewName + LExt);
        LTouched.Add(LNewDproj);
      end;
      if (AGroupProjPath <> '') and TFile.Exists(AGroupProjPath) then
      begin
        _ReplaceInFile(AGroupProjPath, LOldBase + '.dproj',
          ANewName + '.dproj');
        LTouched.Add(AGroupProjPath);
      end;

      AOutcome.Changed := True;
      AOutcome.TouchedFiles := LTouched.ToArray;
      Result := True;
    except
      LTxn.Rollback;
      AOutcome := Default(TRenameOutcome);
      AOutcome.Reason := 'apply-failed';
      Result := True;                                   // ADR-204 §5 envelope
    end;
  finally
    LTouched.Free;
    LTxn.Free;
  end;
end;

class function TRenameCascade.RenameUnit(const AUnitPath, ANewUnitName,
  ADProjPath: string; const AFail: TFunc<Boolean>;
  out AOutcome: TRenameOutcome): Boolean;
var
  LDir, LOldBase, LNewPas, LOldDfm, LNewDfm: string;
  LHasDfm, LHasDproj: Boolean;
  LTxn: TRenameTxn;
  LTouched: TList<string>;
begin
  AOutcome := Default(TRenameOutcome);
  if not IsValidIdentifier(ANewUnitName) then
  begin
    AOutcome.Reason := 'invalid-name';
    Exit(False);
  end;
  if (AUnitPath = '') or not TFile.Exists(AUnitPath) then
  begin
    AOutcome.Reason := 'file-not-found';
    Exit(False);
  end;
  LHasDproj := (ADProjPath <> '') and TFile.Exists(ADProjPath);
  LDir := ExtractFilePath(AUnitPath);
  LOldBase := ChangeFileExt(ExtractFileName(AUnitPath), '');
  LNewPas := LDir + ANewUnitName + '.pas';
  if SameText(LNewPas, AUnitPath) then
    Exit(True);                                         // idempotent (FR-8)
  if TFile.Exists(LNewPas) then
  begin
    AOutcome.Reason := 'name-collision';
    Exit(False);
  end;
  LOldDfm := ChangeFileExt(AUnitPath, '.dfm');
  LHasDfm := TFile.Exists(LOldDfm);
  LNewDfm := LDir + ANewUnitName + '.dfm';
  if LHasDfm and TFile.Exists(LNewDfm) then
  begin
    AOutcome.Reason := 'name-collision';
    Exit(False);
  end;
  LTxn := TRenameTxn.Create;
  LTouched := TList<string>.Create;
  try
    try
      LTxn.Snapshot(AUnitPath);
      LTxn.Snapshot(LNewPas);
      if LHasDfm then
      begin
        LTxn.Snapshot(LOldDfm);
        LTxn.Snapshot(LNewDfm);
      end;
      if LHasDproj then
        LTxn.Snapshot(ADProjPath);

      TFile.Move(AUnitPath, LNewPas);
      LTouched.Add(LNewPas);
      if Assigned(AFail) and AFail() then
        raise ERenameApplyFault.Create('fault-injected');

      // Rewrite the `unit X;` clause in the renamed source.
      TFile.WriteAllText(LNewPas,
        _RewriteUnitClause(TAefosText.ReadAllUtf8(LNewPas),
          LOldBase, ANewUnitName), TEncoding.UTF8);

      if LHasDfm then
      begin
        TFile.Move(LOldDfm, LNewDfm);
        LTouched.Add(LNewDfm);
      end;

      if LHasDproj then
      begin
        _FixDProjUnitRef(ADProjPath, AUnitPath, LNewPas, LOldDfm, LNewDfm,
          LHasDfm);
        LTouched.Add(ADProjPath);
      end;

      AOutcome.Changed := True;
      AOutcome.TouchedFiles := LTouched.ToArray;
      Result := True;
    except
      LTxn.Rollback;
      AOutcome := Default(TRenameOutcome);
      AOutcome.Reason := 'apply-failed';
      Result := True;
    end;
  finally
    LTouched.Free;
    LTxn.Free;
  end;
end;

class function TRenameCascade.MoveUnitToFolder(const AUnitPath, ATargetFolder,
  ADProjPath, AProjectRoot: string; const AFail: TFunc<Boolean>;
  out AOutcome: TRenameOutcome): Boolean;
var
  LTargetFull, LSrcDir, LNewPas, LOldDfm, LNewDfm, LReason: string;
  LHasDfm, LHasDproj, LDirCreated: Boolean;
  LTxn: TRenameTxn;
  LTouched: TList<string>;
begin
  AOutcome := Default(TRenameOutcome);
  if (AUnitPath = '') or not TFile.Exists(AUnitPath) then
  begin
    AOutcome.Reason := 'file-not-found';
    Exit(False);
  end;
  if not _ValidateMoveTarget(AProjectRoot, ATargetFolder, LTargetFull,
    LReason) then
  begin
    AOutcome.Reason := LReason;
    Exit(False);
  end;
  LSrcDir := IncludeTrailingPathDelimiter(
    TPath.GetFullPath(ExtractFileDir(AUnitPath)));
  if SameText(LSrcDir, LTargetFull) then
    Exit(True);                                         // idempotent (FR-8)
  LNewPas := LTargetFull + ExtractFileName(AUnitPath);
  if TFile.Exists(LNewPas) then
  begin
    AOutcome.Reason := 'name-collision';
    Exit(False);
  end;
  LOldDfm := ChangeFileExt(AUnitPath, '.dfm');
  LHasDfm := TFile.Exists(LOldDfm);
  LNewDfm := LTargetFull + ChangeFileExt(ExtractFileName(AUnitPath), '.dfm');
  if LHasDfm and TFile.Exists(LNewDfm) then
  begin
    AOutcome.Reason := 'name-collision';
    Exit(False);
  end;
  LHasDproj := (ADProjPath <> '') and TFile.Exists(ADProjPath);
  LTxn := TRenameTxn.Create;
  LTouched := TList<string>.Create;
  try
    try
      LDirCreated := not TDirectory.Exists(LTargetFull);
      if LDirCreated then
      begin
        TDirectory.CreateDirectory(LTargetFull);
        LTxn.MarkDirCreated(ExcludeTrailingPathDelimiter(LTargetFull));
      end;
      LTxn.Snapshot(AUnitPath);
      LTxn.Snapshot(LNewPas);
      if LHasDfm then
      begin
        LTxn.Snapshot(LOldDfm);
        LTxn.Snapshot(LNewDfm);
      end;
      if LHasDproj then
        LTxn.Snapshot(ADProjPath);

      TFile.Move(AUnitPath, LNewPas);
      LTouched.Add(LNewPas);
      if Assigned(AFail) and AFail() then
        raise ERenameApplyFault.Create('fault-injected');

      if LHasDfm then
      begin
        TFile.Move(LOldDfm, LNewDfm);
        LTouched.Add(LNewDfm);
      end;

      if LHasDproj then
      begin
        _FixDProjUnitRef(ADProjPath, AUnitPath, LNewPas, LOldDfm, LNewDfm,
          LHasDfm);
        LTouched.Add(ADProjPath);
      end;

      AOutcome.Changed := True;
      AOutcome.TouchedFiles := LTouched.ToArray;
      Result := True;
    except
      LTxn.Rollback;
      AOutcome := Default(TRenameOutcome);
      AOutcome.Reason := 'apply-failed';
      Result := True;
    end;
  finally
    LTouched.Free;
    LTxn.Free;
  end;
end;

// ── Registrar ───────────────────────────────────────────────────────────

type
  TMCPRenameToolsRegistrar = class(TMCPToolsRegistrarBase, IMCPRenameToolsDispatch)
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
    function _SchemaTwoStrings(const AName1, ADesc1, AName2,
      ADesc2: string): TJSONObject;
    function _SchemaOutcomeResult: TJSONObject;
    // Result builders.
    function _ResultOutcome(const AOutcome: TRenameOutcome): TMCPToolResult;
    // Param readers.
    // Handlers.
    function _HandleRenameProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleRenameUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleMoveUnitToFolder(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function IMCPRenameToolsDispatch.HandleRenameProject = _HandleRenameProject;
    function IMCPRenameToolsDispatch.HandleRenameUnit = _HandleRenameUnit;
    function IMCPRenameToolsDispatch.HandleMoveUnitToFolder =
      _HandleMoveUnitToFolder;
    // Descriptor builders.
    function _BuildRenameProject: TMCPToolDescriptor;
    function _BuildRenameUnit: TMCPToolDescriptor;
    function _BuildMoveUnitToFolder: TMCPToolDescriptor;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPRenameToolsRegistrar.Create(const AFacade: IMCPWorkspaceFacade;
  const AConsent: IMCPConsentRegistry; const AAudit: IMCPAuditLog);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TMCPRenameToolsRegistrar: AFacade');
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

procedure TMCPRenameToolsRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPRenameToolsRegistrar.RegisterAll: AServer');
  AServer.RegisterTool(_BuildRenameProject);
  AServer.RegisterTool(_BuildRenameUnit);
  AServer.RegisterTool(_BuildMoveUnitToFolder);
end;

function TMCPRenameToolsRegistrar._RequestGate(const AContext: IMCPToolContext;
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

procedure TMCPRenameToolsRegistrar._AuditDenied(const AToolName, AArgs: string);
begin
  FAudit.Append(AToolName, AArgs, 'denied', 'denied');
end;

procedure TMCPRenameToolsRegistrar._AuditApplied(const AToolName, AArgs: string;
  const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'applied');
end;

procedure TMCPRenameToolsRegistrar._AuditFailed(const AToolName, AArgs: string;
  const ADecision: TMCPConsentDecision);
begin
  FAudit.Append(AToolName, AArgs, _ConsentToken(ADecision), 'failed');
end;

function TMCPRenameToolsRegistrar._SchemaTwoStrings(const AName1, ADesc1,
  AName2, ADesc2: string): TJSONObject;
var
  LProps, LP1, LP2: TJSONObject;
  LRequired: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LP1 := TJSONObject.Create;
  LP1.AddPair('type', 'string');
  LP1.AddPair('description', ADesc1);
  LProps.AddPair(AName1, LP1);
  LP2 := TJSONObject.Create;
  LP2.AddPair('type', 'string');
  LP2.AddPair('description', ADesc2);
  LProps.AddPair(AName2, LP2);
  Result.AddPair('properties', LProps);
  LRequired := TJSONArray.Create;
  LRequired.Add(AName1);
  LRequired.Add(AName2);
  Result.AddPair('required', LRequired);
end;

function TMCPRenameToolsRegistrar._SchemaOutcomeResult: TJSONObject;
var
  LProps, LChanged, LTouched, LItems, LReason: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LChanged := TJSONObject.Create;
  LChanged.AddPair('type', 'boolean');
  LProps.AddPair('changed', LChanged);
  LTouched := TJSONObject.Create;
  LTouched.AddPair('type', 'array');
  LItems := TJSONObject.Create;
  LItems.AddPair('type', 'string');
  LTouched.AddPair('items', LItems);
  LProps.AddPair('touchedFiles', LTouched);
  LReason := TJSONObject.Create;
  LReason.AddPair('type', 'string');
  LProps.AddPair('reason', LReason);
  Result.AddPair('properties', LProps);
end;

function TMCPRenameToolsRegistrar._ResultOutcome(
  const AOutcome: TRenameOutcome): TMCPToolResult;
var
  LObj: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('changed', TJSONBool.Create(AOutcome.Changed));
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AOutcome.TouchedFiles) do
      LArr.Add(AOutcome.TouchedFiles[LFor]);
    LObj.AddPair('touchedFiles', LArr);
    LObj.AddPair('reason', AOutcome.Reason);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPRenameToolsRegistrar._HandleRenameProject(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LOldName, LNewName, LArgs: string;
  LDecision: TMCPConsentDecision;
  LOutcome: TRenameOutcome;
  LOk: Boolean;
begin
  LOldName := _ReadString(AParams, 'oldName');
  LNewName := _ReadString(AParams, 'newName');
  if Trim(LNewName) = '' then
    raise EMCPInvalidParams.Create(
      'RenameProject: newName rejected;'
      + ' data.detail={"reason":"invalid-name"}');
  LArgs := LOldName + '->' + LNewName;
  LDecision := _RequestGate(AContext, 'RenameProject',
    'Rename project (.dpr/.dproj + .groupproj ref):', LArgs);
  if LDecision = cdDenied then
  begin
    _AuditDenied('RenameProject', LArgs);
    raise EMCPUserDenied.Create('RenameProject: user denied the action');
  end;
  LOutcome := Default(TRenameOutcome);
  LOk := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LOk := FFacade.RenameProject(LOldName, LNewName, LOutcome);
    end);
  if not LOk then
  begin
    _AuditFailed('RenameProject', LArgs + '|' + LOutcome.Reason, LDecision);
    raise EMCPInvalidParams.Create(
      'RenameProject: ' + LOutcome.Reason
      + '; data.detail={"reason":"' + LOutcome.Reason + '"}');
  end;
  if LOutcome.Changed or (LOutcome.Reason = '') then
    _AuditApplied('RenameProject', LArgs, LDecision)
  else
    _AuditFailed('RenameProject', LArgs + '|' + LOutcome.Reason, LDecision);
  Result := _ResultOutcome(LOutcome);
end;

function TMCPRenameToolsRegistrar._HandleRenameUnit(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName, LNewName, LArgs: string;
  LDecision: TMCPConsentDecision;
  LOutcome: TRenameOutcome;
  LOk: Boolean;
begin
  LUnitName := _ReadString(AParams, 'unitName');
  LNewName := _ReadString(AParams, 'newUnitName');
  if Trim(LNewName) = '' then
    raise EMCPInvalidParams.Create(
      'RenameUnit: newUnitName rejected;'
      + ' data.detail={"reason":"invalid-name"}');
  LArgs := LUnitName + '->' + LNewName;
  LDecision := _RequestGate(AContext, 'RenameUnit',
    'Rename unit (.pas/.dfm + unit clause + .dproj ref):', LArgs);
  if LDecision = cdDenied then
  begin
    _AuditDenied('RenameUnit', LArgs);
    raise EMCPUserDenied.Create('RenameUnit: user denied the action');
  end;
  LOutcome := Default(TRenameOutcome);
  LOk := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LOk := FFacade.RenameUnit(LUnitName, LNewName, LOutcome);
    end);
  if not LOk then
  begin
    _AuditFailed('RenameUnit', LArgs + '|' + LOutcome.Reason, LDecision);
    raise EMCPInvalidParams.Create(
      'RenameUnit: ' + LOutcome.Reason
      + '; data.detail={"reason":"' + LOutcome.Reason + '"}');
  end;
  if LOutcome.Changed or (LOutcome.Reason = '') then
    _AuditApplied('RenameUnit', LArgs, LDecision)
  else
    _AuditFailed('RenameUnit', LArgs + '|' + LOutcome.Reason, LDecision);
  Result := _ResultOutcome(LOutcome);
end;

function TMCPRenameToolsRegistrar._HandleMoveUnitToFolder(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LUnitName, LTargetFolder, LArgs: string;
  LDecision: TMCPConsentDecision;
  LOutcome: TRenameOutcome;
  LOk: Boolean;
begin
  LUnitName := _ReadString(AParams, 'unitName');
  LTargetFolder := _ReadString(AParams, 'targetFolder');
  if Trim(LTargetFolder) = '' then
    raise EMCPInvalidParams.Create(
      'MoveUnitToFolder: targetFolder rejected;'
      + ' data.detail={"reason":"invalid-name"}');
  LArgs := LUnitName + '->' + LTargetFolder;
  LDecision := _RequestGate(AContext, 'MoveUnitToFolder',
    'Move unit (.pas/.dfm) to folder + fix .dproj path:', LArgs);
  if LDecision = cdDenied then
  begin
    _AuditDenied('MoveUnitToFolder', LArgs);
    raise EMCPUserDenied.Create('MoveUnitToFolder: user denied the action');
  end;
  LOutcome := Default(TRenameOutcome);
  LOk := False;
  AContext.MarshalToMainThread(
    procedure
    begin
      LOk := FFacade.MoveUnitToFolder(LUnitName, LTargetFolder, LOutcome);
    end);
  if not LOk then
  begin
    _AuditFailed('MoveUnitToFolder', LArgs + '|' + LOutcome.Reason, LDecision);
    raise EMCPInvalidParams.Create(
      'MoveUnitToFolder: ' + LOutcome.Reason
      + '; data.detail={"reason":"' + LOutcome.Reason + '"}');
  end;
  if LOutcome.Changed or (LOutcome.Reason = '') then
    _AuditApplied('MoveUnitToFolder', LArgs, LDecision)
  else
    _AuditFailed('MoveUnitToFolder', LArgs + '|' + LOutcome.Reason, LDecision);
  Result := _ResultOutcome(LOutcome);
end;

function TMCPRenameToolsRegistrar._BuildRenameProject: TMCPToolDescriptor;
var
  LDispatch: IMCPRenameToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('RenameProject', 'Rename project',
    'Renames the project (.dpr/.dpk + .dproj) and fixes the reference in the '
    + '.groupproj, atomically (rollback on failure).',
    _SchemaTwoStrings('oldName', 'Current project base name.',
      'newName', 'New project base name (Pascal identifier).'),
    _SchemaOutcomeResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRenameProject(AParams, AContext);
    end);
end;

function TMCPRenameToolsRegistrar._BuildRenameUnit: TMCPToolDescriptor;
var
  LDispatch: IMCPRenameToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('RenameUnit', 'Rename unit',
    'Renames the unit (.pas + .dfm), rewrites the `unit X;` clause and '
    + 'fixes the reference in the .dproj. Does NOT rewrite `uses` clauses of '
    + 'other units (BR-6).',
    _SchemaTwoStrings('unitName', 'Current unit name.',
      'newUnitName', 'New unit name (Pascal identifier).'),
    _SchemaOutcomeResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleRenameUnit(AParams, AContext);
    end);
end;

function TMCPRenameToolsRegistrar._BuildMoveUnitToFolder: TMCPToolDescriptor;
var
  LDispatch: IMCPRenameToolsDispatch;
begin
  LDispatch := Self;
  Result := _BuildDescriptor('MoveUnitToFolder', 'Move unit to folder',
    'Moves a unit (.pas + .dfm) into a folder (project-relative, created '
    + 'if absent, rejected outside the root) and fixes the path in the .dproj.',
    _SchemaTwoStrings('unitName', 'Unit to move.',
      'targetFolder', 'Project-relative target folder.'),
    _SchemaOutcomeResult,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleMoveUnitToFolder(AParams, AContext);
    end);
end;

procedure RegisterRenameTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade);
var
  LRegistrar: IMCPRenameToolsDispatch;
begin
  LRegistrar := TMCPRenameToolsRegistrar.Create(AFacade, nil, nil);
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterRenameTools(const AServer: IMCPServer;
  const AFacade: IMCPWorkspaceFacade;
  const AConsentRegistry: IMCPConsentRegistry;
  const AAuditLog: IMCPAuditLog);
var
  LRegistrar: IMCPRenameToolsDispatch;
begin
  LRegistrar := TMCPRenameToolsRegistrar.Create(AFacade, AConsentRegistry,
    AAuditLog);
  LRegistrar.RegisterAll(AServer);
end;

end.
