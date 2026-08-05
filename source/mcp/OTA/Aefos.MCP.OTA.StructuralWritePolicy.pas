unit Aefos.MCP.OTA.StructuralWritePolicy;

{
  Pure structural-write policy seam (ESP-088, S2 / ADR-088-07 / BR10).

  Pure RTL — no ToolsAPI, no VCL, no disk write. Carries every OTA-free
  decision the file-identity / project-membership writes (rename / move /
  delete a unit) must make before the facade touches IOTAProject or the disk:

    - PlanUnitRename  — rename a unit's .pas (+ companion .dfm) in place to a new
                        Pascal name, confining every destination to the project
                        root, refusing a clobber (no-overwrite), and surfacing
                        the `unit X;` rewrite target (backs RenameUnit).
    - PlanUnitMove    — move a unit's .pas (+ companion .dfm) into a confined,
                        project-relative folder, basename preserved (backs
                        MoveUnitToFolder).
    - PlanUnitDelete  — enumerate a unit's .pas (+ companion .dfm) for deletion,
                        every target confined to the root (backs DeleteUnit).
    - ConfineStructuralTarget — confine a single add/create target to the root,
                        reusing the shared ContentWritePolicy predicate (backs
                        AddUnitToProject / membership ops).

  Each unit plan emits an ordered, root-confined src->dst move set the facade
  applies all-or-nothing (roll back every completed move on any failure, R4),
  plus the touched-files list to report (TRenameOutcome.TouchedFiles, AC7). The
  companion .dfm is included only when it exists on disk (injected probe).

  Confinement reuses ContentWritePolicy.ConfineWritePath (ADR-087-07, the D4
  predicate extended here from single-file writes to the structural tier);
  name validation reuses UnitCreatePolicy.IsValidUnitName. Existence is injected
  (TPathExistsFunc) so the rules stay deterministic and disk-free for unit
  tests, exactly as UnitCreatePolicy injects TUnitExistsFunc. The OTA wiring
  (TThread.Synchronize + IOTAProject.AddFile/RemoveFile + TFile.Move/Delete)
  lives in the UI facade and is the only OTA-bound, structurally-exempt part
  (covered live, AC7).
}

interface

type
  // Injected existence probe — the facade passes TFile.Exists; tests a stub.
  TPathExistsFunc = reference to function(const APath: string): Boolean;

  // One source->destination file move in an all-or-nothing structural plan.
  TStructuralMove = record
    Src: string;
    Dst: string;
  end;

  // Resolved structural decision (rename / move / delete). When Accepted, Moves
  // is the ordered, root-confined src->dst set the facade applies all-or-nothing
  // and TouchedFiles is the destination (rename/move) or deleted (delete) file
  // list to report; on refusal, Reason is the kebab cause and no file is
  // touched (ADR-088-07 non-partial sentinel). NewUnitName carries the
  // `unit X;` rewrite target for a rename (empty for move/delete).
  TStructuralPlan = record
    Accepted: Boolean;
    Reason: string;
    NewUnitName: string;
    Moves: TArray<TStructuralMove>;
    TouchedFiles: TArray<string>;
    function MoveCount: Integer;
  end;

  // Pure structural-write policy seam as a sealed static namespace
  // (see the unit header for the ESP-088 / ADR-088 contract). Never instantiated.
  TStructuralWritePolicy = class sealed
  public
    // Plan a unit rename: the .pas (and its companion .dfm when present) renamed in
    // place to ANewUnitName, every destination confined to AProjectRoot. Refuses an
    // invalid name (`invalid-unit-name`), an unresolved/out-of-root source
    // (`unit-not-found` / `path-escape`), or an existing destination
    // (`already-exists`). NewUnitName carries the validated rewrite target.
    class function PlanUnitRename(const ASourcePas, ANewUnitName, AProjectRoot: string;
      const AExists: TPathExistsFunc): TStructuralPlan; static;

    // Plan a unit move into ATargetFolder (project-relative): the .pas (+ companion
    // .dfm) moved into the confined folder, basename preserved. Refuses an
    // out-of-root folder (`path-escape`), an unresolved source (`unit-not-found`),
    // or an existing destination (`already-exists`).
    class function PlanUnitMove(const ASourcePas, ATargetFolder, AProjectRoot: string;
      const AExists: TPathExistsFunc): TStructuralPlan; static;

    // Plan a unit delete: the .pas (+ companion .dfm when present) listed for
    // deletion, every target confined to AProjectRoot. Refuses an unresolved
    // (`not-found`) or out-of-root (`path-escape`) source. TouchedFiles is the set
    // to delete; Moves is empty.
    class function PlanUnitDelete(const ASourcePas, AProjectRoot: string;
      const AExists: TPathExistsFunc): TStructuralPlan; static;

    // Confine a single structural target (add / create) to AProjectRoot, returning
    // the canonical absolute path or a kebab refusal reason. Thin reuse of the
    // shared ContentWritePolicy confinement predicate for the membership ops.
    class function ConfineStructuralTarget(const ATargetPath, AProjectRoot: string;
      out AFullPath, AReason: string): Boolean; static;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Aefos.MCP.OTA.UnitCreatePolicy,
  Aefos.MCP.OTA.ContentWritePolicy;

