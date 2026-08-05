unit Aefos.MCP.OTA.ProjectGroupService;

{
  Project-group operations, extracted from the TMCPWorkspaceFacade god-object as a
  focused service of the SOLID split (audit S6 / facade split).

  Owns the six IOTAProjectGroup methods — GetProjectGroupName, ListProjectsInGroup,
  SetActiveProject, AddProjectToGroup, RemoveProjectFromGroup, BuildAllInGroup —
  plus their group-specific OTA-body helpers (_FindProjectInGroup, the four *Sync
  bodies, _BuildOneGroupProject). The only shared dependency is the trivial
  TFacadeShared.TryModuleServices getter, now drawn from Aefos.MCP.OTA.FacadeShared.

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FProjectGroup service field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPProjectGroupService = interface
    ['{C4E9A1D8-7B62-4F30-9A57-3E1C8D2B6A40}']
    function GetProjectGroupName: string;
    function ListProjectsInGroup: TArray<TMCPRecordGroupProject>;
    function SetActiveProject(const AProjectPath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function AddProjectToGroup(const AProjectPath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function RemoveProjectFromGroup(const AProjectPath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function BuildAllInGroup(out AResults: TArray<TMCPRecordGroupBuildResult>;
      out AReason: string): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPProjectGroupService: IMCPProjectGroupService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared;

type
  TMCPProjectGroupService = class(TInterfacedObject, IMCPProjectGroupService)
  public
    function GetProjectGroupName: string;
    function ListProjectsInGroup: TArray<TMCPRecordGroupProject>;
    function SetActiveProject(const AProjectPath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function AddProjectToGroup(const AProjectPath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function RemoveProjectFromGroup(const AProjectPath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function BuildAllInGroup(out AResults: TArray<TMCPRecordGroupBuildResult>;
      out AReason: string): Boolean;
  end;

// Resolve a project inside AGroup by exact .dproj path (FindProject) with a
// basename fallback across the group. Extracted from SetActiveProject so the
// configuration setter stays within the cognitive-complexity gate (ESP-089
// verify F1).
function _FindProjectInGroup(const AGroup: IOTAProjectGroup;
  const AProjectPath: string): IOTAProject;
var
  LProject: IOTAProject;
  LFor: Integer;
begin
  Result := AGroup.FindProject(AProjectPath);
  if Assigned(Result) then
    Exit;
  for LFor := 0 to AGroup.ProjectCount - 1 do
  begin
    LProject := AGroup.Projects[LFor];
    if Assigned(LProject) and
       SameText(ExtractFileName(LProject.FileName),
                ExtractFileName(AProjectPath)) then
      Exit(LProject);
  end;
  Result := nil;
end;

// OTA body of SetActiveProject, run on the main thread: resolve the target in
// the open project group and select it. Selecting the already-active project is
// a valid idempotent no-op (AChanged := False). Extracted from SetActiveProject
// so each method stays within the cognitive-complexity gate (ESP-089 verify F1).
function _SetActiveProjectSync(const AProjectPath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LMS: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
  LTarget: IOTAProject;
begin
  AChanged := False;
  AReason  := 'no-project-group';
  if not TFacadeShared.TryModuleServices(LMS) then
  begin
    AReason := 'no-module-services';
    Exit(False);
  end;
  LGroup := LMS.MainProjectGroup;
  if not Assigned(LGroup) then
  begin
    AReason := 'no-project-group';
    Exit(False);
  end;
  LTarget := _FindProjectInGroup(LGroup, AProjectPath);
  if not Assigned(LTarget) then
  begin
    AReason := 'project-not-in-group';
    Exit(False);
  end;
  AChanged := not (Assigned(LGroup.ActiveProject) and
                   SameText(LGroup.ActiveProject.FileName, LTarget.FileName));
  LGroup.SetActiveProject(LTarget);
  Result := Assigned(LGroup.ActiveProject) and
            SameText(LGroup.ActiveProject.FileName, LTarget.FileName);
  if not Result then
    AReason := 'set-active-failed';
end;

// Open the .dproj via IOTAModuleServices.OpenModule, which adds it to the
// current group without closing existing projects. Idempotent if already there.
function _AddProjectToGroupSync(const AProjectPath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LMS: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
  LModule: IOTAModule;
begin
  AChanged := False;
  AReason  := '';
  if not TFacadeShared.TryModuleServices(LMS) then
  begin
    AReason := 'no-module-services';
    Exit(False);
  end;
  LGroup := LMS.MainProjectGroup;
  if Assigned(LGroup) and Assigned(_FindProjectInGroup(LGroup, AProjectPath)) then
  begin
    AChanged := False;
    Exit(True);
  end;
  try
    LModule := LMS.OpenModule(AProjectPath);
    if Assigned(LModule) then
    begin
      AChanged := True;
      Exit(True);
    end;
    AReason := 'open-module-returned-nil';
    Result  := False;
  except
    on E: Exception do
    begin
      AReason := E.Message;
      Result  := False;
    end;
  end;
end;

// Remove project from group via IOTAProjectGroup.RemoveProject. Idempotent
// (not-in-group = already removed = success). Symmetric with AddProjectToGroup.
function _RemoveProjectFromGroupSync(const AProjectPath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LMS: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
  LTarget: IOTAProject;
begin
  AChanged := False;
  AReason  := '';
  if not TFacadeShared.TryModuleServices(LMS) then
  begin
    AReason := 'no-module-services';
    Exit(False);
  end;
  LGroup := LMS.MainProjectGroup;
  if not Assigned(LGroup) then
  begin
    AReason := 'no-project-group';
    Exit(False);
  end;
  LTarget := _FindProjectInGroup(LGroup, AProjectPath);
  if not Assigned(LTarget) then
  begin
    AChanged := False;
    Exit(True);
  end;
  try
    LGroup.RemoveProject(LTarget);
    AChanged := not Assigned(_FindProjectInGroup(LGroup, AProjectPath));
    Result   := True;
  except
    on E: Exception do
    begin
      AReason := E.Message;
      Result  := False;
    end;
  end;
end;

// Build a single project of the open group and capture its outcome row. Never
// raises — a missing builder degrades to a Success=False row with an 'errors'
// note, so BuildAllInGroup never short-circuits (frozen-types ADR-144).
function _BuildOneGroupProject(
  const AProject: IOTAProject): TMCPRecordGroupBuildResult;
var
  LBuilder: IOTAProjectBuilder;
begin
  Result := Default(TMCPRecordGroupBuildResult);
  Result.Project := AProject.FileName;
  LBuilder := AProject.ProjectBuilder;
  if not Assigned(LBuilder) then
  begin
    Result.Success := False;
    Result.Errors  := ['no-project-builder'];
    Exit;
  end;
  Result.Success := LBuilder.BuildProject(cmOTABuild, False, True);
end;

// OTA body of BuildAllInGroup, run on the main thread: iterate every project in
// the open project group and build it, one outcome row per project (never
// short-circuiting, ADR-144). A lone project still has an implicit group, so
// this builds the single scratch project when no .groupproj is open; only a
// truly absent group degrades to the 'no-project-group' CAVEAT (ADR-091-03 /
// R3). Extracted so BuildAllInGroup stays within the complexity gate.
function _BuildAllInGroupSync(
  out AResults: TArray<TMCPRecordGroupBuildResult>;
  out AReason: string): Boolean;
var
  LMS: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
  LFor: Integer;
  LProject: IOTAProject;
  LList: TList<TMCPRecordGroupBuildResult>;
begin
  AResults := [];
  AReason  := 'no-project-group';
  if not TFacadeShared.TryModuleServices(LMS) then
  begin
    AReason := 'no-module-services';
    Exit(False);
  end;
  LGroup := LMS.MainProjectGroup;
  if not Assigned(LGroup) or (LGroup.ProjectCount = 0) then
    Exit(False); // no group open — honest CAVEAT (ADR-091-03 / R3)
  LList := TList<TMCPRecordGroupBuildResult>.Create;
  try
    for LFor := 0 to LGroup.ProjectCount - 1 do
    begin
      LProject := LGroup.Projects[LFor];
      if Assigned(LProject) then
        LList.Add(_BuildOneGroupProject(LProject));
    end;
    AResults := LList.ToArray;
  finally
    LList.Free;
  end;
  AReason := '';
  Result  := Length(AResults) > 0;
end;

function TMCPProjectGroupService.GetProjectGroupName: string;
var
  LName: string;
begin
  // Was a never-implemented stub (always ''). Now reads the live group via
  // IOTAModuleServices.MainProjectGroup on the OTA main thread. '' = no group.
  LName := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
      LGroup: IOTAProjectGroup;
    begin
      try
        if Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
        begin
          LGroup := LMS.MainProjectGroup;
          if Assigned(LGroup) then
            LName := LGroup.FileName;
        end;
      except
        LName := '';
      end;
    end);
  except
    LName := '';
  end;
  Result := LName;
end;

function TMCPProjectGroupService.ListProjectsInGroup: TArray<TMCPRecordGroupProject>;
var
  LResult: TArray<TMCPRecordGroupProject>;
begin
  // Was a never-implemented stub (always []). Now enumerates the live project
  // group on the OTA main thread; [] only when no group is open.
  SetLength(LResult, 0);
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
      LGroup: IOTAProjectGroup;
      LActive: IOTAProject;
      LProj: IOTAProject;
      LFor: Integer;
      LRec: TMCPRecordGroupProject;
    begin
      try
        if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
          Exit;
        LGroup := LMS.MainProjectGroup;
        if not Assigned(LGroup) then
          Exit;
        LActive := LGroup.ActiveProject;
        SetLength(LResult, LGroup.ProjectCount);
        for LFor := 0 to LGroup.ProjectCount - 1 do
        begin
          LRec.Name := '';
          LRec.Path := '';
          LRec.Active := False;
          LProj := LGroup.Projects[LFor];
          if Assigned(LProj) then
          begin
            LRec.Path := LProj.FileName;
            LRec.Name := TPath.GetFileNameWithoutExtension(LProj.FileName);
            LRec.Active := Assigned(LActive) and
              SameText(LProj.FileName, LActive.FileName);
          end;
          LResult[LFor] := LRec;
        end;
      except
        SetLength(LResult, 0);
      end;
    end);
  except
    SetLength(LResult, 0);
  end;
  Result := LResult;
end;

// Select the active project in the open project group (ESP-089,
// IOTAProjectGroup.SetActiveProject). The target is resolved by exact .dproj path
// (FindProject) and falls back to a basename match within the group; selecting
// the already-active project is a valid idempotent no-op (AChanged := False).
// GetActiveProject is the live acceptance read. A lone project still has an
// implicit group, so this works without an open .groupproj.
function TMCPProjectGroupService.SetActiveProject(
  const AProjectPath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LOk, LChanged: Boolean;
  LReason: string;
begin
  LOk      := False;
  LChanged := False;
  LReason  := 'no-project-group';
  try
    TThread.Synchronize(nil, procedure
    begin
      LOk := _SetActiveProjectSync(AProjectPath, LChanged, LReason);
    end);
  except
    on E: Exception do
    begin
      LOk     := False;
      LReason := E.Message;
    end;
  end;
  AChanged := LChanged;
  if LOk then AReason := '' else AReason := LReason;
  Result := LOk;
end;

function TMCPProjectGroupService.AddProjectToGroup(
  const AProjectPath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LOk, LChanged: Boolean;
  LReason: string;
begin
  LOk      := False;
  LChanged := False;
  LReason  := '';
  try
    TThread.Synchronize(nil, procedure
    begin
      LOk := _AddProjectToGroupSync(AProjectPath, LChanged, LReason);
    end);
  except
    on E: Exception do
    begin
      LOk     := False;
      LReason := E.Message;
    end;
  end;
  AChanged := LChanged;
  if LOk then AReason := '' else AReason := LReason;
  Result := LOk;
end;

function TMCPProjectGroupService.RemoveProjectFromGroup(
  const AProjectPath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LOk, LChanged: Boolean;
  LReason: string;
begin
  LOk      := False;
  LChanged := False;
  LReason  := '';
  try
    TThread.Synchronize(nil, procedure
    begin
      LOk := _RemoveProjectFromGroupSync(AProjectPath, LChanged, LReason);
    end);
  except
    on E: Exception do
    begin
      LOk     := False;
      LReason := E.Message;
    end;
  end;
  AChanged := LChanged;
  if LOk then AReason := '' else AReason := LReason;
  Result := LOk;
end;

// Build every project in the open project group (ESP-091, S2 / ADR-091-07 /
// R3). Scratch-scoped: the open group is the campaign's scratch project (a lone
// project's implicit group), so this builds it; RADShell is never built. With
// no group open at all it degrades to the documented 'no-project-group' CAVEAT
// (the D5 no-.groupproj class), never a FAIL.
function TMCPProjectGroupService.BuildAllInGroup(
  out AResults: TArray<TMCPRecordGroupBuildResult>;
  out AReason: string): Boolean;
var
  LResults: TArray<TMCPRecordGroupBuildResult>;
  LReason: string;
  LOk: Boolean;
begin
  LResults := [];
  LReason  := 'no-project-group';
  LOk      := False;
  try
    TThread.Synchronize(nil, procedure
    begin
      LOk := _BuildAllInGroupSync(LResults, LReason);
    end);
  except
    on E: Exception do
    begin
      LReason := E.Message;
      LOk     := False;
    end;
  end;
  AResults := LResults;
  AReason  := LReason;
  Result   := LOk;
end;

function NewMCPProjectGroupService: IMCPProjectGroupService;
begin
  Result := TMCPProjectGroupService.Create;
end;

end.
