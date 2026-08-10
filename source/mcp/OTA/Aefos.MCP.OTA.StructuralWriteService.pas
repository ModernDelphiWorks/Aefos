unit Aefos.MCP.OTA.StructuralWriteService;

{
  Structural / file-op writes, extracted from the TMCPWorkspaceFacade god-object as
  a focused service of the SOLID split (audit S6 / facade split).

  Owns the disk-level unit mutations — DeleteUnit, RenameUnit, MoveUnitToFolder — and
  the project-membership ops AddUnitToProject / RemoveUnitFromProject. Every OTA-free
  decision (confinement to the project root, the touched-files plan, clobber refusal)
  lives in the pure StructuralWritePolicy seam (PlanUnitDelete / PlanUnitRename /
  PlanUnitMove / ConfineStructuralTarget); these methods only marshal to the IDE main
  thread and apply the plan, with the all-or-nothing move driver rolling back a
  half-applied multi-file rename/move (R4 / ADR-088-07).

  The five private helpers (_MoveFileChecked, _ApplyMovesAllOrNothing,
  _RewriteUnitClauseInFile, _CloseModuleForFileOp, _ExecuteDeleteUnit) are used ONLY
  by this slice, so they move with it. Every other dependency comes from FacadeShared
  (TryProject / FindUnitPath / ResolveUnitModule / IsModuleModified) and
  StructuralWritePolicy. The service is stateless — no FAudit, no public-method
  delegation. Bodies moved VERBATIM (only the class qualifier changes on the 5
  methods). The facade delegates the frozen IMCPWorkspaceFacade methods to a
  refcounted FStructuralWrite field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPStructuralWriteService = interface
    ['{2C7A1E94-9D63-4B50-8F38-3A6C1B5E8D40}']
    function DeleteUnit(const AUnitPath: string;
      out AError: string): TMCPFileActionOutcome;
    function AddUnitToProject(const AFilePath: string): Boolean;
    function RemoveUnitFromProject(const AUnitName: string): Boolean;
    function RenameUnit(const AUnitName, ANewUnitName: string;
      out AOutcome: TRenameOutcome): Boolean;
    function MoveUnitToFolder(const AUnitName, ATargetFolder: string;
      out AOutcome: TRenameOutcome): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPStructuralWriteService: IMCPStructuralWriteService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  Aefos.Compat.IO,
  System.RegularExpressions,
  System.Generics.Collections,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.StructuralWritePolicy;

type
  TMCPStructuralWriteService = class(TInterfacedObject, IMCPStructuralWriteService)
  public
    function DeleteUnit(const AUnitPath: string;
      out AError: string): TMCPFileActionOutcome;
    function AddUnitToProject(const AFilePath: string): Boolean;
    function RemoveUnitFromProject(const AUnitName: string): Boolean;
    function RenameUnit(const AUnitName, ANewUnitName: string;
      out AOutcome: TRenameOutcome): Boolean;
    function MoveUnitToFolder(const AUnitName, ATargetFolder: string;
      out AOutcome: TRenameOutcome): Boolean;
  end;

// Disk-disk move with parent-folder create. False on a missing source or any
// filesystem error (the all-or-nothing driver rolls back on False).
function _MoveFileChecked(const ASrc, ADst: string): Boolean;
var
  LDir: string;
begin
  Result := False;
  try
    if not TFile.Exists(ASrc) then Exit;
    LDir := TPath.GetDirectoryName(ADst);
    if (LDir <> '') and not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
    TFile.Move(ASrc, ADst);
    Result := True;
  except
    Result := False;
  end;
end;

// Apply an ordered src->dst move set all-or-nothing (R4 / ADR-088-07): on the
// first failure, revert every completed move (dst->src) so a multi-file unit is
// never left half-renamed / half-moved.
function _ApplyMovesAllOrNothing(const AMoves: TArray<TStructuralMove>): Boolean;
var
  LDone: TList<TStructuralMove>;
  LMove: TStructuralMove;
  LBack: Integer;
begin
  LDone := TList<TStructuralMove>.Create;
  try
    for LMove in AMoves do
    begin
      if not _MoveFileChecked(LMove.Src, LMove.Dst) then
      begin
        for LBack := LDone.Count - 1 downto 0 do
          _MoveFileChecked(LDone[LBack].Dst, LDone[LBack].Src);
        Exit(False);
      end;
      LDone.Add(LMove);
    end;
    Result := True;
  finally
    LDone.Free;
  end;
end;

// Rewrite the `unit <id>;` header of AFilePath from AOldBase to ANewName,
// anchored to the clause line (case-insensitive) so a same-named symbol
// elsewhere is untouched — other units' `uses` are not rewritten (RenameUnit
// BR-6).
procedure _RewriteUnitClauseInFile(const AFilePath, AOldBase, ANewName: string);
var
  LSrc, LNew: string;
begin
  if not TFile.Exists(AFilePath) then Exit;
  LSrc := TAefosText.ReadAllUtf8(AFilePath);
  LNew := TRegEx.Replace(LSrc,
    '(?im)^(\s*unit\s+)' + TRegEx.Escape(AOldBase) + '\b',
    '${1}' + ANewName);
  if LNew <> LSrc then
    TFile.WriteAllText(AFilePath, LNew, TEncoding.UTF8);
end;

// Flush + close a module before a disk-level file op so the .pas / .dfm are
// current and unlocked. No-op when the unit is not open.
procedure _CloseModuleForFileOp(const APath: string);
var
  LModule: IOTAModule;
begin
  if not TFacadeShared.ResolveUnitModule(APath, LModule) then Exit;
  if TFacadeShared.IsModuleModified(LModule) then
    LModule.Save(False, True);
  LModule.Close;
end;

// OTA body of DeleteUnit, run on the main thread: confine + plan via the pure
// PlanUnitDelete, drop project membership (best-effort), then delete every
// touched file and persist. Extracted from DeleteUnit so each method stays
// within the cognitive-complexity gate (ESP-088 verify F1).
function _ExecuteDeleteUnit(const AUnitPath: string;
  out AError: string): TMCPFileActionOutcome;
var
  LProject: IOTAProject;
  LRoot, LPath, LFile: string;
  LPlan: TStructuralPlan;
begin
  AError := '';
  if not TFacadeShared.TryProject(LProject) then
    Exit(faNoActiveProject);
  LPath := TFacadeShared.FindUnitPath(AUnitPath);
  if LPath = '' then
    LPath := AUnitPath;
  LRoot := TPath.GetDirectoryName(LProject.FileName);
  LPlan := TStructuralWritePolicy.PlanUnitDelete(LPath, LRoot,
    function(const APath: string): Boolean
    begin
      Result := TFile.Exists(APath);
    end);
  if not LPlan.Accepted then
  begin
    AError := LPlan.Reason;
    if LPlan.Reason = 'not-found' then
      Exit(faNotFound)
    else
      Exit(faAccessError);
  end;
  _CloseModuleForFileOp(LPath);
  try
    LProject.RemoveFile(LPath);
  except // NOSONAR — intentional best-effort membership removal; the file deletes below regardless (ADR-088-07)
  end;
  for LFile in LPlan.TouchedFiles do
    if TFile.Exists(LFile) then
      TFile.Delete(LFile);
  LProject.Save(False, True);
  Result := faApplied;
end;

{ ── TMCPStructuralWriteService ─────────────────────────────────────────── }

function TMCPStructuralWriteService.DeleteUnit(const AUnitPath: string;
  out AError: string): TMCPFileActionOutcome;
var
  LOutcome: TMCPFileActionOutcome;
  LError: string;
begin
  LOutcome := faNoActiveProject;
  LError   := '';
  try
    TThread.Synchronize(nil, procedure
    begin
      LOutcome := _ExecuteDeleteUnit(AUnitPath, LError);
    end);
  except
    on E: Exception do
    begin
      LOutcome := faAccessError;
      LError   := E.Message;
    end;
  end;
  AError := LError;
  Result := LOutcome;
end;

function TMCPStructuralWriteService.AddUnitToProject(
  const AFilePath: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LRoot, LFull, LReason: string;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      if not TStructuralWritePolicy.ConfineStructuralTarget(AFilePath, LRoot, LFull, LReason) then Exit;
      if not TFile.Exists(LFull) then Exit;
      LProject.AddFile(LFull, True);
      LProject.Save(False, True);
      LResult := True;
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

function TMCPStructuralWriteService.RemoveUnitFromProject(
  const AUnitName: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LPath: string;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LPath := TFacadeShared.FindUnitPath(AUnitName);
      if LPath = '' then Exit;
      LProject.RemoveFile(LPath);
      LProject.Save(False, True);
      LResult := True;
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

function TMCPStructuralWriteService.RenameUnit(const AUnitName,
  ANewUnitName: string; out AOutcome: TRenameOutcome): Boolean;
var
  LResult: Boolean;
  LReason: string;
  LChanged: Boolean;
  LTouched: TArray<string>;
begin
  LResult  := False;
  LReason  := '';
  LChanged := False;
  LTouched := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LRoot, LOldPath, LOldBase: string;
      LPlan: TStructuralPlan;
    begin
      if not TFacadeShared.TryProject(LProject) then
      begin
        LReason := 'no-active-project';
        Exit;
      end;
      LOldPath := TFacadeShared.FindUnitPath(AUnitName);
      if LOldPath = '' then
      begin
        LReason := 'unit-not-found';
        Exit;
      end;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      LPlan := TStructuralWritePolicy.PlanUnitRename(LOldPath, ANewUnitName, LRoot,
        function(const APath: string): Boolean
        begin
          Result := TFile.Exists(APath);
        end);
      if not LPlan.Accepted then
      begin
        LReason := LPlan.Reason;
        Exit;
      end;
      LOldBase := TPath.GetFileNameWithoutExtension(LOldPath);
      _CloseModuleForFileOp(LOldPath);
      try
        LProject.RemoveFile(LOldPath);
      except // NOSONAR — intentional best-effort membership drop; the add below re-establishes a member (ADR-088-07)
      end;
      if not _ApplyMovesAllOrNothing(LPlan.Moves) then
      begin
        try
          LProject.AddFile(LOldPath, True);
        except // NOSONAR — intentional best-effort rollback re-add; disk moves already reverted in _ApplyMovesAllOrNothing
        end;
        LReason := 'apply-failed';
        Exit;
      end;
      _RewriteUnitClauseInFile(LPlan.Moves[0].Dst, LOldBase, ANewUnitName);
      try
        LProject.AddFile(LPlan.Moves[0].Dst, True);
        LProject.Save(False, True);
      except
        on E: Exception do
        begin
          LReason := 'apply-failed';
          Exit;
        end;
      end;
      LChanged := True;
      LTouched := LPlan.TouchedFiles;
      LResult  := True;
    end);
  except
    on E: Exception do
    begin
      LReason := E.Message;
      LResult := False;
    end;
  end;
  AOutcome.Changed      := LChanged;
  AOutcome.TouchedFiles := LTouched;
  AOutcome.Reason       := LReason;
  Result                := LResult;
end;

function TMCPStructuralWriteService.MoveUnitToFolder(const AUnitName,
  ATargetFolder: string; out AOutcome: TRenameOutcome): Boolean;
var
  LResult: Boolean;
  LReason: string;
  LChanged: Boolean;
  LTouched: TArray<string>;
begin
  LResult  := False;
  LReason  := '';
  LChanged := False;
  LTouched := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LRoot, LOldPath: string;
      LPlan: TStructuralPlan;
    begin
      if not TFacadeShared.TryProject(LProject) then
      begin
        LReason := 'no-active-project';
        Exit;
      end;
      LOldPath := TFacadeShared.FindUnitPath(AUnitName);
      if LOldPath = '' then
      begin
        LReason := 'unit-not-found';
        Exit;
      end;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      LPlan := TStructuralWritePolicy.PlanUnitMove(LOldPath, ATargetFolder, LRoot,
        function(const APath: string): Boolean
        begin
          Result := TFile.Exists(APath);
        end);
      if not LPlan.Accepted then
      begin
        LReason := LPlan.Reason;
        Exit;
      end;
      _CloseModuleForFileOp(LOldPath);
      try
        LProject.RemoveFile(LOldPath);
      except // NOSONAR — intentional best-effort membership drop; the add below re-establishes a member (ADR-088-07)
      end;
      if not _ApplyMovesAllOrNothing(LPlan.Moves) then
      begin
        try
          LProject.AddFile(LOldPath, True);
        except // NOSONAR — intentional best-effort rollback re-add; disk moves already reverted in _ApplyMovesAllOrNothing
        end;
        LReason := 'apply-failed';
        Exit;
      end;
      try
        LProject.AddFile(LPlan.Moves[0].Dst, True);
        LProject.Save(False, True);
      except
        on E: Exception do
        begin
          LReason := 'apply-failed';
          Exit;
        end;
      end;
      LChanged := True;
      LTouched := LPlan.TouchedFiles;
      LResult  := True;
    end);
  except
    on E: Exception do
    begin
      LReason := E.Message;
      LResult := False;
    end;
  end;
  AOutcome.Changed      := LChanged;
  AOutcome.TouchedFiles := LTouched;
  AOutcome.Reason       := LReason;
  Result                := LResult;
end;

function NewMCPStructuralWriteService: IMCPStructuralWriteService;
begin
  Result := TMCPStructuralWriteService.Create;
end;

end.