function TStructuralPlan.MoveCount: Integer;
begin
  Result := Length(Moves);
end;

// A single src->dst move (plain-record builder — records carry no constructor).
function _Move(const ASrc, ADst: string): TStructuralMove;
begin
  Result.Src := ASrc;
  Result.Dst := ADst;
end;

class function TStructuralWritePolicy.ConfineStructuralTarget(const ATargetPath, AProjectRoot: string;
  out AFullPath, AReason: string): Boolean;
var
  LConfined: TConfinedWrite;
begin
  // Callers must not alias ATargetPath with AFullPath: an `out` string is reset
  // to '' at the call site before this body runs, which would erase an aliased
  // input. Callers pass a distinct temp for AFullPath.
  LConfined := TContentWritePolicy.ConfineWritePath(ATargetPath, AProjectRoot);
  AFullPath := '';
  AReason   := '';
  Result := LConfined.Accepted;
  if Result then
    AFullPath := LConfined.FullPath
  else
    AReason := LConfined.Reason;
end;

// A refused plan — no file touched, kebab cause recorded (ADR-088-07).
function _Refuse(const AReason: string): TStructuralPlan;
begin
  Result := Default(TStructuralPlan);
  Result.Accepted := False;
  Result.Reason   := AReason;
end;

// Confine ASource to AProjectRoot and enumerate its companion .dfm when it
// exists. Returns False (AReason set) on an unresolved or out-of-root source.
function _ConfinedSourceSet(const ASourcePas, AProjectRoot: string;
  const AExists: TPathExistsFunc;
  out AConfinedPas, AConfinedDfm: string; out AHasDfm: Boolean;
  out AReason: string): Boolean;
var
  LDfm: string;
begin
  AConfinedPas := '';
  AConfinedDfm := '';
  AHasDfm      := False;
  if not TStructuralWritePolicy.ConfineStructuralTarget(ASourcePas, AProjectRoot, AConfinedPas, AReason) then
    Exit(False);
  LDfm := ChangeFileExt(AConfinedPas, '.dfm');
  if Assigned(AExists) and AExists(LDfm) then
  begin
    if not TStructuralWritePolicy.ConfineStructuralTarget(LDfm, AProjectRoot, AConfinedDfm, AReason) then
      Exit(False);
    AHasDfm := True;
  end;
  Result := True;
end;

class function TStructuralWritePolicy.PlanUnitRename(const ASourcePas, ANewUnitName, AProjectRoot: string;
  const AExists: TPathExistsFunc): TStructuralPlan;
var
  LSrcPas, LSrcDfm, LDstPas, LDstDfm, LDir, LConf, LReason: string;
  LHasDfm: Boolean;
begin
  if not TUnitCreatePolicy.IsValidUnitName(ANewUnitName) then
    Exit(_Refuse('invalid-unit-name'));

  if not (Assigned(AExists) and AExists(ASourcePas)) then
    Exit(_Refuse('unit-not-found'));

  if not _ConfinedSourceSet(ASourcePas, AProjectRoot, AExists,
    LSrcPas, LSrcDfm, LHasDfm, LReason) then
    Exit(_Refuse(LReason));

  LDir    := TPath.GetDirectoryName(LSrcPas);
  LDstPas := TPath.Combine(LDir, ANewUnitName + '.pas');
  if not TStructuralWritePolicy.ConfineStructuralTarget(LDstPas, AProjectRoot, LConf, LReason) then
    Exit(_Refuse(LReason));
  LDstPas := LConf;
  if Assigned(AExists) and AExists(LDstPas) then
    Exit(_Refuse('already-exists'));

  Result := Default(TStructuralPlan);
  Result.Accepted     := True;
  Result.NewUnitName  := ANewUnitName;
  Result.Moves        := [_Move(LSrcPas, LDstPas)];
  Result.TouchedFiles := [LDstPas];

  if LHasDfm then
  begin
    LDstDfm := ChangeFileExt(LDstPas, '.dfm');
    if not TStructuralWritePolicy.ConfineStructuralTarget(LDstDfm, AProjectRoot, LConf, LReason) then
      Exit(_Refuse(LReason));
    LDstDfm := LConf;
    if Assigned(AExists) and AExists(LDstDfm) then
      Exit(_Refuse('already-exists'));
    Result.Moves        := Result.Moves + [_Move(LSrcDfm, LDstDfm)];
    Result.TouchedFiles := Result.TouchedFiles + [LDstDfm];
  end;
end;

class function TStructuralWritePolicy.PlanUnitMove(const ASourcePas, ATargetFolder, AProjectRoot: string;
  const AExists: TPathExistsFunc): TStructuralPlan;
var
  LSrcPas, LSrcDfm, LDstPas, LDstDfm, LFolderFull, LConf, LReason: string;
  LHasDfm: Boolean;
begin
  if not (Assigned(AExists) and AExists(ASourcePas)) then
    Exit(_Refuse('unit-not-found'));

  // The target folder is project-relative and must resolve inside the root.
  if not TStructuralWritePolicy.ConfineStructuralTarget(ATargetFolder, AProjectRoot, LFolderFull, LReason) then
    Exit(_Refuse(LReason));

  if not _ConfinedSourceSet(ASourcePas, AProjectRoot, AExists,
    LSrcPas, LSrcDfm, LHasDfm, LReason) then
    Exit(_Refuse(LReason));

  LDstPas := TPath.Combine(LFolderFull, TPath.GetFileName(LSrcPas));
  if not TStructuralWritePolicy.ConfineStructuralTarget(LDstPas, AProjectRoot, LConf, LReason) then
    Exit(_Refuse(LReason));
  LDstPas := LConf;
  if Assigned(AExists) and AExists(LDstPas) then
    Exit(_Refuse('already-exists'));

  Result := Default(TStructuralPlan);
  Result.Accepted     := True;
  Result.Moves        := [_Move(LSrcPas, LDstPas)];
  Result.TouchedFiles := [LDstPas];

  if LHasDfm then
  begin
    LDstDfm := TPath.Combine(LFolderFull, TPath.GetFileName(LSrcDfm));
    if not TStructuralWritePolicy.ConfineStructuralTarget(LDstDfm, AProjectRoot, LConf, LReason) then
      Exit(_Refuse(LReason));
    LDstDfm := LConf;
    if Assigned(AExists) and AExists(LDstDfm) then
      Exit(_Refuse('already-exists'));
    Result.Moves        := Result.Moves + [_Move(LSrcDfm, LDstDfm)];
    Result.TouchedFiles := Result.TouchedFiles + [LDstDfm];
  end;
end;

class function TStructuralWritePolicy.PlanUnitDelete(const ASourcePas, AProjectRoot: string;
  const AExists: TPathExistsFunc): TStructuralPlan;
var
  LSrcPas, LSrcDfm, LReason: string;
  LHasDfm: Boolean;
begin
  if not (Assigned(AExists) and AExists(ASourcePas)) then
    Exit(_Refuse('not-found'));

  if not _ConfinedSourceSet(ASourcePas, AProjectRoot, AExists,
    LSrcPas, LSrcDfm, LHasDfm, LReason) then
    Exit(_Refuse(LReason));

  Result := Default(TStructuralPlan);
  Result.Accepted     := True;
  Result.TouchedFiles := [LSrcPas];
  if LHasDfm then
    Result.TouchedFiles := Result.TouchedFiles + [LSrcDfm];
end;

end.
